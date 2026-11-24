//! The shared handle the frontends use: one lock, whole calls, B2 ordering.

mod common;

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::Instant;

use common::{App, HOLD, PASSWORD, PREEDIT, key};
use ime_core::{
    Action, CtxId, Ime, KeyEvent, KeyResult, MemoryStateStore, Mode, Mods, SharedIme, keysym,
};

fn shared() -> SharedIme {
    SharedIme::new(Ime::new(&MemoryStateStore::new(Mode::Vi)))
}

fn tap(ime: &SharedIme, id: CtxId) -> Vec<KeyResult> {
    [
        KeyEvent::press(keysym::CONTROL_L, Mods::NONE),
        KeyEvent::press(keysym::SHIFT_L, Mods::CONTROL),
        KeyEvent::release(keysym::SHIFT_L, Mods(Mods::CONTROL.0 | Mods::SHIFT.0)),
        KeyEvent::release(keysym::CONTROL_L, Mods::CONTROL),
    ]
    .into_iter()
    .map(|ev| ime.process_key(id, ev))
    .collect()
}

#[test]
fn clones_drive_one_ime() {
    let ime = shared();
    let other = ime.clone();
    let mut watch = other.subscribe_mode();

    let id = ime.create_context();
    assert!(ime.set_caps(id, PREEDIT).is_empty());
    ime.focus_in(id);
    for c in "vieet".chars() {
        assert!(other.process_key(id, key(c)).handled);
    }
    assert_eq!(ime.buffered_len(id), 4);
    assert_eq!(
        other.focus_out(id),
        [Action::HidePreedit, Action::Commit("viêt".to_owned())]
    );
    assert!(ime.reset(id).is_empty());

    tap(&ime, id);
    assert_eq!(other.mode(), Mode::En);
    assert_eq!(watch.try_changed(), Some(Mode::En));
    assert!(other.destroy_context(id).is_empty());
}

#[test]
fn set_caps_hands_back_the_commit_of_the_word_in_progress() {
    let ime = shared();
    let id = ime.create_context();
    ime.set_caps(id, PREEDIT);
    for c in "vieet".chars() {
        ime.process_key(id, key(c));
    }
    assert_eq!(
        ime.set_caps(id, PASSWORD),
        [Action::HidePreedit, Action::Commit("viêt".to_owned())],
        "the frontend sends this before the field becomes a password field"
    );
    assert!(ime.set_caps(id, HOLD).is_empty());
}

#[test]
fn each_context_keeps_its_order_under_concurrent_frontends() {
    let ime = shared();
    let words = ["tieesng ", "vieejt ", "dduowngf ", "class ", "hoaf "];
    let expected = ["tiếng ", "việt ", "đường ", "class ", "hoà "];
    let threads = 4;
    let start = Arc::new(Barrier::new(threads));

    let handles: Vec<_> = (0..threads)
        .map(|t| {
            let ime = ime.clone();
            let start = Arc::clone(&start);
            thread::spawn(move || {
                let id = ime.create_context();
                ime.set_caps(id, PREEDIT);
                ime.focus_in(id);
                let mut app = App::default();
                let mut want = String::new();
                start.wait();
                for round in 0..200 {
                    let pick = (round + t) % words.len();
                    for c in words[pick].chars() {
                        let ev = key(c);
                        let result = ime.process_key(id, ev);
                        app.apply(ev, &result);
                    }
                    want.push_str(expected[pick]);
                }
                app.apply_actions(&ime.destroy_context(id));
                (app.text, want)
            })
        })
        .collect();

    for handle in handles {
        let (text, want) = handle.join().unwrap();
        assert_eq!(text, want);
    }
}

/// A clock that panics once when armed: a call dies half way, under the lock.
fn faulty_clock(armed: &Arc<AtomicBool>) -> Box<dyn Fn() -> Instant + Send> {
    let armed = Arc::clone(armed);
    Box::new(move || {
        if armed.swap(false, Ordering::SeqCst) {
            panic!("injected clock failure");
        }
        Instant::now()
    })
}

#[test]
fn a_panic_inside_one_call_does_not_stop_the_others() {
    let armed = Arc::new(AtomicBool::new(false));
    let ime = SharedIme::new(Ime::with_clock(
        &MemoryStateStore::new(Mode::Vi),
        faulty_clock(&armed),
    ));
    let id = ime.create_context();
    ime.set_caps(id, PREEDIT);
    let other = ime.create_context();
    ime.set_caps(other, PREEDIT);
    for c in "vie".chars() {
        ime.process_key(other, key(c));
    }
    for c in "na".chars() {
        ime.process_key(id, key(c));
    }

    armed.store(true, Ordering::SeqCst);
    let crashed = catch_unwind(AssertUnwindSafe(|| tap(&ime, id)));
    assert!(crashed.is_err(), "the injected panic fired");

    // Only the context whose call died loses its word.
    assert_eq!(ime.buffered_len(id), 0);
    // The other context's word is kept as a commit and leads its next result.
    let space = ime.process_key(other, key(' '));
    assert!(!space.handled);
    assert_eq!(
        space.actions,
        [Action::HidePreedit, Action::Commit("vie".to_owned())]
    );

    // Both contexts go on typing.
    for target in [id, other] {
        let mut app = App::default();
        for c in "as ".chars() {
            let ev = key(c);
            let result = ime.process_key(target, ev);
            app.apply(ev, &result);
        }
        assert_eq!(app.text, "á ");
    }
    assert_eq!(ime.mode(), Mode::Vi);
}
