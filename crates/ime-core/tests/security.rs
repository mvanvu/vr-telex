//! Keystroke confidentiality: password passthrough (AC-7, SEC-12), commits
//! stay in their own context (SEC-13), redacted Debug (SEC-2), nothing kept
//! after a boundary (SEC-4).

mod common;

use common::{App, HOLD, PASSWORD, PREEDIT, SURROUNDING, ctx, ime, key, press};
use ime_core::{Action, Caps, KeyEvent, KeyResult, Mods, keysym};

#[test]
fn password_field_receives_exactly_the_keys() {
    let mut ime = ime();
    let id = ctx(&mut ime, PASSWORD);
    let mut app = App::default();

    for c in "matkhau1s".chars() {
        let result = app.send(&mut ime, id, key(c));
        assert!(!result.handled);
        assert!(result.actions.is_empty());
        assert_eq!(ime.buffered_len(id), 0, "no buffering in a password field");
    }
    assert_eq!(app.text, "matkhau1s");

    let back = app.send(&mut ime, id, press(keysym::BACKSPACE));
    assert!(!back.handled);
    assert_eq!(app.text, "matkhau1");
    assert!(ime.focus_out(id).is_empty());
    assert!(ime.reset(id).is_empty());
    assert!(ime.destroy_context(id).is_empty());
}

#[test]
fn password_flag_wins_over_every_other_capability() {
    for caps in [PREEDIT, SURROUNDING, HOLD] {
        let mut ime = ime();
        let id = ctx(
            &mut ime,
            Caps {
                password: true,
                ..caps
            },
        );
        let mut app = App::default();
        app.type_str(&mut ime, id, "aas ddd ");
        assert_eq!(app.text, "aas ddd ");
        assert_eq!(app.preedit, "");
    }
}

#[test]
fn turning_into_a_password_field_commits_the_word_first() {
    let mut ime = ime();
    let id = ctx(&mut ime, PREEDIT);
    let mut app = App::default();

    app.type_str(&mut ime, id, "vieet");
    ime.set_caps(id, PASSWORD);
    assert_eq!(ime.buffered_len(id), 0);
    let pending = ime.take_pending(id);
    assert_eq!(
        pending,
        [Action::HidePreedit, Action::Commit("viêt".to_owned())]
    );
    app.apply_actions(&pending);

    let results = app.type_str(&mut ime, id, "aas");
    assert!(results.iter().all(|r| !r.handled && r.actions.is_empty()));
    assert_eq!(app.text, "viêtaas");

    // Back to a normal field: composing resumes with an empty word.
    ime.set_caps(id, PREEDIT);
    assert!(ime.take_pending(id).is_empty());
    app.type_str(&mut ime, id, " aans ");
    assert_eq!(app.text, "viêtaas ấn ");
}

#[test]
fn a_word_is_committed_only_to_the_context_it_was_typed_in() {
    let mut ime = ime();
    let field = ctx(&mut ime, PREEDIT);
    let mut field_app = App::default();
    field_app.type_str(&mut ime, field, "vieet");

    // Focus moves to a password field of another context.
    field_app.apply_actions(&ime.focus_out(field));
    let secret = ctx(&mut ime, PASSWORD);
    let mut secret_app = App::default();
    let results = secret_app.type_str(&mut ime, secret, "matkhau1s");

    assert_eq!(field_app.text, "viêt");
    assert_eq!(secret_app.text, "matkhau1s");
    assert!(results.iter().all(|r| r.actions.is_empty()));
    assert!(ime.take_pending(secret).is_empty());
    assert!(ime.take_pending(field).is_empty());
}

#[test]
fn debug_output_never_shows_text_or_keys() {
    let commit = Action::Commit("bimat".to_owned());
    let preedit = Action::UpdatePreedit {
        text: "bimat".to_owned(),
        cursor: 5,
    };
    let result = KeyResult {
        handled: true,
        actions: vec![
            Action::Commit("bimat".to_owned()),
            Action::HidePreedit,
            Action::DeleteSurrounding {
                offset: -5,
                chars: 5,
            },
        ],
    };
    for shown in [
        format!("{commit:?}"),
        format!("{preedit:?}"),
        format!("{result:?}"),
        format!("{result:#?}"),
    ] {
        assert!(!shown.contains("bimat"), "{shown}");
        assert!(shown.contains("<redacted len=5>"), "{shown}");
    }

    // keysym 0x71 = 113 = 'q', keycode 24.
    let event = KeyEvent {
        keysym: 0x71,
        keycode: 24,
        state: Mods::SHIFT,
        is_release: false,
    };
    let shown = format!("{event:?}");
    for leak in ["113", "71", "24", "q,", "'q'"] {
        assert!(!shown.contains(leak), "{shown}");
    }

    let mut ime = ime();
    let id = ctx(&mut ime, PREEDIT);
    for c in "bimat".chars() {
        ime.process_key(id, key(c));
    }
    let shown = format!("{ime:?}");
    assert!(!shown.contains("bimat"), "{shown}");
    assert!(!shown.contains("bim"), "{shown}");
}

#[test]
fn nothing_is_kept_after_a_boundary() {
    type End = fn(&mut ime_core::Ime, ime_core::CtxId);
    let ends: [(&str, End); 5] = [
        ("space", |ime, id| {
            ime.process_key(id, key(' '));
        }),
        ("focus-out", |ime, id| {
            ime.focus_out(id);
        }),
        ("reset", |ime, id| {
            ime.reset(id);
        }),
        ("password", |ime, id| {
            ime.set_caps(id, PASSWORD);
        }),
        ("toggle", |ime, id| {
            common::tap_ctrl_shift(ime, id);
        }),
    ];
    for caps in [PREEDIT, SURROUNDING, HOLD] {
        for (name, end) in ends {
            let mut ime = ime();
            let id = ctx(&mut ime, caps);
            for c in "vieet".chars() {
                ime.process_key(id, key(c));
            }
            assert_eq!(ime.buffered_len(id), 4);
            end(&mut ime, id);
            assert_eq!(ime.buffered_len(id), 0, "{name}, caps {caps:?}");
        }
    }
}
