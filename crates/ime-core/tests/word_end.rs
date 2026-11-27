//! Word end: every word is committed as `Composer::finish` decides, with the
//! language of the previous word of the same context (AC-1..AC-5), and that
//! language starts over at every focus, reset, mode or enable change.

mod common;

use common::{App, HOLD, PASSWORD, PREEDIT, SURROUNDING, ctx, ime, ime_in, key, tap_ctrl_shift};
use ime_core::{Action, Caps, CtxId, Ime, KeyEvent, MAX_WORD_KEYS, Mode, Mods};

const MODES: [Caps; 3] = [PREEDIT, SURROUNDING, HOLD];

fn commit(text: &str) -> Action {
    Action::Commit(text.to_owned())
}

/// What a word end emits in each edit mode when the shown text `shown` is
/// committed as `text`.
fn word_end(caps: Caps, shown: &str, text: &str) -> Vec<Action> {
    if caps.preedit {
        vec![Action::HidePreedit, commit(text)]
    } else if caps.surrounding_text {
        if shown == text {
            Vec::new()
        } else {
            let chars = shown.chars().count() as u32;
            vec![
                Action::DeleteSurrounding {
                    offset: -(chars as i32),
                    chars,
                },
                commit(text),
            ]
        }
    } else {
        vec![commit(text)]
    }
}

fn typed(caps: Caps, keys: &str) -> String {
    let mut ime = ime();
    let id = ctx(&mut ime, caps);
    let mut app = App::default();
    app.type_str(&mut ime, id, keys);
    assert_eq!(app.preedit, "", "caps {caps:?}");
    app.text
}

#[test]
fn english_after_a_plain_english_word_is_restored_in_every_edit_mode() {
    for caps in MODES {
        assert_eq!(typed(caps, "the best "), "the best ", "caps {caps:?}");
        assert_eq!(typed(caps, "use the best list "), "use the best list ");
    }
}

#[test]
fn vietnamese_words_stay_in_every_edit_mode() {
    for caps in MODES {
        // `bets` is in en.txt and `bét` in vi.txt: after a Vietnamese word
        // the overlap stays Vietnamese.
        assert_eq!(typed(caps, "raats bets "), "rất bét ", "caps {caps:?}");
        assert_eq!(typed(caps, "tieesng Vieejt "), "tiếng Việt ");
    }
}

#[test]
fn an_incomplete_syllable_commits_its_keys() {
    for caps in MODES {
        assert_eq!(typed(caps, "use "), "use ", "caps {caps:?}");
    }
}

#[test]
fn an_overlap_word_first_in_a_field_is_vietnamese() {
    // Data: `her` is in en.txt and `hẻ` in vi.txt; with no previous word the
    // overlap is Vietnamese (D1), after an English word it is English.
    for caps in MODES {
        assert_eq!(typed(caps, "her "), "hẻ ", "caps {caps:?}");
        assert_eq!(typed(caps, "the her "), "the her ", "caps {caps:?}");
    }
}

#[test]
fn the_boundary_key_emits_the_finished_text_per_edit_mode() {
    for caps in MODES {
        let mut ime = ime();
        let id = ctx(&mut ime, caps);
        let mut app = App::default();
        app.type_str(&mut ime, id, "the best");
        let space = app.send(&mut ime, id, key(' '));
        assert!(!space.handled, "the boundary key still passes");
        assert_eq!(
            space.actions,
            word_end(caps, "bét", "best"),
            "caps {caps:?}"
        );
        assert_eq!(app.text, "the best ");
    }
}

#[test]
fn surrounding_mode_rewrites_nothing_when_the_text_stays() {
    let mut ime = ime();
    let id = ctx(&mut ime, SURROUNDING);
    let mut app = App::default();
    for word in ["the", "vieet", "raats", "bets"] {
        app.type_str(&mut ime, id, word);
        let space = app.send(&mut ime, id, key(' '));
        assert!(space.actions.is_empty(), "{word}");
    }
    assert_eq!(app.text, "the viêt rất bét ");
}

/// A context in `caps` with `the best` typed and not yet ended.
fn typed_the_best(caps: Caps) -> (Ime, CtxId) {
    let mut ime = ime();
    let id = ctx(&mut ime, caps);
    let mut app = App::default();
    app.type_str(&mut ime, id, "the best");
    (ime, id)
}

#[test]
fn every_word_end_event_commits_the_finished_text() {
    for caps in MODES {
        let want = word_end(caps, "bét", "best");
        // Away from the keyboard the cursor may have moved already: a
        // surrounding-text client keeps the shown word (D13).
        let away = if caps == SURROUNDING {
            Vec::new()
        } else {
            want.clone()
        };

        let (mut ime, id) = typed_the_best(caps);
        assert_eq!(ime.focus_out(id), away, "focus-out {caps:?}");

        let (mut ime, id) = typed_the_best(caps);
        assert_eq!(ime.reset(id), away, "reset {caps:?}");

        let (mut ime, id) = typed_the_best(caps);
        assert_eq!(ime.destroy_context(id), away, "destroy {caps:?}");

        let (mut ime, id) = typed_the_best(caps);
        ime.set_enabled(false);
        assert_eq!(ime.take_pending(id), away, "disable {caps:?}");

        let (mut ime, id) = typed_the_best(caps);
        let other = if caps == HOLD { PREEDIT } else { HOLD };
        ime.set_caps(id, other);
        assert_eq!(ime.take_pending(id), want, "set_caps {caps:?}");

        let (mut ime, id) = typed_the_best(caps);
        let actions: Vec<Action> = tap_ctrl_shift(&mut ime, id)
            .into_iter()
            .flat_map(|r| r.actions)
            .collect();
        assert_eq!(actions, want, "mode toggle {caps:?}");
        assert_eq!(ime.mode(), Mode::En);

        let (mut ime, id) = typed_the_best(caps);
        let chord = ime.process_key(id, KeyEvent::press('a' as u32, Mods::CONTROL));
        assert!(!chord.handled);
        assert_eq!(chord.actions, want, "command chord {caps:?}");
    }
}

/// Types `the ` (English), runs `event`, then `best `: Unknown again gives
/// `bét`, a kept English language gives `best`.
fn after_event(event: impl FnOnce(&mut Ime, CtxId)) -> String {
    let mut ime = common::ime();
    let id = ctx(&mut ime, PREEDIT);
    let mut app = App::default();
    app.type_str(&mut ime, id, "the ");
    event(&mut ime, id);
    app.type_str(&mut ime, id, "best ");
    app.text
}

#[test]
fn the_language_starts_over_at_focus_reset_mode_and_enable_changes() {
    assert_eq!(after_event(|_, _| {}), "the best ", "kept without an event");
    assert_eq!(
        after_event(|ime, id| ime.focus_in(id)),
        "the bét ",
        "focus in"
    );
    assert_eq!(
        after_event(|ime, id| {
            ime.focus_out(id);
            ime.focus_in(id);
        }),
        "the bét ",
        "focus out"
    );
    assert_eq!(
        after_event(|ime, id| {
            ime.reset(id);
        }),
        "the bét ",
        "reset"
    );
    assert_eq!(
        after_event(|ime, id| {
            tap_ctrl_shift(ime, id);
            tap_ctrl_shift(ime, id);
        }),
        "the bét ",
        "mode toggle"
    );
    assert_eq!(
        after_event(|ime, _| {
            ime.set_enabled(false);
            ime.set_enabled(true);
        }),
        "the bét ",
        "disable"
    );
}

#[test]
fn the_word_ending_at_a_reset_still_uses_the_language_of_its_context() {
    // `the best` + focus-out commits `best`; the next focus starts Unknown.
    let mut ime = ime();
    let id = ctx(&mut ime, HOLD);
    let mut app = App::default();
    app.type_str(&mut ime, id, "the best");
    app.apply_actions(&ime.focus_out(id));
    ime.focus_in(id);
    app.type_str(&mut ime, id, " best ");
    assert_eq!(app.text, "the best bét ");
}

#[test]
fn contexts_keep_their_own_language() {
    let mut ime = ime();
    let a = ctx(&mut ime, PREEDIT);
    let b = ctx(&mut ime, PREEDIT);
    let mut app_a = App::default();
    let mut app_b = App::default();
    app_a.type_str(&mut ime, a, "the ");
    app_b.type_str(&mut ime, b, "best ");
    app_a.type_str(&mut ime, a, "best ");
    assert_eq!(app_a.text, "the best ");
    assert_eq!(app_b.text, "bét ", "a new context starts Unknown");
}

#[test]
fn english_mode_and_password_fields_pass_every_key() {
    let mut ime = ime_in(Mode::En);
    let id = ctx(&mut ime, PREEDIT);
    let mut app = App::default();
    let results = app.type_str(&mut ime, id, "her the bets use ");
    assert!(results.iter().all(|r| !r.handled && r.actions.is_empty()));
    assert_eq!(app.text, "her the bets use ");

    let mut ime = ime_in(Mode::Vi);
    let id = ctx(&mut ime, PASSWORD);
    let mut app = App::default();
    let results = app.type_str(&mut ime, id, "her the bets use ");
    assert!(results.iter().all(|r| !r.handled && r.actions.is_empty()));
    assert_eq!(app.text, "her the bets use ");
    assert_eq!(ime.buffered_len(id), 0);
}

#[test]
fn an_overlong_run_of_letters_counts_as_english() {
    let mut ime = ime();
    let id = ctx(&mut ime, PREEDIT);
    let mut app = App::default();
    let long = "b".repeat(MAX_WORD_KEYS + 3);
    app.type_str(&mut ime, id, &format!("{long} best "));
    assert_eq!(app.text, format!("{long} best "));
}

#[test]
fn debug_prints_no_word() {
    let (ime, _) = typed_the_best(PREEDIT);
    let shown = format!("{ime:?}");
    assert!(!shown.contains("best") && !shown.contains("bét") && !shown.contains("the"));
}

#[test]
fn surrounding_mode_never_rewrites_after_a_click_or_focus_change() {
    // `the bét` shown, then the cursor moves (click) before the reset arrives:
    // a delete there would remove other text, so nothing is sent (D13).
    let mut ime = ime();
    let id = ctx(&mut ime, SURROUNDING);
    let mut app = App::default();
    app.type_str(&mut ime, id, "hello world");
    app.send(&mut ime, id, key(' '));
    app.type_str(&mut ime, id, "the best");
    assert_eq!(app.text, "hello world the bét");
    assert!(ime.reset(id).is_empty());
    app.type_str(&mut ime, id, "best");
    ime.set_enabled(false);
    assert!(ime.take_pending(id).is_empty(), "disable");
    ime.set_enabled(true);
    app.type_str(&mut ime, id, "best");
    assert!(ime.focus_out(id).is_empty(), "focus out");
    ime.focus_in(id);
    app.type_str(&mut ime, id, "best");
    assert!(ime.destroy_context(id).is_empty(), "destroy");
}

#[test]
fn a_reset_mid_word_or_between_words_replays_the_terminal_flake() {
    // Observed once in gnome-terminal right after the window opened: `has `
    // came out raw and `the best ` as `the bét `. A reset that splits `has`
    // and one between `the ` and `best` give exactly that, with the IME
    // following its rules: a reset ends the word, the next starts Unknown.
    let mut ime = ime();
    let id = ctx(&mut ime, PREEDIT);
    let mut app = App::default();
    app.type_str(&mut ime, id, "ha");
    app.apply_actions(&ime.reset(id));
    app.type_str(&mut ime, id, "s ");
    app.type_str(&mut ime, id, "the ");
    app.apply_actions(&ime.reset(id));
    app.type_str(&mut ime, id, "best ");
    assert_eq!(app.text, "has the bét ");
}
