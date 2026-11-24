//! The IME switched off and on as a whole: GNOME's source switcher picks an
//! xkb layout or the engine (D33). Off means every frontend's keys pass
//! untouched and Ctrl+Shift does nothing; a word in progress is committed,
//! never dropped (B3).

mod common;

use common::{App, HOLD, PREEDIT, SURROUNDING, ctx, ime, ime_in, key, tap_ctrl_shift};
use ime_core::{Action, KeyEvent, Mode, Mods, SharedIme, keysym};

#[test]
fn the_ime_starts_on() {
    assert!(ime().enabled());
}

#[test]
fn while_off_keys_pass_raw_and_ctrl_shift_does_nothing() {
    let mut ime = ime();
    let mut watch = ime.subscribe_mode();
    let id = ctx(&mut ime, PREEDIT);
    ime.set_enabled(false);
    assert!(!ime.enabled());

    let mut app = App::default();
    let results = app.type_str(&mut ime, id, "vieetj ");
    assert!(results.iter().all(|r| !r.handled && r.actions.is_empty()));
    assert_eq!(app.text, "vieetj ");

    let taps = tap_ctrl_shift(&mut ime, id);
    assert!(taps.iter().all(|r| !r.handled && r.actions.is_empty()));
    assert_eq!(ime.mode(), Mode::Vi, "no toggle while off");
    assert_eq!(watch.try_changed(), None, "the indicator is not touched");
}

#[test]
fn switching_off_commits_the_word_in_progress_at_the_next_call() {
    for caps in [PREEDIT, HOLD] {
        let mut ime = ime();
        let id = ctx(&mut ime, caps);
        let mut app = App::default();
        app.type_str(&mut ime, id, "vieet");
        ime.set_enabled(false);
        assert_eq!(
            ime.buffered_len(id),
            0,
            "nothing of the word stays in the IME"
        );

        // The next key of that context brings the word first, then goes on raw.
        app.type_str(&mut ime, id, "j");
        assert_eq!(app.text, "viêtj");
        assert_eq!(app.preedit, "");
    }
}

#[test]
fn switching_off_hands_the_word_to_focus_out_and_take_pending() {
    let mut ime = ime();
    let a = ctx(&mut ime, PREEDIT);
    let b = ctx(&mut ime, PREEDIT);
    let mut app = App::default();
    app.type_str(&mut ime, a, "vieetj");
    app.type_str(&mut ime, b, "dd");
    ime.set_enabled(false);
    assert_eq!(
        ime.take_pending(a),
        [Action::HidePreedit, Action::Commit("việt".into())]
    );
    assert_eq!(
        ime.focus_out(b),
        [Action::HidePreedit, Action::Commit("đ".into())]
    );
    assert_eq!(ime.take_pending(a), [], "handed out once");
}

#[test]
fn surrounding_text_clients_already_hold_the_word() {
    let mut ime = ime();
    let id = ctx(&mut ime, SURROUNDING);
    let mut app = App::default();
    app.type_str(&mut ime, id, "vieetj");
    ime.set_enabled(false);
    assert_eq!(ime.take_pending(id), []);
    app.type_str(&mut ime, id, "s");
    assert_eq!(app.text, "việts");
}

#[test]
fn switching_on_again_keeps_the_mode_and_converts_again() {
    let mut ime = ime_in(Mode::En);
    let id = ctx(&mut ime, PREEDIT);
    ime.set_enabled(false);
    ime.set_enabled(true);
    assert_eq!(ime.mode(), Mode::En);
    tap_ctrl_shift(&mut ime, id);
    assert_eq!(ime.mode(), Mode::Vi);
    let mut app = App::default();
    app.type_str(&mut ime, id, "vieetj ");
    assert_eq!(app.text, "việt ");
}

#[test]
fn a_tap_that_spans_the_switch_does_not_toggle() {
    let mut ime = ime();
    let id = ctx(&mut ime, PREEDIT);
    ime.process_key(id, KeyEvent::press(keysym::CONTROL_L, Mods::NONE));
    ime.process_key(id, KeyEvent::press(keysym::SHIFT_L, Mods::CONTROL));
    ime.set_enabled(false);
    ime.set_enabled(true);
    let cs = Mods(Mods::CONTROL.0 | Mods::SHIFT.0);
    ime.process_key(id, KeyEvent::release(keysym::SHIFT_L, cs));
    ime.process_key(id, KeyEvent::release(keysym::CONTROL_L, Mods::CONTROL));
    assert_eq!(ime.mode(), Mode::Vi);
}

#[test]
fn the_shared_handle_switches_and_collects() {
    let shared = SharedIme::new(ime());
    let id = shared.create_context();
    shared.set_caps(id, PREEDIT);
    for c in "dd".chars() {
        shared.process_key(id, key(c));
    }
    shared.set_enabled(false);
    assert!(!shared.enabled());
    assert_eq!(
        shared.take_pending(id),
        [Action::HidePreedit, Action::Commit("đ".into())]
    );
    shared.set_enabled(true);
    assert!(shared.enabled());
}
