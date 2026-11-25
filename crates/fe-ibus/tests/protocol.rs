//! The IBus protocol as GNOME Shell 46 uses it (spike T1, Q3), end to end
//! over the private socket: AC-2 ordering, AC-3 commits, AC-4 indicator.

mod common;

use std::time::{Duration, Instant};

use common::*;
use ime_core::Mode;
use zbus::Variant;

const QUIET: Duration = Duration::from_millis(150);

fn panel(member: &str, symbol: &str) -> Seen {
    Seen::Panel(member.to_owned(), symbol.to_owned())
}

#[test]
fn the_call_sequence_of_gnome_shell_ends_in_a_typed_word() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.client().await;

        // Bus level.
        let hello = shell.bus("Hello", &()).await.ok();
        let (name,): (String,) = hello.reply.body().deserialize().unwrap();
        assert!(name.starts_with(":1."));
        assert_eq!(
            shell.unasked(QUIET).await,
            [Seen::Other("NameAcquired".into())]
        );
        let rule = "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged'";
        shell.bus("AddMatch", &(rule,)).await.ok();
        let owner = shell.bus("GetNameOwner", &(IBUS,)).await.ok();
        let (owner,): (String,) = owner.reply.body().deserialize().unwrap();
        assert_eq!(owner, ":1.0");
        let panel_name = shell.bus("RequestName", &(PANEL, 2u32)).await.ok();
        let (granted,): (u32,) = panel_name.reply.body().deserialize().unwrap();
        assert_eq!(granted, 1);
        let owner = shell.bus("GetNameOwner", &(PANEL,)).await.ok();
        let (owner,): (String,) = owner.reply.body().deserialize().unwrap();
        assert_eq!(owner, name);

        // The IBus service.
        let path = shell.create_context().await;
        assert!(path.starts_with("/org/freedesktop/IBus/InputContext_"));
        let engines = shell
            .call(IBUS, IBUS_PATH, PROPERTIES, "Get", &(IBUS, "Engines"))
            .await
            .ok();
        let body = engines.reply.body();
        let (engines,): (Variant<'_>,) = body.deserialize().unwrap();
        assert_eq!(engines.value_signature().to_string(), "av");
        let Variant::Array(engines) = engines else {
            panic!("not an array");
        };
        assert_eq!(engines.len(), 1);
        let Variant::Variant(desc) = &engines[0] else {
            panic!("not a variant");
        };
        assert_eq!(
            desc.value_signature().to_string(),
            "(sa{sv}ssssssssussssssss)"
        );

        let global = shell
            .call(IBUS, IBUS_PATH, PROPERTIES, "Get", &(IBUS, "GlobalEngine"))
            .await
            .ok();
        let body = global.reply.body();
        let (global,): (Variant<'_>,) = body.deserialize().unwrap();
        assert_eq!(global.value_signature().to_string(), "v");

        // An engine is always active: its properties follow the answer.
        assert_eq!(
            shell.unasked(QUIET).await.last(),
            Some(&panel("RegisterProperties", "vi"))
        );

        let set = shell.ibus("SetGlobalEngine", &("vr-talex",)).await.ok();
        assert_eq!(set.before, [], "the reply comes first");
        assert_eq!(
            shell.unasked(QUIET).await,
            [
                Seen::Other("GlobalEngineChanged".into()),
                panel("RegisterProperties", "vi"),
            ]
        );

        // The input context.
        let all = shell
            .call(IBUS, &path, PROPERTIES, "GetAll", &(CONTEXT,))
            .await
            .ok();
        assert_eq!(all.reply.body().signature().to_string(), "a{sv}");
        shell.set(&path, "ClientCommitPreedit", (true,)).await.ok();
        shell
            .context(&path, "SetCapabilities", &(41u32,))
            .await
            .ok();
        shell.set(&path, "ContentType", (10u32, 0u32)).await.ok();
        shell.context(&path, "FocusIn", &()).await.ok();
        shell
            .context(&path, "SetCursorLocation", &(1i32, 2i32, 3i32, 4i32))
            .await
            .ok();
        shell.unasked(QUIET).await;

        let mut shown = Vec::new();
        for letter in "vieetj".chars() {
            let answer = shell.tap(&path, letter as u32).await;
            assert!(answer.handled());
            // The cursor rectangle follows each preedit and ends no word.
            shell
                .context(&path, "SetCursorLocation", &(1i32, 2i32, 3i32, 4i32))
                .await
                .ok();
            shown.extend(answer.before);
        }
        assert_eq!(
            shown,
            ["v", "vi", "vie", "viê", "viêt", "việt"].map(preedit)
        );

        // The word ends: the commit is written before the reply that sends
        // the space on to the application.
        let space = shell.key(&path, KEY_SPACE, 0).await;
        assert!(!space.handled());
        assert_eq!(space.before, [Seen::Commit("việt".into()), hidden(Some(0))]);
        assert_eq!(shell.unasked(QUIET).await, []);
    });
}

#[test]
fn keys_sent_without_waiting_are_answered_in_order() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        let path = shell.shell_context().await;
        shell.unasked(QUIET).await;

        // Press and release of each key back to back, a whole word and the
        // space after it, before reading a single reply (spike Q3, B2).
        let mut serials = Vec::new();
        for keysym in "tieesng".chars().map(|c| c as u32).chain([KEY_SPACE]) {
            for state in [0, RELEASE] {
                let call = (keysym, 0u32, state);
                serials.push(
                    shell
                        .send(IBUS, &path, CONTEXT, "ProcessKeyEvent", &call)
                        .await,
                );
            }
        }
        let mut handled = Vec::new();
        let mut written = Vec::new();
        for serial in serials {
            let answer = shell.answer(serial).await;
            handled.push(answer.handled());
            written.push(answer.before);
        }
        // Presses of letters are handled, releases and the space are not.
        let expected: Vec<bool> = (0..16).map(|at| at % 2 == 0 && at < 14).collect();
        assert_eq!(handled, expected);
        let texts = ["t", "ti", "tie", "tiê", "tiế", "tiến", "tiếng"];
        for (at, text) in texts.iter().enumerate() {
            assert_eq!(written[at * 2], [preedit(text)]);
            assert_eq!(written[at * 2 + 1], []);
        }
        assert_eq!(written[14], [Seen::Commit("tiếng".into()), hidden(Some(0))]);
        assert_eq!(written[15], []);
    });
}

#[test]
fn a_ctrl_shift_tap_updates_the_indicator_and_commits_the_word() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        shell.bus("RequestName", &(PANEL, 2u32)).await.ok();
        let path = shell.shell_context().await;
        shell.unasked(QUIET).await;

        shell.type_letters(&path, "vieet").await;
        let mut caused = shell.tap_ctrl_shift(&path).await;
        caused.extend(shell.unasked(QUIET).await);
        assert_eq!(
            caused,
            [
                Seen::Commit("viêt".into()),
                hidden(Some(0)),
                panel("UpdateProperty", "en"),
            ]
        );
        assert_eq!(bus.ime.mode(), Mode::En);

        // English: keys pass untouched.
        assert!(!shell.tap(&path, 'a' as u32).await.handled());

        let mut caused = shell.tap_ctrl_shift(&path).await;
        caused.extend(shell.unasked(QUIET).await);
        assert_eq!(caused, [panel("UpdateProperty", "vi")]);
    });
}

#[test]
fn ctrl_shift_with_another_key_does_not_toggle() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        shell.bus("RequestName", &(PANEL, 2u32)).await.ok();
        let path = shell.shell_context().await;
        shell.unasked(QUIET).await;

        // Ctrl+Shift+T.
        for (keysym, state) in [
            (KEY_CONTROL_L, 0),
            (KEY_SHIFT_L, CONTROL),
            ('T' as u32, CONTROL | SHIFT),
            ('T' as u32, CONTROL | SHIFT | RELEASE),
            (KEY_SHIFT_L, CONTROL | SHIFT | RELEASE),
            (KEY_CONTROL_L, CONTROL | RELEASE),
        ] {
            let answer = shell.key(&path, keysym, state).await;
            assert!(!answer.handled(), "the shortcut reaches the application");
            assert_eq!(answer.before, []);
        }
        assert_eq!(shell.unasked(QUIET).await, []);
        assert_eq!(bus.ime.mode(), Mode::Vi);
    });
}

#[test]
fn a_toggle_made_through_another_frontend_reaches_the_panel() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        shell.bus("RequestName", &(PANEL, 2u32)).await.ok();
        shell.unasked(QUIET).await;

        // A context of another frontend (fe-fcitx) toggles the global mode.
        let other = bus.ime.create_context();
        use ime_core::{KeyEvent, Mods, keysym};
        for event in [
            KeyEvent::press(keysym::CONTROL_L, Mods::NONE),
            KeyEvent::press(keysym::SHIFT_L, Mods::CONTROL),
            KeyEvent::release(keysym::SHIFT_L, Mods::CONTROL | Mods::SHIFT),
            KeyEvent::release(keysym::CONTROL_L, Mods::CONTROL),
        ] {
            bus.ime.process_key(other, event);
        }
        assert_eq!(bus.ime.mode(), Mode::En);
        assert_eq!(shell.unasked(QUIET).await, [panel("UpdateProperty", "en")]);
    });
}

#[test]
fn focus_out_and_reset_leave_the_commit_to_a_client_that_commits_its_preedit() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        let path = shell.shell_context().await;
        shell.unasked(QUIET).await;

        // AC-3: GNOME Shell commits the preedit it shows when the field
        // loses focus (the preedit was sent in "commit" mode). A second
        // CommitText would double the word.
        for leave in ["FocusOut", "Reset"] {
            let last = shell.type_letters(&path, "vieet").await;
            assert_eq!(last, [preedit("viêt")]);
            let answer = shell.context(&path, leave, &()).await.ok();
            assert_eq!(answer.before, [hidden(Some(0))], "{leave}");

            // The word is gone from the engine: the next one starts afresh.
            shell.context(&path, "FocusIn", &()).await.ok();
            let last = shell.type_letters(&path, "as").await;
            assert_eq!(last, [preedit("á")], "{leave}");
            let space = shell.key(&path, KEY_SPACE, 0).await;
            assert_eq!(space.before, [Seen::Commit("á".into()), hidden(Some(0))]);
        }
        // Nothing to commit: nothing is written at all.
        let answer = shell.context(&path, "Reset", &()).await.ok();
        assert_eq!(answer.before, []);
    });
}

#[test]
fn gnome_shells_focus_out_in_a_terminal_leaves_the_word_to_the_compositor() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        let path = shell.shell_context().await;
        shell.unasked(QUIET).await;
        // gnome-terminal through the shell: purpose TERMINAL.
        shell.set(&path, "ContentType", (10u32, 0u32)).await.ok();
        let last = shell.type_letters(&path, "vieet").await;
        // "Commit" mode: Mutter keeps this preedit and commits it itself
        // when the text-input focus moves (clutter_input_focus_reset),
        // before the shell's focus-out reaches the engine.
        assert_eq!(last, [preedit("viêt")]);

        // inputMethod.js `vfunc_focus_out`: `_fullReset` (content type
        // cleared, cursor cleared, Reset), then FocusOut. A CommitText in
        // any of these answers would come after Mutter's commit.
        let content = shell.set(&path, "ContentType", (0u32, 0u32)).await.ok();
        assert_eq!(content.before, []);
        let cursor = shell
            .context(&path, "SetCursorLocation", &(0i32, 0i32, 0i32, 0i32))
            .await
            .ok();
        assert_eq!(cursor.before, []);
        let reset = shell.context(&path, "Reset", &()).await.ok();
        assert_eq!(reset.before, [hidden(Some(0))]);
        let focus_out = shell.context(&path, "FocusOut", &()).await.ok();
        assert_eq!(focus_out.before, []);

        // The word ended there: the next one starts afresh.
        shell.context(&path, "FocusIn", &()).await.ok();
        let last = shell.type_letters(&path, "as").await;
        assert_eq!(last, [preedit("á")]);
    });
}

#[test]
fn a_client_that_does_not_commit_its_preedit_gets_the_word_once() {
    block_on(async {
        let bus = Bus::start().await;
        let mut client = bus.greeted().await;
        // No ClientCommitPreedit: a Qt 5 application.
        let path = client.create_context().await;
        client
            .context(&path, "SetCapabilities", &(9u32,))
            .await
            .ok();
        client.context(&path, "FocusIn", &()).await.ok();
        let shown = Seen::Preedit {
            text: "viêt".into(),
            cursor: 4,
            visible: true,
            mode: None,
        };

        // Qt 5 moves focus or the cursor with `commit()`: it inserts the
        // preedit it holds, then sends Reset. A CommitText would land a
        // second copy in whatever has the focus by then (seen in a Qt 5
        // QLineEdit, qa-artifacts/T5/qt5). The word only leaves the engine.
        let last = client.type_letters(&path, "vieet").await;
        assert_eq!(last, std::slice::from_ref(&shown));
        let answer = client.context(&path, "Reset", &()).await.ok();
        assert_eq!(answer.before, [hidden(None)]);
        let last = client.type_letters(&path, "as").await;
        assert_eq!(last[0], preedit_plain("á"), "the next word starts afresh");
        client.context(&path, "Reset", &()).await.ok();

        // A FocusOut that no Reset preceded still delivers the word.
        let last = client.type_letters(&path, "vieet").await;
        assert_eq!(last, [shown]);
        let answer = client.context(&path, "FocusOut", &()).await.ok();
        assert_eq!(answer.before, [Seen::Commit("viêt".into()), hidden(None)]);

        // A held word was never shown: Reset sends it.
        client.context(&path, "FocusIn", &()).await.ok();
        client
            .context(&path, "SetCapabilities", &(8u32,))
            .await
            .ok();
        client.type_letters(&path, "as").await;
        let answer = client.context(&path, "Reset", &()).await.ok();
        assert_eq!(answer.before, [Seen::Commit("á".into())]);
    });
}

/// A preedit sent without a focus mode, cursor at its end.
fn preedit_plain(text: &str) -> Seen {
    Seen::Preedit {
        text: text.into(),
        cursor: text.chars().count() as u32,
        visible: true,
        mode: None,
    }
}

#[test]
fn a_client_without_preedit_gets_the_word_at_the_boundary() {
    block_on(async {
        let bus = Bus::start().await;
        let mut client = bus.greeted().await;
        let path = client.create_context().await;
        // FOCUS only: neither preedit nor surrounding text (D10: hold).
        client
            .context(&path, "SetCapabilities", &(8u32,))
            .await
            .ok();
        assert_eq!(client.type_letters(&path, "vieetj").await, []);
        let space = client.key(&path, KEY_SPACE, 0).await;
        assert!(!space.handled());
        assert_eq!(space.before, [Seen::Commit("việt".into())]);

        // Held words have no preedit the client could commit: FocusOut
        // sends them even to a client that commits its own preedit.
        client.set(&path, "ClientCommitPreedit", (true,)).await.ok();
        client.type_letters(&path, "as").await;
        let answer = client.context(&path, "FocusOut", &()).await.ok();
        assert_eq!(answer.before, [Seen::Commit("á".into())]);
    });
}

#[test]
fn a_client_with_surrounding_text_only_gets_deletes_and_commits() {
    block_on(async {
        let bus = Bus::start().await;
        let mut client = bus.greeted().await;
        let path = client.create_context().await;
        client
            .context(&path, "SetCapabilities", &(32u32,))
            .await
            .ok();
        assert_eq!(
            client.tap(&path, 'a' as u32).await.before,
            [Seen::Commit("a".into())]
        );
        assert_eq!(
            client.tap(&path, 's' as u32).await.before,
            [Seen::Delete(-1, 1), Seen::Commit("á".into())]
        );
    });
}

#[test]
fn password_fields_get_their_keys_untouched() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        let path = shell.shell_context().await;
        shell.unasked(QUIET).await;

        // (purpose, hints): password, PIN, and the private hint.
        for content in [(8u32, 0u32), (9, 0), (0, 1 << 11)] {
            shell.set(&path, "ContentType", content).await.ok();
            for letter in "matkhau1s".chars() {
                let answer = shell.tap(&path, letter as u32).await;
                assert!(!answer.handled(), "{content:?}");
                assert_eq!(answer.before, [], "{content:?}");
            }
            assert_eq!(shell.unasked(QUIET).await, []);
        }
    });
}

#[test]
fn a_field_turning_into_a_password_field_commits_the_word_first() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        let path = shell.shell_context().await;
        shell.unasked(QUIET).await;

        shell.type_letters(&path, "vieet").await;
        // SEC-13: the word typed so far belongs to the old field.
        let answer = shell.set(&path, "ContentType", (8u32, 0u32)).await.ok();
        assert_eq!(
            answer.before,
            [Seen::Commit("viêt".into()), hidden(Some(0))]
        );
        let key = shell.tap(&path, 's' as u32).await;
        assert!(!key.handled());
        assert_eq!(key.before, []);

        // And back: composing works again.
        shell.set(&path, "ContentType", (0u32, 0u32)).await.ok();
        assert_eq!(shell.type_letters(&path, "as").await, [preedit("á")]);
    });
}

#[test]
fn a_destroyed_context_is_gone() {
    block_on(async {
        let bus = Bus::start().await;
        let mut client = bus.greeted().await;
        let path = client.shell_context().await;
        client.type_letters(&path, "a").await;
        let destroyed = client.call(IBUS, &path, SERVICE, "Destroy", &()).await.ok();
        assert_eq!(destroyed.before, []);
        let key = client.key(&path, 'a' as u32, 0).await;
        assert_eq!(
            key.error().as_deref(),
            Some("org.freedesktop.DBus.Error.UnknownObject")
        );
    });
}

#[test]
fn several_clients_type_at_the_same_time_without_mixing() {
    block_on(async {
        let bus = Bus::start().await;
        // D20: GNOME Shell plus applications with their own IBus client.
        let mut shell = bus.greeted().await;
        let mut qt = bus.greeted().await;
        let shell_path = shell.shell_context().await;
        let qt_path = qt.shell_context().await;
        assert_ne!(shell_path, qt_path);
        shell.unasked(QUIET).await;
        qt.unasked(QUIET).await;

        for (a, b) in "vieetj".chars().zip("dduowf".chars()) {
            assert!(shell.tap(&shell_path, a as u32).await.handled());
            assert!(qt.tap(&qt_path, b as u32).await.handled());
        }
        let space = shell.key(&shell_path, KEY_SPACE, 0).await;
        assert_eq!(space.before, [Seen::Commit("việt".into()), hidden(Some(0))]);
        let space = qt.key(&qt_path, KEY_SPACE, 0).await;
        assert_eq!(space.before, [Seen::Commit("đườ".into()), hidden(Some(0))]);
    });
}

/// `IBUS_INPUT_PURPOSE_URL`.
const PURPOSE_URL: u32 = 5;

#[test]
fn in_an_address_field_the_preedit_is_cleared_before_the_word_is_committed() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        let path = shell.shell_context().await;
        shell
            .set(&path, "ContentType", (PURPOSE_URL, 0u32))
            .await
            .ok();
        shell.unasked(QUIET).await;

        // Chrome deletes the inline completion of its address bar when the
        // preedit changes in the same text-input `done` as the commit: the
        // preedit has to be gone, in a `done` of its own, before the commit.
        assert_eq!(shell.type_letters(&path, "git").await, [preedit("git")]);
        let serial = shell
            .send(
                IBUS,
                &path,
                CONTEXT,
                "ProcessKeyEvent",
                &(KEY_RETURN, 0u32, 0u32),
            )
            .await;
        let hide = shell.next(QUIET).await.expect("the preedit is cleared");
        let cleared = Instant::now();
        assert_eq!(seen(&hide), hidden(Some(0)));
        let commit = shell.next(QUIET).await.expect("the word is committed");
        let gap = cleared.elapsed();
        assert_eq!(seen(&commit), Seen::Commit("git".into()));
        assert!(gap >= Duration::from_millis(3), "committed after {gap:?}");
        let enter = shell.answer(serial).await;
        assert_eq!(enter.before, []);
        assert!(!enter.handled(), "the key goes on to the address bar");

        // Everywhere else the commit replaces the preedit in one step.
        shell.set(&path, "ContentType", (0u32, 0u32)).await.ok();
        shell.type_letters(&path, "git").await;
        let enter = shell.key(&path, KEY_RETURN, 0).await;
        assert_eq!(enter.before, [Seen::Commit("git".into()), hidden(Some(0))]);
    });
}

#[test]
fn in_an_address_field_tab_ends_the_word_and_the_enter_after_it_is_the_clients_alone() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        let path = shell.shell_context().await;
        shell
            .set(&path, "ContentType", (PURPOSE_URL, 0u32))
            .await
            .ok();
        shell.unasked(QUIET).await;

        // Tab accepts the address bar's completion: the word goes out as for
        // Enter, and the key goes on to the client.
        assert_eq!(shell.type_letters(&path, "git").await, [preedit("git")]);
        let tab = shell.key(&path, KEY_TAB, 0).await;
        assert_eq!(tab.before, [hidden(Some(0)), Seen::Commit("git".into())]);
        assert!(!tab.handled());
        let release = shell.key(&path, KEY_TAB, RELEASE).await;
        assert_eq!(release.before, []);
        assert!(!release.handled());

        // What the client made of the Tab (the completed address, a row of
        // its list) is its own: the Enter that follows changes none of it.
        let enter = shell.key(&path, KEY_RETURN, 0).await;
        assert_eq!(enter.before, []);
        assert!(!enter.handled());
        let release = shell.key(&path, KEY_RETURN, RELEASE).await;
        assert_eq!(release.before, []);
        assert!(!release.handled());
        assert_eq!(shell.unasked(QUIET).await, []);

        // Nothing of the ended word comes back with the next one.
        assert_eq!(shell.type_letters(&path, "a").await, [preedit("a")]);
    });
}

#[test]
fn gnome_shell_never_gets_a_delete_surrounding_text() {
    // Mutter 46 aborts (the whole session goes down) on a
    // DeleteSurroundingText that does not fit the surrounding text it holds,
    // and that text lags behind the keys.
    const SURROUNDING_ONLY: u32 = 32;
    async fn word_without_delete(client: &mut Client, path: &str) {
        let mut all = Vec::new();
        for letter in "as".chars() {
            all.extend(client.tap(path, letter as u32).await.before);
        }
        all.extend(client.key(path, KEY_SPACE, 0).await.before);
        assert_eq!(all, [Seen::Commit("á".into())]);
    }
    block_on(async {
        // The connection that owns the panel is GNOME Shell.
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        shell.bus("RequestName", &(PANEL, 2u32)).await.ok();
        let path = shell.create_context().await;
        shell
            .context(&path, "SetCapabilities", &(SURROUNDING_ONLY,))
            .await
            .ok();
        shell.unasked(QUIET).await;
        word_without_delete(&mut shell, &path).await;

        // A context of its own preedit commits is one of GNOME Shell's too,
        // whichever of the two settings comes first.
        let mut client = bus.greeted().await;
        let first = client.create_context().await;
        client
            .set(&first, "ClientCommitPreedit", (true,))
            .await
            .ok();
        client
            .context(&first, "SetCapabilities", &(SURROUNDING_ONLY,))
            .await
            .ok();
        word_without_delete(&mut client, &first).await;
        let second = client.create_context().await;
        client
            .context(&second, "SetCapabilities", &(SURROUNDING_ONLY,))
            .await
            .ok();
        client
            .set(&second, "ClientCommitPreedit", (true,))
            .await
            .ok();
        word_without_delete(&mut client, &second).await;

        // A context made before the connection became the panel.
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        let path = shell.create_context().await;
        shell
            .context(&path, "SetCapabilities", &(SURROUNDING_ONLY,))
            .await
            .ok();
        shell.bus("RequestName", &(PANEL, 2u32)).await.ok();
        shell.unasked(QUIET).await;
        word_without_delete(&mut shell, &path).await;
    });
}

const ACCESS_DENIED: &str = "org.freedesktop.DBus.Error.AccessDenied";
const INVALID_ARGS: &str = "org.freedesktop.DBus.Error.InvalidArgs";

#[test]
fn an_xkb_source_switches_the_ime_off_and_the_engine_back_on() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        shell.bus("RequestName", &(PANEL, 2u32)).await.ok();
        let path = shell.shell_context().await;
        shell.unasked(QUIET).await;

        // The user picks the US layout with a word in progress: the word is
        // committed with the switch (D33, B3).
        shell.type_letters(&path, "vieet").await;
        let off = shell.ibus("SetGlobalEngine", &("xkb:us::eng",)).await.ok();
        assert_eq!(off.before, [Seen::Commit("viêt".into()), hidden(Some(0))]);
        assert_eq!(
            shell.unasked(QUIET).await,
            [Seen::Other("GlobalEngineChanged".into())]
        );
        assert!(!bus.ime.enabled());

        // Off: keys pass raw and Ctrl+Shift neither toggles nor touches the indicator.
        let j = shell.tap(&path, 'j' as u32).await;
        assert!(!j.handled());
        assert_eq!(j.before, []);
        let mut caused = shell.tap_ctrl_shift(&path).await;
        caused.extend(shell.unasked(QUIET).await);
        assert_eq!(caused, []);
        assert_eq!(bus.ime.mode(), Mode::Vi);

        // Back to the engine: on again in the kept mode, shown in the indicator.
        shell.ibus("SetGlobalEngine", &("vr-talex",)).await.ok();
        assert_eq!(
            shell.unasked(QUIET).await,
            [
                Seen::Other("GlobalEngineChanged".into()),
                panel("RegisterProperties", "vi"),
            ]
        );
        assert!(bus.ime.enabled());
        shell.type_letters(&path, "dd").await;
        let mut caused = shell.tap_ctrl_shift(&path).await;
        caused.extend(shell.unasked(QUIET).await);
        assert_eq!(
            caused,
            [
                Seen::Commit("đ".into()),
                hidden(Some(0)),
                panel("UpdateProperty", "en"),
            ]
        );
    });
}

#[test]
fn only_the_panel_switches_the_ime_off() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        shell.bus("RequestName", &(PANEL, 2u32)).await.ok();
        let mut app = bus.greeted().await;

        // Another client of the same user cannot turn Vietnamese off for all (SEC-10).
        let denied = app.ibus("SetGlobalEngine", &("xkb:us::eng",)).await;
        assert_eq!(denied.error().as_deref(), Some(ACCESS_DENIED));
        assert!(bus.ime.enabled());
        // Selecting the engine stays harmless for anyone.
        app.ibus("SetGlobalEngine", &("vr-talex",)).await.ok();
        assert!(bus.ime.enabled());

        // Names that are neither the engine nor a bounded xkb name are refused.
        let long = format!("xkb:{}", "a".repeat(200));
        for name in ["xkb:", "pinyin", long.as_str(), "xkb:us\n"] {
            let bad = shell.ibus("SetGlobalEngine", &(name,)).await;
            assert_eq!(bad.error().as_deref(), Some(INVALID_ARGS), "{name:?}");
        }
        assert!(bus.ime.enabled());
    });
}

#[test]
fn a_word_of_another_frontend_is_kept_across_the_switch() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        shell.bus("RequestName", &(PANEL, 2u32)).await.ok();

        // A context of fe-fcitx with a word in progress.
        use ime_core::{Action, Caps, KeyEvent, Mods};
        let other = bus.ime.create_context();
        let caps = Caps {
            preedit: true,
            surrounding_text: false,
            password: false,
        };
        bus.ime.set_caps(other, caps);
        for c in "dd".chars() {
            bus.ime
                .process_key(other, KeyEvent::press(c as u32, Mods::NONE));
        }
        shell.ibus("SetGlobalEngine", &("xkb:us::eng",)).await.ok();
        let next = bus
            .ime
            .process_key(other, KeyEvent::press('a' as u32, Mods::NONE));
        assert!(!next.handled);
        assert_eq!(
            next.actions,
            [Action::HidePreedit, Action::Commit("đ".into())]
        );
    });
}

#[test]
fn the_ime_is_on_again_when_the_panel_leaves() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        shell.bus("RequestName", &(PANEL, 2u32)).await.ok();
        shell.ibus("SetGlobalEngine", &("xkb:us::eng",)).await.ok();
        assert!(!bus.ime.enabled());

        // Nobody else may switch it on, so a shell that is gone must not leave it off.
        drop(shell);
        let start = std::time::Instant::now();
        while !bus.ime.enabled() && start.elapsed() < Duration::from_secs(2) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(bus.ime.enabled());
    });
}

fn name_result(answer: &Answer) -> u32 {
    let (code,): (u32,) = answer.reply.body().deserialize().expect("(u)");
    code
}

#[test]
fn the_ime_is_on_again_when_the_panel_releases_its_name() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        shell.bus("RequestName", &(PANEL, 2u32)).await.ok();
        let mut app = bus.greeted().await;
        shell.ibus("SetGlobalEngine", &("xkb:us::eng",)).await.ok();
        assert!(!bus.ime.enabled());

        // Another client cannot release the panel's name, so the IME stays off.
        let denied = app.bus("ReleaseName", &(PANEL,)).await.ok();
        assert_eq!(name_result(&denied), 3);
        assert!(!bus.ime.enabled());

        // The panel gives the name up while staying connected: nobody could
        // switch the IME on any more, so it is on again.
        let released = shell.bus("ReleaseName", &(PANEL,)).await.ok();
        assert_eq!(name_result(&released), 1);
        assert!(bus.ime.enabled());
        let path = shell.shell_context().await;
        shell.unasked(QUIET).await;
        // A typed word composes again (every letter is handled) and commits at the space.
        shell.type_letters(&path, "dd").await;
        let space = shell.tap(&path, ' ' as u32).await;
        assert!(space.before.contains(&Seen::Commit("đ".into())));
    });
}
