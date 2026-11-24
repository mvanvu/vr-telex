//! Ctrl+Shift tap detector and the global VI/EN mode (AC-4, D6, D7).

mod common;

use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use common::{App, PASSWORD, PREEDIT, TestClock, ctx, ime, ime_in, key, tap_ctrl_shift};
use ime_core::{Action, Ime, KeyEvent, Mode, Mods, StateStore, keysym};

/// Records every save, starts from a given mode.
#[derive(Clone)]
struct RecordingStore {
    start: Mode,
    saved: Arc<Mutex<Vec<Mode>>>,
}

impl RecordingStore {
    fn new(start: Mode) -> Self {
        Self {
            start,
            saved: Arc::default(),
        }
    }
}

impl StateStore for RecordingStore {
    fn load(&self) -> Mode {
        self.start
    }

    fn save(&self, m: Mode) {
        self.saved.lock().unwrap().push(m);
    }
}

fn run(ime: &mut Ime, id: ime_core::CtxId, events: &[KeyEvent]) {
    for &ev in events {
        let result = ime.process_key(id, ev);
        let modifier = (keysym::SHIFT_L..=keysym::HYPER_R).contains(&ev.keysym);
        if modifier {
            assert!(!result.handled, "modifier events always reach the app");
        }
    }
}

const C: Mods = Mods::CONTROL;
const S: Mods = Mods::SHIFT;
const CS: Mods = Mods(Mods::CONTROL.0 | Mods::SHIFT.0);

#[test]
fn tap_toggles_and_notifies_without_writing_the_store() {
    let store = RecordingStore::new(Mode::Vi);
    let mut ime = Ime::new(&store);
    let mut watch = ime.subscribe_mode();
    let id = ctx(&mut ime, PREEDIT);
    assert_eq!(ime.mode(), Mode::Vi);
    assert_eq!(watch.current(), Mode::Vi);
    assert_eq!(watch.try_changed(), None);

    let results = tap_ctrl_shift(&mut ime, id);
    assert!(results.iter().all(|r| !r.handled && r.actions.is_empty()));
    assert_eq!(ime.mode(), Mode::En);
    assert_eq!(
        watch.try_changed(),
        Some(Mode::En),
        "the indicator watch fires"
    );
    assert_eq!(watch.try_changed(), None);

    tap_ctrl_shift(&mut ime, id);
    assert_eq!(ime.mode(), Mode::Vi);
    assert!(
        store.saved.lock().unwrap().is_empty(),
        "saving is file I/O: it is left to whoever follows the watch"
    );

    // The async side resolves at once after a change.
    let mut changed = Box::pin(watch.changed());
    let mut cx = Context::from_waker(Waker::noop());
    assert_eq!(changed.as_mut().poll(&mut cx), Poll::Ready(Some(Mode::Vi)));
}

#[test]
fn either_order_and_either_hand_toggles() {
    let sequences: [[KeyEvent; 4]; 4] = [
        [
            KeyEvent::press(keysym::SHIFT_L, Mods::NONE),
            KeyEvent::press(keysym::CONTROL_L, S),
            KeyEvent::release(keysym::CONTROL_L, CS),
            KeyEvent::release(keysym::SHIFT_L, S),
        ],
        [
            KeyEvent::press(keysym::SHIFT_L, Mods::NONE),
            KeyEvent::press(keysym::CONTROL_L, S),
            KeyEvent::release(keysym::SHIFT_L, CS),
            KeyEvent::release(keysym::CONTROL_L, C),
        ],
        [
            KeyEvent::press(keysym::CONTROL_R, Mods::NONE),
            KeyEvent::press(keysym::SHIFT_R, C),
            KeyEvent::release(keysym::CONTROL_R, CS),
            KeyEvent::release(keysym::SHIFT_R, S),
        ],
        // Releases flagged the IBus way, in the state mask.
        [
            KeyEvent::press(keysym::CONTROL_L, Mods::NONE),
            KeyEvent::press(keysym::SHIFT_R, C),
            KeyEvent::press(keysym::SHIFT_R, Mods(CS.0 | Mods::RELEASE.0)),
            KeyEvent::press(keysym::CONTROL_L, Mods(C.0 | Mods::RELEASE.0)),
        ],
    ];
    for events in sequences {
        let mut ime = ime();
        let id = ctx(&mut ime, PREEDIT);
        run(&mut ime, id, &events);
        assert_eq!(ime.mode(), Mode::En);
    }
}

#[test]
fn auto_repeat_of_a_held_modifier_still_toggles() {
    let mut ime = ime();
    let id = ctx(&mut ime, PREEDIT);
    run(
        &mut ime,
        id,
        &[
            KeyEvent::press(keysym::CONTROL_L, Mods::NONE),
            KeyEvent::press(keysym::CONTROL_L, C),
            KeyEvent::press(keysym::SHIFT_L, C),
            KeyEvent::press(keysym::SHIFT_L, CS),
            KeyEvent::release(keysym::SHIFT_L, CS),
            KeyEvent::release(keysym::CONTROL_L, C),
        ],
    );
    assert_eq!(ime.mode(), Mode::En);
}

#[test]
fn shortcuts_do_not_toggle_and_reach_the_app() {
    for letter in ['T', 'P', 'C', 'V'] {
        for start in [Mode::Vi, Mode::En] {
            let mut ime = ime_in(start);
            let id = ctx(&mut ime, PREEDIT);
            let mut app = App::default();
            let events = [
                KeyEvent::press(keysym::CONTROL_L, Mods::NONE),
                KeyEvent::press(keysym::SHIFT_L, C),
                KeyEvent::press(letter as u32, CS),
                KeyEvent::release(letter as u32, CS),
                KeyEvent::release(keysym::SHIFT_L, CS),
                KeyEvent::release(keysym::CONTROL_L, C),
            ];
            for ev in events {
                let result = app.send(&mut ime, id, ev);
                assert!(!result.handled, "Ctrl+Shift+{letter} reaches the app");
                assert!(result.actions.is_empty());
            }
            assert_eq!(ime.mode(), start, "Ctrl+Shift+{letter} must not toggle");
            assert!(app.keys.contains(&(letter as u32)));
        }
    }
}

#[test]
fn anything_but_a_clean_tap_does_not_toggle() {
    let a = 'a' as u32;
    let cases: Vec<(&str, Vec<KeyEvent>)> = vec![
        (
            "ctrl alone",
            vec![
                KeyEvent::press(keysym::CONTROL_L, Mods::NONE),
                KeyEvent::release(keysym::CONTROL_L, C),
            ],
        ),
        (
            "shift alone",
            vec![
                KeyEvent::press(keysym::SHIFT_L, Mods::NONE),
                KeyEvent::release(keysym::SHIFT_L, S),
            ],
        ),
        (
            "ctrl then shift, never together",
            vec![
                KeyEvent::press(keysym::CONTROL_L, Mods::NONE),
                KeyEvent::release(keysym::CONTROL_L, C),
                KeyEvent::press(keysym::SHIFT_L, Mods::NONE),
                KeyEvent::release(keysym::SHIFT_L, S),
            ],
        ),
        (
            "a key released in between",
            vec![
                KeyEvent::press(a, Mods::NONE),
                KeyEvent::press(keysym::CONTROL_L, Mods::NONE),
                KeyEvent::release(a, C),
                KeyEvent::press(keysym::SHIFT_L, C),
                KeyEvent::release(keysym::SHIFT_L, CS),
                KeyEvent::release(keysym::CONTROL_L, C),
            ],
        ),
        (
            "a key pressed after one modifier went up",
            vec![
                KeyEvent::press(keysym::CONTROL_L, Mods::NONE),
                KeyEvent::press(keysym::SHIFT_L, C),
                KeyEvent::release(keysym::SHIFT_L, CS),
                KeyEvent::press(a, C),
                KeyEvent::release(a, C),
                KeyEvent::release(keysym::CONTROL_L, C),
            ],
        ),
        (
            "alt joins the chord",
            vec![
                KeyEvent::press(keysym::CONTROL_L, Mods::NONE),
                KeyEvent::press(keysym::ALT_L, C),
                KeyEvent::press(keysym::SHIFT_L, Mods(C.0 | Mods::ALT.0)),
                KeyEvent::release(keysym::SHIFT_L, Mods(CS.0 | Mods::ALT.0)),
                KeyEvent::release(keysym::ALT_L, Mods(C.0 | Mods::ALT.0)),
                KeyEvent::release(keysym::CONTROL_L, C),
            ],
        ),
        (
            "super was already down",
            vec![
                KeyEvent::press(keysym::CONTROL_L, Mods::SUPER),
                KeyEvent::press(keysym::SHIFT_L, Mods(C.0 | Mods::SUPER.0)),
                KeyEvent::release(keysym::SHIFT_L, Mods(CS.0 | Mods::SUPER.0)),
                KeyEvent::release(keysym::CONTROL_L, Mods(C.0 | Mods::SUPER.0)),
            ],
        ),
    ];
    for (name, events) in cases {
        let mut ime = ime();
        let id = ctx(&mut ime, PREEDIT);
        run(&mut ime, id, &events);
        assert_eq!(ime.mode(), Mode::Vi, "{name}");
        // The detector recovers: a clean tap right after works.
        tap_ctrl_shift(&mut ime, id);
        assert_eq!(ime.mode(), Mode::En, "{name}: clean tap afterwards");
    }
}

#[test]
fn a_chord_held_for_a_second_does_not_toggle() {
    let clock = TestClock::new();
    let press_both = [
        KeyEvent::press(keysym::CONTROL_L, Mods::NONE),
        KeyEvent::press(keysym::SHIFT_L, C),
    ];
    let release_both = [
        KeyEvent::release(keysym::SHIFT_L, CS),
        KeyEvent::release(keysym::CONTROL_L, C),
    ];

    let mut ime = Ime::with_clock(&RecordingStore::new(Mode::Vi), clock.reader());
    let id = ctx(&mut ime, PREEDIT);

    run(&mut ime, id, &press_both);
    clock.advance(Duration::from_millis(1000));
    run(&mut ime, id, &release_both);
    assert_eq!(ime.mode(), Mode::Vi, "held 1 s");

    run(&mut ime, id, &press_both);
    clock.advance(Duration::from_millis(999));
    run(&mut ime, id, &release_both);
    assert_eq!(ime.mode(), Mode::En, "held just under 1 s");

    // Ctrl held long before Shift joins: Ctrl was down too long.
    run(&mut ime, id, &press_both[..1]);
    clock.advance(Duration::from_secs(3));
    run(&mut ime, id, &press_both[1..]);
    run(&mut ime, id, &release_both);
    assert_eq!(ime.mode(), Mode::En);
}

#[test]
fn the_tap_commits_the_word_being_typed() {
    let mut ime = ime();
    let id = ctx(&mut ime, PREEDIT);
    let mut app = App::default();
    app.type_str(&mut ime, id, "vieet");

    let results = tap_ctrl_shift(&mut ime, id);
    assert!(results.iter().all(|r| !r.handled));
    assert!(results[..3].iter().all(|r| r.actions.is_empty()));
    assert_eq!(
        results[3].actions,
        [Action::HidePreedit, Action::Commit("viêt".to_owned())]
    );
    assert_eq!(ime.mode(), Mode::En);
    assert_eq!(ime.buffered_len(id), 0);
}

#[test]
fn the_mode_is_global() {
    let mut ime = ime();
    let a = ctx(&mut ime, PREEDIT);
    let b = ctx(&mut ime, PREEDIT);
    let mut app_b = App::default();

    app_b.type_str(&mut ime, b, "vie");
    tap_ctrl_shift(&mut ime, a);
    assert_eq!(ime.mode(), Mode::En);

    // B's pending word is committed, then B types plain keys.
    let next = app_b.send(&mut ime, b, key('t'));
    assert!(!next.handled);
    assert_eq!(app_b.text, "viet");
    app_b.type_str(&mut ime, b, " as ");
    assert_eq!(app_b.text, "viet as ");

    tap_ctrl_shift(&mut ime, b);
    let mut app_a = App::default();
    app_a.type_str(&mut ime, a, "as ");
    assert_eq!(app_a.text, "á ");
}

#[test]
fn the_tap_works_in_a_password_field_and_keeps_nothing() {
    let mut ime = ime();
    let id = ctx(&mut ime, PASSWORD);
    let results = tap_ctrl_shift(&mut ime, id);
    assert!(results.iter().all(|r| !r.handled && r.actions.is_empty()));
    assert_eq!(ime.mode(), Mode::En);
    assert_eq!(ime.buffered_len(id), 0);
}

#[test]
fn focus_changes_cancel_a_chord_in_progress() {
    let mut ime = ime();
    let id = ctx(&mut ime, PREEDIT);
    let down = [
        KeyEvent::press(keysym::CONTROL_L, Mods::NONE),
        KeyEvent::press(keysym::SHIFT_L, C),
    ];
    let up = [
        KeyEvent::release(keysym::SHIFT_L, CS),
        KeyEvent::release(keysym::CONTROL_L, C),
    ];

    run(&mut ime, id, &down);
    ime.focus_out(id);
    ime.focus_in(id);
    run(&mut ime, id, &up);
    assert_eq!(ime.mode(), Mode::Vi, "focus-out in the middle");

    run(&mut ime, id, &down);
    ime.reset(id);
    run(&mut ime, id, &up);
    assert_eq!(
        ime.mode(),
        Mode::Vi,
        "a reset (a click) in the middle: Ctrl+Shift+click is not a tap"
    );

    run(&mut ime, id, &down);
    run(&mut ime, id, &up);
    assert_eq!(ime.mode(), Mode::En);
}

#[test]
fn the_mode_is_loaded_from_the_store() {
    let ime = Ime::new(&RecordingStore::new(Mode::En));
    assert_eq!(ime.mode(), Mode::En);
    let ime = Ime::new(&RecordingStore::new(Mode::Vi));
    assert_eq!(ime.mode(), Mode::Vi);
}
