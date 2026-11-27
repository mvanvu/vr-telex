//! Key pipeline: preedit / surrounding / hold policy (D10), boundaries,
//! never-drop on focus-out, reset and destroy (AC-3, B3).

mod common;

use common::{App, HOLD, PREEDIT, SURROUNDING, ctx, ime, ime_in, key, press};
use ime_core::{Action, KeyEvent, MAX_WORD_KEYS, Mode, Mods, keysym};
use telex_core::Composer;

fn commit(text: &str) -> Action {
    Action::Commit(text.to_owned())
}

#[test]
fn preedit_word_is_shown_then_committed_once_at_the_boundary() {
    let mut ime = ime();
    let id = ctx(&mut ime, PREEDIT);
    let mut app = App::default();

    let results = app.type_str(&mut ime, id, "vieejt");
    assert!(results.iter().all(|r| r.handled));
    assert_eq!(
        results.last().unwrap().actions,
        [Action::UpdatePreedit {
            text: "việt".to_owned(),
            cursor: 4
        }]
    );
    assert_eq!(app.text, "", "nothing committed inside the word");
    assert_eq!(app.preedit, "việt");

    let space = app.send(&mut ime, id, key(' '));
    assert!(!space.handled, "the app gets the boundary key itself");
    assert_eq!(space.actions, [Action::HidePreedit, commit("việt")]);
    assert_eq!(app.text, "việt ");
    assert_eq!(app.preedit, "");
    assert_eq!(ime.buffered_len(id), 0);
}

#[test]
fn every_edit_mode_gives_the_same_text() {
    let keys = "tieesng Vieejt class DDaij as<s nam, hoaf2 ";
    let want = "tiếng Việt class Đại á nam, hoà2 ";
    for caps in [PREEDIT, SURROUNDING, HOLD] {
        let mut ime = ime();
        let id = ctx(&mut ime, caps);
        let mut app = App::default();
        app.type_str(&mut ime, id, keys);
        assert_eq!(app.text, want, "caps {caps:?}");
        assert_eq!(app.preedit, "");
    }
}

#[test]
fn backspace_edits_the_word_and_passes_through_when_there_is_none() {
    let mut ime = ime();
    let id = ctx(&mut ime, PREEDIT);
    let mut app = App::default();

    app.type_str(&mut ime, id, "vieet");
    let back = app.send(&mut ime, id, press(keysym::BACKSPACE));
    assert!(back.handled);
    assert_eq!(app.preedit, "viê");

    let results = app.type_str(&mut ime, id, "<<");
    assert!(results.iter().all(|r| r.handled));
    assert_eq!(app.preedit, "v");
    let last = app.send(&mut ime, id, press(keysym::BACKSPACE));
    assert!(last.handled);
    assert_eq!(last.actions, [Action::HidePreedit]);
    assert_eq!(ime.buffered_len(id), 0);

    app.text.push('x');
    let outside = app.send(&mut ime, id, press(keysym::BACKSPACE));
    assert!(!outside.handled, "no word: the app deletes its own text");
    assert!(outside.actions.is_empty());
    assert_eq!(app.text, "");
}

#[test]
fn surrounding_mode_rewrites_the_word_in_place() {
    let mut ime = ime();
    let id = ctx(&mut ime, SURROUNDING);
    let mut app = App::default();

    let a = app.send(&mut ime, id, key('a'));
    assert!(a.handled);
    assert_eq!(a.actions, [commit("a")]);
    let s = app.send(&mut ime, id, key('s'));
    assert!(s.handled);
    assert_eq!(
        s.actions,
        [
            Action::DeleteSurrounding {
                offset: -1,
                chars: 1
            },
            commit("á")
        ]
    );
    let space = app.send(&mut ime, id, key(' '));
    assert!(!space.handled);
    assert!(space.actions.is_empty(), "the word is already in the app");
    assert_eq!(app.text, "á ");

    // After every key the app shows exactly what the composer holds.
    let mut reference = Composer::new();
    let mut app = App::default();
    for c in "nguowif".chars() {
        app.send(&mut ime, id, key(c));
        reference.push(c);
        assert_eq!(app.text, reference.text());
    }
    app.send(&mut ime, id, press(keysym::BACKSPACE));
    reference.pop();
    assert_eq!(app.text, reference.text());
    assert_eq!(app.text, "ngươi");
}

#[test]
fn hold_mode_keeps_the_word_until_the_boundary() {
    let mut ime = ime();
    let id = ctx(&mut ime, HOLD);
    let mut app = App::default();

    let results = app.type_str(&mut ime, id, "vieejt");
    assert!(results.iter().all(|r| r.handled && r.actions.is_empty()));
    assert_eq!(ime.buffered_len(id), 4);

    let enter = app.send(&mut ime, id, press(keysym::RETURN));
    assert!(!enter.handled);
    assert_eq!(enter.actions, [commit("việt")]);
    assert_eq!(app.keys, [keysym::RETURN]);
}

#[test]
fn boundary_keys_commit_the_word_and_reach_the_app() {
    let boundaries = [
        key(' '),
        key('1'),
        key(','),
        key('.'),
        key('/'),
        press(keysym::RETURN),
        press(keysym::TAB),
        press(keysym::ESCAPE),
        press(keysym::LEFT),
        press(keysym::RIGHT),
        press(keysym::UP),
        press(keysym::DOWN),
        press(keysym::HOME),
        press(keysym::END),
        press(keysym::DELETE),
        press(0x0100_1ea1),
        KeyEvent::press('a' as u32, Mods::CONTROL),
        KeyEvent::press('s' as u32, Mods::ALT),
        KeyEvent::press('f' as u32, Mods::SUPER),
        KeyEvent::press('T' as u32, Mods::CONTROL | Mods::SHIFT),
    ];
    for ev in boundaries {
        let mut ime = ime();
        let id = ctx(&mut ime, PREEDIT);
        let mut app = App::default();
        app.type_str(&mut ime, id, "vieet");
        let result = app.send(&mut ime, id, ev);
        assert!(!result.handled);
        assert_eq!(result.actions, [Action::HidePreedit, commit("viêt")]);
        assert_eq!(app.keys, [ev.keysym]);
        assert_eq!(ime.buffered_len(id), 0);

        // With no word the key just passes.
        let again = app.send(&mut ime, id, ev);
        assert!(!again.handled);
        assert!(again.actions.is_empty());
    }
}

#[test]
fn focus_out_reset_and_destroy_commit_the_word_exactly_once() {
    for caps in [PREEDIT, HOLD] {
        let expected: Vec<Action> = if caps.preedit {
            vec![Action::HidePreedit, commit("viêt")]
        } else {
            vec![commit("viêt")]
        };

        let mut ime = ime();
        let id = ctx(&mut ime, caps);
        let mut app = App::default();

        app.type_str(&mut ime, id, "vieet");
        assert_eq!(ime.focus_out(id), expected, "focus-out");
        assert_eq!(ime.buffered_len(id), 0);
        assert!(ime.focus_out(id).is_empty(), "committed once");
        assert!(ime.reset(id).is_empty());

        ime.focus_in(id);
        app.type_str(&mut ime, id, "vieet");
        assert_eq!(ime.reset(id), expected, "reset");
        assert_eq!(ime.buffered_len(id), 0);
        assert!(ime.reset(id).is_empty(), "committed once");

        app.type_str(&mut ime, id, "vieet");
        assert_eq!(ime.destroy_context(id), expected, "destroy");
        assert!(ime.destroy_context(id).is_empty(), "already gone");
        let after = ime.process_key(id, key('a'));
        assert!(!after.handled, "a destroyed context handles nothing");
        assert!(after.actions.is_empty());
        assert!(ime.focus_out(id).is_empty());
    }
}

#[test]
fn surrounding_mode_has_nothing_left_to_commit_on_focus_out() {
    let mut ime = ime();
    let id = ctx(&mut ime, SURROUNDING);
    let mut app = App::default();
    app.type_str(&mut ime, id, "vieet");
    assert_eq!(app.text, "viêt");
    assert!(ime.focus_out(id).is_empty());
    assert_eq!(ime.buffered_len(id), 0);
    // The next word starts fresh: the old one is not rewritten.
    ime.focus_in(id);
    app.type_str(&mut ime, id, "s");
    assert_eq!(app.text, "viêts");
}

#[test]
fn english_mode_handles_nothing() {
    let mut ime = ime_in(Mode::En);
    let id = ctx(&mut ime, PREEDIT);
    let mut app = App::default();
    let results = app.type_str(&mut ime, id, "vieejt as<s ");
    assert!(results.iter().all(|r| !r.handled && r.actions.is_empty()));
    assert_eq!(app.text, "vieejt as ");
    assert_eq!(ime.buffered_len(id), 0);
}

#[test]
fn contexts_do_not_share_words() {
    let mut ime = ime();
    let a = ctx(&mut ime, PREEDIT);
    let b = ctx(&mut ime, PREEDIT);
    let mut app_a = App::default();
    let mut app_b = App::default();

    app_a.type_str(&mut ime, a, "vie");
    app_b.type_str(&mut ime, b, "na");
    app_a.type_str(&mut ime, a, "et");
    app_b.type_str(&mut ime, b, "m");
    assert_eq!(app_a.preedit, "viêt");
    assert_eq!(app_b.preedit, "nam");

    assert_eq!(ime.focus_out(a), [Action::HidePreedit, commit("viêt")]);
    assert_eq!(ime.buffered_len(b), 3, "the other context keeps its word");
    assert_eq!(ime.reset(b), [Action::HidePreedit, commit("nam")]);
}

#[test]
fn releases_and_lone_modifiers_do_not_end_the_word() {
    let mut ime = ime();
    let id = ctx(&mut ime, PREEDIT);
    let mut app = App::default();

    app.type_str(&mut ime, id, "vi");
    let events = [
        KeyEvent::release('i' as u32, Mods::NONE),
        KeyEvent::press(keysym::SHIFT_L, Mods::NONE),
        KeyEvent::release(keysym::SHIFT_L, Mods::SHIFT),
        KeyEvent::press(keysym::CAPS_LOCK, Mods::NONE),
        KeyEvent::release(keysym::CAPS_LOCK, Mods::LOCK),
        // IBus marks a release in the state mask.
        KeyEvent::press(' ' as u32, Mods::RELEASE),
    ];
    for ev in events {
        let result = app.send(&mut ime, id, ev);
        assert!(!result.handled);
        assert!(result.actions.is_empty());
    }
    app.type_str(&mut ime, id, "EEt");
    assert_eq!(app.preedit, "viÊt");
}

#[test]
fn an_overlong_word_is_committed_and_the_rest_passes_through() {
    let mut ime = ime();
    let id = ctx(&mut ime, PREEDIT);
    let mut app = App::default();

    let long = "b".repeat(MAX_WORD_KEYS + 8);
    let mut last_handled = true;
    for c in long.chars() {
        last_handled = app.send(&mut ime, id, key(c)).handled;
        assert!(ime.buffered_len(id) <= MAX_WORD_KEYS);
    }
    assert!(!last_handled);
    assert_eq!(ime.buffered_len(id), 0);
    assert_eq!(app.text, long);
    assert_eq!(app.preedit, "");

    // Still the same word: Telex keys stay literal until a boundary.
    app.type_str(&mut ime, id, "as");
    assert_eq!(app.text, format!("{long}as"));
    // The next word is composed again. The overlong run counts as English,
    // so the overlap word `as` (`á`) after it is restored (AC-3).
    app.type_str(&mut ime, id, " as dduwowcj ");
    assert_eq!(app.text, format!("{long}as as được "));
}

#[test]
fn a_capability_change_commits_the_word_under_the_old_capabilities() {
    let mut ime = ime();
    let id = ctx(&mut ime, PREEDIT);
    let mut app = App::default();

    app.type_str(&mut ime, id, "vieet");
    ime.set_caps(id, HOLD);
    assert_eq!(ime.buffered_len(id), 0);
    assert_eq!(ime.take_pending(id), [Action::HidePreedit, commit("viêt")]);
    assert!(ime.take_pending(id).is_empty());

    // Not collected: the actions lead the next result, never dropped.
    ime.set_caps(id, PREEDIT);
    app.type_str(&mut ime, id, "nam");
    ime.set_caps(id, HOLD);
    let next = ime.process_key(id, key('a'));
    assert!(next.handled);
    assert_eq!(next.actions, [Action::HidePreedit, commit("nam")]);

    // Same capabilities again: the word stays.
    ime.set_caps(id, HOLD);
    assert_eq!(ime.buffered_len(id), 1);
    assert_eq!(ime.focus_out(id), [commit("a")]);
}
