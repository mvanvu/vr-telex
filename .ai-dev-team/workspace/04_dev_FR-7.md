# FR-7 Bug (live desktop): Ctrl+Shift toggles the mode but the GNOME top-bar indicator does not change VI/EN

## Progress
- started; worktree /home/rainy/DEV/vr-talex-wt-FR7 (branch fr7-indicator), read fe-ibus session.rs/server.rs, ime-core ModeWatch
- live observation (read-only): vr-talex pid 2481453 active since 03:55:09; exactly one client on /run/user/1000/vr-talex/ibus = gnome-shell pid 6637 fd 92; mode file = VI; gsettings sources [('xkb','us'),('xkb','vn'),('ibus','vr-talex')] (brief said 2 sources), mru [vr-talex, us, vn]; gnome-shell journal: 5x "GDBus.Error:org.freedesktop.DBus.Error.InvalidArgs" from ibusManager._setEngine (03:55:10 x2, 03:58:55, 04:00:08, 04:00:10, 04:00:14) = SetGlobalEngine('xkb:us::eng') refused by fe-ibus
- GNOME 46 sources extracted to qa-artifacts/FR-7/gs/ (ibusManager.js, keyboard.js) for reading
- added e2e scenario 'indicator' (tests/e2e/run.sh) + SHELL_IME_JS diagnostic (tests/e2e/lib.sh); release build ok; before-replay: --route fcitx
- e2e before (scenario indicator, --route fcitx, engine picked explicitly): PASS -> qa-artifacts/FR-7/before-fcitx.log (symptom not in that path)
- probe1 (qa-artifacts/FR-7/probe/probe1.log): live-like sources, current 'us' at connect; after switching to vr-talex toggles move the indicator. Shell keeps a register-properties handler waiting from connect (race), harmless
- probe2 (probe2-fcitx.log, probe2-ibus.log): replay of the live install (shell on [us], daemon connects, install.sh's mru-then-sources writes) -> shell stays on 'us' (label en), typing converts and toggles flip the mode, indicator never changes = USER SYMPTOM REPRODUCED on both routes
- root cause: (R1) fe-ibus refuses SetGlobalEngine('xkb:us::eng') (session.rs SetGlobalEngine arm) so conversion stays on while the shell shows an xkb source; (R2) a running shell keeps its in-memory MRU (keyboard.js _updateMruSources) so install.sh's mru write does not select vr-talex; mru is re-read from settings only on an IBus ready change
- add-on 1 (longname): keyboard.js builds displayName = `${IBus.get_language_name(lang)} (${longname})` -> longname "Telex"; red test engine_desc_has_the_libibus_layout then green
- add-on 2 (D32 lowercase): ibus.rs indicator_symbol() vi/en for engine symbol + InputMode symbol; state file keeps VI/EN (Mode::symbol); tests protocol.rs/security.rs updated; harness CUR_LABEL_JS / INDICATOR_JS upper-case the label
- cargo test -p fe-ibus: lib 25 ok, address 12 ok, protocol 13 ok, security 15 ok; latency FAILED twice under load avg 27 (p99 14.8 ms) — not mine: load, key path untouched
- after (qa-artifacts/FR-7/after-fcitx.log, after-ibus.log, rebuilt daemon): AC-4:indicator PASS on fcitx (VI->EN 34 ms, EN->VI 17 ms) and ibus (3 ms / 3 ms), terminal got [việt vieetj ], shell source-symbol=vi; AC-4 (Chrome) PASS ibus route (3/1 ms); fcitx-route run AC-4 Chrome VI->EN 102 ms (load avg ~27 from other agents' runs; same check 4 ms in before-fcitx.log) -> timing noise, rerun when the machine is idle
- SEC-1 PASS in both after runs (the 2 hits in before-fcitx.log/probe were /tmp/flutter_tools.* files of another project, not ours)
- STATUS: BLOCKED needs-user-decision on R1 (what an xkb source means for the engine); R2 is install.sh (outside fe-ibus) — proposals below. Add-ons (longname, D32 lowercase) done.

## Root cause (evidence)
- Live (read-only): journal of gnome-shell 6637 has 5 InvalidArgs from ibusManager._setEngine = shell activated the xkb source 'us' and fe-ibus refused SetGlobalEngine('xkb:us::eng'); 03:55:10 #1 comes from _ibusReadyCallback (connect), #2 from _emitInputSourcesChanged (install.sh writes). Settings mru head is vr-talex only because install.sh wrote it; the shell's in-memory MRU head was 'us'.
- Sandbox replay (probe2, both routes) gives exactly the user's symptom: state [us|en] throughout, Vietnamese typed, Ctrl+Shift flips the mode, top bar stays "en".
- When the vr-talex source is the current one (probe1, e2e 'indicator'), the toggle moves the indicator within 100 ms on both routes: the fe-ibus ModeWatch -> UpdateProperty path works (existing test a_toggle_made_through_another_frontend_reaches_the_panel).

## Files changed
- crates/fe-ibus/src/ibus.rs (longname "Telex", indicator_symbol vi/en, unit tests), crates/fe-ibus/tests/protocol.rs, crates/fe-ibus/tests/security.rs (vi/en), crates/ime-core/src/ime.rs (doc comment of Mode::symbol only)
- tests/e2e/run.sh (scenario 'indicator'), tests/e2e/lib.sh (CUR_LABEL_JS upper-cased, SHELL_IME_JS), tests/e2e/e2e.py (INDICATOR_JS upper-cased), tests/e2e/stub_ime.py (longname "Telex")

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| fcitx-route terminal in the sandbox | tests/e2e/run.sh --route | reused --route fcitx |
| toggle timing | e2e.py toggle-check | reused with empty --combo |
| test of ModeWatch -> UpdateProperty | crates/fe-ibus/tests/protocol.rs | exists (a_toggle_made_through_another_frontend_reaches_the_panel), kept |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 | pass | scope: fe-ibus + harness only; R1/R2 behaviour not changed without a decision |
| BASE-3 | pass | red: engine_desc_has_the_libibus_layout / mode_property_carries_the_symbol_of_each_mode failed (left "Vietnamese (Telex)"/"VI"), then green |
| BASE-7/24 | pass | worktree /home/rainy/DEV/vr-talex-wt-FR7, no commit |
| BASE-19 | pass | this file |
| BASE-37 | pass | user's steps replayed before (probe2-*.log, symptom reproduced) and after (after-*.log) |
| COST-1..20 | pass | heavy runs through run-heavy.sh, background for long ones, edits with Edit, throwaway scripts in qa-artifacts/FR-7, only own processes; leftover sandbox processes belong to FR-8 |
| SEC-1 | pass | after-*.log SEC-1 PASS 0 hits; fe-ibus still logs nothing |
| SEC-9 | pass | session.rs untouched; tests/security.rs 15 ok |
| SEC-10 | pass | panel claim untouched; protocol/security tests ok |
| live permission | pass | live: only journalctl, systemctl status, ss, /proc fd list, gsettings get, gdbus GetNameOwner/NameHasOwner, reading extension files; nothing changed |

## Round 2 (D33, option A: R1 in fe-ibus)
- red: crates/ime-core/tests/enabled.rs did not compile (no set_enabled/enabled/take_pending); protocol.rs 3 new tests failed with InvalidArgs on SetGlobalEngine('xkb:us::eng')
- code: ime-core Ime::enabled/set_enabled (off: every context's word flushed into pending, taps reset; process_key passes everything while off), SharedIme::enabled/set_enabled/take_pending; fe-ibus SetGlobalEngine accepts bounded `xkb:*` names from the panel owner only (others AccessDenied, SEC-10), commits this connection's words before the reply, echoes GlobalEngineChanged; vr-talex from the panel turns it on (RegisterProperties with the kept mode); panel leaving / ReleaseName turns it on (no stuck-off)
- green: ime-core enabled 8 ok + all ime-core suites ok; fe-ibus lib 25, protocol 17, security 15 (security test updated: pinyin InvalidArgs, xkb from non-panel AccessDenied); fe-fcitx all ok
- e2e 'indicator' extended: Ctrl+Space (sandbox keybinding as live: ['<Control>space']) with a word in progress -> us, raw typing, Ctrl+Shift inert, Ctrl+Space back -> vr-talex|VI, "dd " converts
- first after2 e2e run: AC-4:indicator FAIL both routes, terminal [việt vieetj j aa đ ] — word "viêt" typed before Ctrl+Space missing
- probe3 (probe/probe3-*.log) + probe3-oldbin.log (MASTER binary, before FR-7): gnome-terminal loses a word in progress on every focus-out, with or without this change ([j x ] expected [viêtj đx ]). Temporary call trace (probe7, eprintln of call names only, removed; `grep -rn FR7-PROBE crates` empty): each `e2e.py inject` ends with Reset+FocusOut of the field (virtual keyboard torn down), and the Ctrl+Space popup sends Reset+FocusOut BEFORE SetGlobalEngine. The word leaves the engine at that FocusOut (skipped commit, client-commits-preedit rule, T5) and gnome-terminal never gets it. Experiment "no hide either on that skip" (probe8): still lost -> reverted. => pre-existing AC-3 gap for gnome-terminal (GTK3 im-wayland), not caused by D33; out of scope, reported
- scenario adjusted: the Ctrl+Space part runs in one inject session with complete words (no harness focus-out mid-word)
- final run (after2.sh -> after3-*.log): cargo test ime-core all ok (latency ok), fe-ibus lib 25/address 12/latency ok (load 13.6)/protocol 17/security 15, fe-fcitx 10+15, vr-talex 14; guard: fmt ok, clippy -D warnings clean; e2e AC-4:indicator PASS fcitx and ibus, AC-4 PASS both, SEC-1 PASS 0 hits both
- replay of the live install after the fix (after3-probe2-*.log): shell stays on us (R2, FR-9) but now typing is raw and consistent with the label: fcitx [vieetj vieetj ]; ibus first run [] (terminal file empty, flake), rerun after3-probe2-ibus-rerun.log [vieetj vieetj ]

| Rule | Status | Evidence |
|---|---|---|
| BASE-3 (round 2) | pass | red: enabled.rs compile errors (no set_enabled), protocol 3 FAILED InvalidArgs; green above |
| BASE-37 (round 2) | pass | replay before (probe2-*.log: converts under "en") / after (after3-probe2-*.log: raw under "en") |
| BASE-48 | pass | states quoted from read-back output (IME_STATE / SHELL_IME_JS Eval reads in the sandbox, terminal file content) |
| SEC-10 | pass | only_the_panel_switches_the_ime_off (non-panel xkb -> AccessDenied), security.rs only_the_ibus_surface_is_served |

## Fix round 1
- Finding 1 (major): added `the_ime_is_on_again_when_the_panel_releases_its_name` in `crates/fe-ibus/tests/protocol.rs` (panel claims name, SetGlobalEngine xkb off; non-owner ReleaseName -> 3, IME stays off; owner ReleaseName -> 1, IME on, "dd" composes and commits "đ"). Mutation: removing `set_enabled(true)` in ReleaseName fails it at protocol.rs:636 `assertion failed: bus.ime.enabled()`; source restored.
- Finding 2 (minor): `tests/e2e/run.sh` indicator scenario: ind1/ind2 read `$IME_STATE` (expect `vr-talex|EN`, `vr-talex|VI`); the off check requires `engine=xkb:us::eng` in SHELL_IME_JS.
- Commands: `cargo test -p fe-ibus --locked` all green (25/12/1/18/15 passed, 0 failed); fmt check ok; `clippy --workspace --all-targets -D warnings` clean; release built.
- e2e (`--ime daemon --apps term --runs 1 --words 60 --scenarios indicator`), `RESULT AC-4:indicator PASS` on route=ibus and route=fcitx (exit 1 only from AC-10 INCOMPLETE, no --allow-incomplete). Logs: qa-artifacts/FR-7/fix1-{ibus,fcitx}.log.
