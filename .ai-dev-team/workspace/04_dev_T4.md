# T4 ime-core

- Task: implement ime-core contract, main.rs hardening/state store/watchdog (be, security).

## Progress
- started: reading plan, spec, threat model, T2 notes
- 19:55 read plan/spec/threat model/T2 notes/rules; design fixed (Arc<Mutex<Ime>> handle, per-context tap detector, D10 three edit modes, FileStateStore in ime-core, rustix+zeroize deps looked up); writing tests first
- 20:00 tests written first (6 files, 43 tests) against an API skeleton with no behaviour; red run: 39 failed / 4 passed (qa-artifacts/T4/red.log). Deps added and pinned (zeroize 1.9.1, rustix 1.1.6; errno 0.3.14 and mio 1.2.4 held back: newer ones < 14 days old). Writing the implementation
- (the lines below were written together at 20:06; their steps happened in this order between 20:00 and 20:06)
- implementation written (lib/key/action/toggle/ime/state/shared); first green run: 43/43 ime-core tests (qa-artifacts/T4/run1.log)
- main.rs written; serve() takes the frontends as a parameter so tests drive the real function; 7 unit tests green (run3.log). Mutation check of the main.rs tests: 3 mutations (harden skipped, WATCHDOG ping removed, SHUTDOWN ignored) → exactly the 3 matching tests FAILED (main-mutation-red.log); file put back from a scratch copy, byte-identical (cmp)
- leader note: T10 (D18, telex-core free-order) merged. None of my expectations change: full rerun on HEAD 666922d is green without edits
- 20:06 final related tests + guard + binary smoke with a notify socket done; notes and capabilities written. Nothing left running.

## Files changed
- Cargo.toml (workspace deps: telex-core path, rustix, zeroize), Cargo.lock
- crates/ime-core/Cargo.toml, crates/ime-core/src/{lib.rs, key.rs, action.rs, toggle.rs, ime.rs, state.rs, shared.rs}
- crates/ime-core/tests/{common/mod.rs, pipeline.rs, toggle.rs, security.rs, state_store.rs, latency.rs, shared.rs}
- crates/vr-talex/Cargo.toml (tokio features signal+time, rustix), crates/vr-talex/src/main.rs
- .ai-dev-team/capabilities.md
- Not touched: crates/fe-*/** (the stubs only name the type `SharedIme`, which keeps its name), crates/telex-core/**.
- Outside the board row's Files column, needed by the brief's own dependency instructions: Cargo.toml, Cargo.lock, crates/vr-talex/Cargo.toml.

## Design in short
- `Ime` = plan contract, exactly (signatures unchanged). Additions beside it: `Ime::with_clock` (tap timing in tests), `Ime::take_pending`, `Ime::buffered_len`, `Mods` consts, `keysym` consts, `KeyEvent::press/release`, `Mode::symbol`, `MemoryStateStore`, `FileStateStore`, `state_dir`, `MAX_WORD_KEYS`.
- `SharedIme` = `Arc<Mutex<Ime>>` with one method per `Ime` call; the lock is never handed out, so it cannot be held across an await. Frontend rules (B2) are the crate docs of crates/ime-core/src/lib.rs.
- Edit modes (D10): preedit → UpdatePreedit per key, [HidePreedit, Commit] at the boundary; surrounding → per key [DeleteSurrounding{-n,n}, Commit(suffix)] (minimal diff against what the app holds), nothing at the boundary; hold → nothing per key, Commit at the boundary. Password → off.
- Boundary = any key that is not a-z/A-Z, not BackSpace-inside-a-word, not a modifier; or any key with Ctrl/Alt/Super/Hyper/Meta. Commit first, then handled=false. Releases: handled=false, no effect on the word.
- Toggle (D7): per-context detector (L/R Ctrl and Shift bits, both_seen, spoiled, start time). Spoiled by any non-chord key press/release, another modifier key, Alt/Super/Hyper/Meta in the state mask, or a reset (Ctrl+Shift+click). Cleared by focus-in/out. The chord must last < 1 s from the first press to the last release. On toggle: the word of that context is committed, mode flipped, watch notified, store saved. Other contexts commit their word on their next key (the EN path flushes).
- SEC-13 with the contract's `set_caps(..) -> ()`: the commit of a word typed under the old capabilities is queued in the context; `SharedIme::set_caps` returns it at once (frontends send it before the new state applies); if nobody collects it, it leads the context's next result — never dropped.
- Word cap: 32 keys (`MAX_WORD_KEYS`); then the word is committed and its remaining letters pass through until a boundary. This is what bounds the work of one key.
- State file: `$XDG_STATE_HOME/vr-talex/mode` (fallback `$HOME/.local/state/vr-talex/mode`), content exactly `VI` or `EN`, dir 0700, file 0600, temp file + rename, no fsync (a toggle must not block typing on a disk flush; a power cut can lose only the last toggle). A symlinked dir is refused; a symlinked file is not read and is replaced, not written through.
- main.rs: `harden()` first (fails closed: exit 1), state store, current-thread runtime (io+time), frontends from T2's wiring, SIGTERM/SIGINT → STOPPING=1, `JoinSet::shutdown` (frontends drop their guards), exit 0. sd_notify is ~25 lines of std (`UnixDatagram::send_to_addr`), no crate. The watchdog task runs on the same thread as the frontends, pings every WATCHDOG_USEC/2 and takes the IME lock first.

## Tests added (50)
- crates/ime-core/tests/pipeline.rs (13): D10 modes, boundaries (20 keys), BackSpace, AC-3 focus-out/reset/destroy commit exactly once, EN mode, context isolation, releases and lone modifiers, word cap, capability change.
- crates/ime-core/tests/toggle.rs (11): AC-4/D6/D7 — both orders, left/right keys, IBus release mask, auto-repeat, Ctrl+Shift+T/P/C/V in both modes, 7 not-a-tap cases, 1 s limit with a test clock, commit on toggle, global mode, password field, focus/reset mid-chord, load from the store, save + watch (sync and async).
- crates/ime-core/tests/security.rs (6): AC-7 `matkhau1s`, password wins over other caps, SEC-13 content-type and focus transitions, SEC-2 redacted Debug (Action, KeyResult, KeyEvent, Ime), SEC-4 empty after every boundary × 3 modes.
- crates/ime-core/tests/state_store.rs (8): AC-8 restart through the file, SEC-5 content/modes/only one file, tightening 0755, damaged/missing file, symlinked file and dir, unwritable location, XDG rules.
- crates/ime-core/tests/latency.rs (1): AC-10, 4 × 10,000 keys (prose and worst case at the cap, preedit and surrounding), asserts p99 < 5 ms.
- crates/ime-core/tests/shared.rs (4): clones, set_caps return, 4 threads × 200 words keep per-context order, a panic inside a call (poison) does not stop the others.
- crates/vr-talex/src/main.rs (7): hardening (dumpable=0, RLIMIT_CORE 0/0, cannot be raised), watchdog period, NOTIFY_SOCKET parsing, path + abstract socket delivery, watchdog pings, SIGTERM → STOPPING + exit SUCCESS through the real `serve`, exit when no frontend is left.

## Commands + trimmed output (HEAD 666922d, after the last code change)
`run-heavy.sh cargo test -p ime-core -p vr-talex --locked --no-fail-fast -- --nocapture` → exit 0 (qa-artifacts/T4/final-test.log):
```
tests/latency.rs     process_key over 10000 keys (preedit, prose): p50 4.536µs, p99 16.742µs, max 60.119µs
                     (surrounding, prose): p50 4.861µs, p99 17.509µs, max 51.184µs
                     (preedit, worst): p50 486ns, p99 10.032µs, max 21.898µs
                     (surrounding, worst): p50 2.991µs, p99 13.57µs, max 37.615µs
                     test result: ok. 1 passed; 0 failed
tests/pipeline.rs    test result: ok. 13 passed; 0 failed
tests/security.rs    test result: ok. 6 passed; 0 failed
tests/shared.rs      test result: ok. 4 passed; 0 failed   (prints the injected panic of the poison test)
tests/state_store.rs test result: ok. 8 passed; 0 failed
tests/toggle.rs      test result: ok. 11 passed; 0 failed
vr-talex src/main.rs test result: ok. 7 passed; 0 failed
```
Guard: `cargo fmt --check` → exit 0, no output. `run-heavy.sh cargo clippy --workspace --all-targets --locked -- -D warnings` → exit 0 (final-clippy.log):
```
    Checking vr-talex v0.1.0 (crates/vr-talex)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.36s
```
`run-heavy.sh cargo test -p telex-core --locked` (the related set names it; not changed by me) → exit 0, golden 1 passed, rules 26 passed (telex-core.log).
Binary smoke, `python3 -I qa-artifacts/T4/notify_smoke.py target/debug/vr-talex` (temp NOTIFY_SOCKET + XDG_STATE_HOME; the smoke dir it made under /tmp was removed afterwards) → notify-smoke.log:
```
exit 0 stderr bytes 0
READY=1
STOPPING=1
state files: none (mode never toggled)
```
Red: red.log — 39 FAILED / 4 passed against the behaviour-free skeleton (the 4: EN mode and password passthrough, which "do nothing" by definition, and two trivially true ones).
Static: `grep -rn unsafe crates/ime-core crates/vr-talex --include=*.rs | grep -v forbid` → empty. No println/eprintln/dbg/panic/unwrap/expect in crates/ime-core/src; main.rs (non-test part) has 6 eprintln, all static text except `frontend {name} failed: {err}` (T2's line; the error text is the frontend's, text-free by contract). `cargo tree -e normal --depth 1`: ime-core → telex-core, tokio, zeroize; vr-talex → fe-*, ime-core, rustix, tokio.

## Dependencies (BASE-8, looked up 2026-11-24 with `cargo search` and the crates.io sparse index `pubtime`)
| Crate | Version | Published | Why |
|---|---|---|---|
| zeroize | 1.9.1 (held; 1.9.2 is 7 days old) | 2026-10-06 | volatile wipe of the text in `Action` on drop and of the diff buffer (SEC-4); RustCrypto, no dependencies |
| rustix | 1.1.6 (latest) | 2026-10-27 | safe `prctl(PR_SET_DUMPABLE)`, `setrlimit`, and `kill` for the SIGTERM test, so no `unsafe` in our crates (SEC-3, SEC-27); features std+process only |
| tokio | 1.54.1 (already in the plan) | — | new features: `sync` (ime-core: watch channel behind ModeWatch), `signal` + `time` (vr-talex: SIGTERM, watchdog timer) |
| transitive, new in Cargo.lock | bitflags 2.13.2, linux-raw-sys 0.12.1, libc 0.2.191, signal-hook-registry 1.4.8, errno 0.3.14 (0.3.15 is 12 days old, held), mio 1.2.4 (1.2.5 is 11 days old, held) | 2026-09-10, 2025-12-23, 2026-10-16, 2025-12-25, 2025-09-09, 2026-10-03 | pulled by rustix / tokio signal |

sd_notify: own code instead of the `sd-notify` crate (one datagram of a fixed string).

## Deviations / interpretations (leader please confirm)
1. SEC-2 says "newtype"; the plan contract fixes `Commit(String)` / `text: String`. I kept the contract types and made the carrier safe instead: `Action` has a hand-written redacted `Debug` (kind + length) and wipes its text on drop. Consequence for T5–T7: match on `&action`; the text cannot be moved out of an `Action`.
2. SEC-13 vs `set_caps(..) -> ()` in the contract: solved without changing the signature (queue + `take_pending`; `SharedIme::set_caps` returns the actions). If the leader prefers `Ime::set_caps -> Vec<Action>`, that is a contract change for the plan.
3. SEC-18 "answered within a bound (e.g. 50 ms), else not handled": NOT built as a reply timer. `process_key` is synchronous CPU work bounded by the 32-key word cap (measured max 0.16 ms in a debug build over 40,000 keys); nothing in it can wait on a client. A timer that answers "not handled" for a call that later completes would deliver the key twice (once raw, once composed). A real hang (a bug) stops the watchdog pings — they come from the key thread and take the IME lock — and systemd restarts the daemon; meanwhile the clients' own D-Bus timeouts pass keys through. A reply deadline on the wire belongs to T5/T6 if still wanted. The unit's `WatchdogSec=` / `Type=notify` / `NotifyAccess=` are T8's; without them the pings are not sent at all (no WATCHDOG_USEC).
4. The state file is written without fsync (see Design). It is written at each toggle, inside `process_key` (a 2-byte temp file + rename).
5. `READY=1` is sent right after the frontends are spawned. Once T5 has a real listener it may want readiness after the bus is reachable (SEC-19).
6. `harden()` fails closed: the daemon exits 1 if core dumps cannot be disabled.
7. A reset spoils a Ctrl+Shift chord in progress (so Ctrl+Shift+click does not toggle), assuming frontends map a click to `reset`. D7 names only keys; say if a reset should be ignored instead.
8. The word cap (SEC-16's "word > 32 chars is committed and passed through") is built here although SEC-16 sits on T5–T7's rows: the pipeline needs it for its time bound.
9. Hold mode (no preedit, no surrounding text) shows nothing until the boundary, as D10 says.
10. A key release is always handled=false, also when its press was handled (as IBus engines do).

## Out-of-scope issues noticed
- Cargo.toml has `panic = "abort"` for release (T2) while SEC-17's text says "no panic=abort hiding this; handlers isolated". With abort, a panic restarts the whole daemon (systemd) instead of one handler; `SharedIme`'s poison recovery then only matters in unwinding builds. Decision for the leader.
- pin-project-lite 0.2.18 in the committed Cargo.lock (T2) was published 2026-11-19, 5 days before today (BASE-8 asks 14).
- Not built, not in the contract: a call to set the mode from the panel (clicking the indicator menu). T5 may need one.
- Integration risk for T5/T6: if one physical Ctrl+Shift tap were delivered through two contexts (two frontends serving the same app), the mode would toggle twice. Per F1/F2 an app uses one route, so not handled here.
- No cap on the number of contexts in `Ime` (`create_context` is infallible by contract); SEC-16's per-connection caps are the frontends'.
- T2 follow-up nit still open (telex-core Raw-branch `keys` Vec not wiped) — not my file.
- Not verified here (needs the real desktop / unit, D2): systemd actually restarting on a stalled watchdog, `/proc/<pid>` ownership after hardening, the 100 ms indicator of AC-4.

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| Word composition, BackSpace rule | capabilities.md | reused `telex_core::Composer` (push/pop/text/raw/clear) unchanged |
| Shared handle, Error/Result | capabilities.md | extended crates/ime-core/src/lib.rs: `SharedIme` placeholder replaced, `Error`/`Result` kept |
| Frontend wiring (runtime + JoinSet) | capabilities.md, crates/vr-talex/src/main.rs | extended: same JoinSet, frontends now passed to `serve` |
| prctl / setrlimit without unsafe | cargo registry, crates.io | new dependency rustix (safe wrappers) |
| Buffer wiping | telex-core `wipe_string` (private, plain fill) | new dependency zeroize (volatile writes), as SEC-4 suggests |
| sd_notify | crates.io `sd-notify` | new — 25 lines of std, a crate is not worth it |
| Temp dirs in tests | — | `CARGO_TARGET_TMPDIR` (ime-core), `std::env::temp_dir()` (main.rs unit tests); no tempfile crate |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 | pass | `git status --short`: crates/ime-core/**, crates/vr-talex/src/main.rs, plus the manifests/lock the dependency work needs (listed under Files changed); fe-* untouched |
| BASE-2 | pass | crates/ime-core/src/ime.rs: every `Ime` method has the plan's signature; KeyEvent/Action/KeyResult/Caps/StateStore/Mode as in the plan; additions only (Design in short); deviations 1–2 explain the two tight spots |
| BASE-3 | pass | qa-artifacts/T4/red.log: 39 FAILED before the code existed; main.rs tests were written with the code and proven by mutation instead (main-mutation-red.log: 3 FAILED) |
| BASE-4 | pass | "Commands + trimmed output" above; logs in qa-artifacts/T4/ |
| BASE-5 | pass | every cargo test/clippy/build through run-heavy.sh; nothing left running |
| BASE-6 | pass | English; comments say why |
| BASE-7 | pass | no commit made |
| BASE-8 | pass | Dependencies table: versions and publish dates looked up today; three young releases held back |
| BASE-9 | pass | unknown CtxId → no-op (pipeline.rs destroy test); state file: bounded read, symlink checks, 0600/0700 (state_store.rs); no text in output (security.rs, static greps) |
| BASE-10 | pass | ran only -p ime-core, -p vr-talex, -p telex-core (related set) and the guard |
| BASE-11 | pass | no command that moves or hides tracked work; the main.rs mutation was undone from a scratch copy and verified with cmp |
| BASE-14 | pass | one command was moved to the background by the harness; I ended the turn and was resumed by its notification; no waiting loop |
| BASE-15 | pass | no process stopped by me |
| BASE-16 | pass | ## Reuse; capabilities.md extended with 6 lines |
| BASE-17 | pass | nothing installed; crates fetched by cargo into its own registry only |
| BASE-18 | pass | no agents started |
| BASE-19 | pass | ## Progress from the first step, times from `date` (the last group of lines was written at once and says so) |
| BASE-22 | pass | file/dir names follow the plan (`$XDG_STATE_HOME/vr-talex/mode`); test files named like telex-core's (tests/*.rs) |
| BASE-23 | pass | entry paths of "commit the word": boundary key, focus_out, reset, destroy, set_caps, toggle, EN/password next key — each has a test (pipeline.rs, toggle.rs, security.rs); both handles (`Ime`, `SharedIme`) tested |
| BASE-24 | pass | index and history untouched |
| BASE-25 | pass | guard output above (fmt exit 0, clippy exit 0) on the final code |
| BASE-32 | pass | D6 toggle.rs `the_mode_is_global`, `tap_toggles_saves_and_notifies`; D7 toggle.rs (all); D10 pipeline.rs `every_edit_mode_gives_the_same_text` + per-mode tests; no fake keys: `Action` has no key variant; D14–D18 untouched (Composer reused as is); D2: no desktop touched |
| BASE-34 | pass | one blocked step: BLOCKED-STEP: appending the notes through a shell heredoc — the team guard hook refused the command because of words in the notes text; switched to the Write tool |
| BASE-38 | pass | rustfmt ran on my files only |
| BASE-45 | pass | AC-3/4/7/8/10 texts are those of 01_spec.md §6 |
| BASE-46 | pass | final test run and smoke on HEAD 666922d after the last code change |
| COST-1 | pass | run-heavy.sh for all cargo runs |
| COST-3 | pass | no sleep/pgrep |
| COST-8 | pass | files written whole; batched reads and runs |
| COST-9 | pass | no background task, server or watcher running; the smoke temp dir removed |
| COST-10 | pass | `rule-checks.sh related-tests T4`: ime-core tests + telex-core golden (ran) + tests/e2e/dbuslite.py (T9's helper, not a test) |
| COST-13 | pass | scripts/logs only under qa-artifacts/T4/ (notify_smoke.py) |
| COST-16 | pass | logs to files, only summaries read |
| AC-3 | pass | pipeline.rs `focus_out_reset_and_destroy_commit_the_word_exactly_once`, `contexts_do_not_share_words`, `boundary_keys_commit_the_word_and_reach_the_app` (core level; mapping click/window switch to these calls is T5/T6) |
| AC-4 | pass | toggle.rs `tap_toggles_saves_and_notifies` (watch fires), `shortcuts_do_not_toggle_and_reach_the_app` (T/P/C/V, handled=false) (core level; the 100 ms indicator is T5) |
| AC-7 | pass | security.rs `password_field_receives_exactly_the_keys` (`matkhau1s`) |
| AC-8 | pass | state_store.rs `the_mode_survives_a_restart` (new Ime over the same directory) |
| AC-10 | pass | latency.rs: p99 ≤ 17.5 µs over 10,000 keys per corpus, assert < 5 ms |
| SEC-1 | pass | no log call in crates/ime-core/src; main.rs eprintln lines are static; smoke: stderr 0 bytes |
| SEC-2 | pass | security.rs `debug_output_never_shows_text_or_keys`; derive(Debug) only on Caps, Mode, CtxId, Mods, KeyResult (its Action prints redacted); no unwrap/expect in src. Deviation 1 (String kept, not a newtype) |
| SEC-3 | pass | main.rs `harden` is the first statement of main; test `hardening_switches_off_core_dumps` (the unit's LimitCORE=0 is T8) |
| SEC-4 | pass | security.rs `nothing_is_kept_after_a_boundary` (5 boundaries × 3 modes); `Action` Drop zeroizes (action.rs); diff buffer zeroized (ime.rs `compose`); no surrounding text or history is stored anywhere. The wipe itself is not observable from safe code: shown by the code, not by a test |
| SEC-5 | pass | state_store.rs `only_the_mode_is_stored_in_a_private_file`, symlink tests; the store is the only file write in both crates |
| SEC-12 | pass | security.rs `password_field_receives_exactly_the_keys` (buffered_len 0 after every key), `password_flag_wins_over_every_other_capability`; toggle.rs `the_tap_works_in_a_password_field_and_keeps_nothing` |
| SEC-13 | pass | security.rs `turning_into_a_password_field_commits_the_word_first`, `a_word_is_committed_only_to_the_context_it_was_typed_in`; shared.rs `set_caps_hands_back_the_commit_of_the_word_in_progress` |
| SEC-17 | pass | shared.rs `a_panic_inside_one_call_does_not_stop_the_others` (my part: the shared handle survives a panicking call); the unit's Restart= is T8; see the out-of-scope note on panic=abort |
| SEC-18 | pass | watchdog: main.rs `the_watchdog_pings_while_the_key_thread_is_free`, `watchdog_period_is_half_the_interval_systemd_asks_for`; bound: pipeline.rs `an_overlong_word_is_committed_and_the_rest_passes_through` + latency worst-case corpus. The "else not handled" reply timer is not built — deviation 3 |
| SEC-27 | pass | `#![forbid(unsafe_code)]` in both crate roots; grep unsafe → empty; no sys module needed (rustix) |

n-a: BASE-12, BASE-13, BASE-20, BASE-21, BASE-26, BASE-27, BASE-28, BASE-29, BASE-30, BASE-31, BASE-33, BASE-35, BASE-36, BASE-37, BASE-39, BASE-40, BASE-41, BASE-42, BASE-43, BASE-44, BASE-47 (library + daemon shell: no other repository, removal, secret, container, third-party code, browser, shared data, schema, UI, user-rules file, fix round or outward write) · COST-2, COST-4, COST-5, COST-6, COST-7, COST-11, COST-12, COST-14, COST-15, COST-17, COST-18, COST-19, COST-20 (no UI, browser, e2e, CI, goldens, full suite or qc script in this task)

## Fix round 1
- 20:14 read 05_review_T4.md and D22; writing the failing tests first (serve with a failed frontend; poison recovery keeps other contexts' words)
- red: fix1-red.log — shared.rs poison test FAILED (`left: []`, right: the other context's commit). The two new serve tests passed by accident there: the SIGTERM test's signal reaches every `serve` in the test process and ended them. Serve tests now take one lock (`serve_alone`); rerun fix1-red-main.log — both FAILED (2 s timeout: the daemon stayed up)
- leader add-on (T8 contract): READY=1 only when every frontend is ready → `ime_core::Ready`, new `run` signature, the three stubs updated
- code for findings 1–4 and the add-on written; fix1-run1.log green (43 + 14)
- mutation check for the tests written with their code (readiness, mode saving): READY sent unconditionally + saver task not started + no save at exit → exactly the 4 matching tests FAILED (fix1-mutation-red.log); file put back from a scratch copy, byte-identical (cmp)
- 20:30 final related tests, guard and binary smoke on the final code (HEAD 666922d + working tree). Nothing left running.

### Findings
1. [major] SEC-17 failed frontend — **fixed**. crates/vr-talex/src/main.rs `serve`: `Event::Finished(name, Err)` and a JoinError set FAILURE and leave the loop → STOPPING=1, `tasks.shutdown()`, exit FAILURE. `Ok(())` = "not needed here": counted as ready, the others keep running. Tests: `a_failed_frontend_ends_the_daemon_so_systemd_restarts_it`, `a_panicked_frontend_ends_the_daemon_too` (one broken + one that serves forever; seen failing first). The Ok/Err/ready meaning is on each frontend's `run` (crates/fe-ibus, fe-fcitx, fe-xim `src/lib.rs`), in the crate docs of crates/ime-core/src/lib.rs (rules 6–7, incl. D22 (c) one task per client connection) and on `Frontend` in main.rs.
2. [minor] poison recovery — **fixed**. `SharedIme::call` records the context a call works on (`Ime::enter`/`leave`); `Ime::recover` clears only that context and turns every other context's word into a pending commit that leads its next result. tests/shared.rs `a_panic_inside_one_call_does_not_stop_the_others` rewritten (panic injected through the tap clock, since the store is no longer called under the lock).
3. [minor] file I/O under the lock — **fixed**. `Ime` no longer owns a store: `Ime::new(&dyn StateStore)` only loads. main.rs `persist_mode` follows a `ModeWatch` and runs `ModeSaver::save_now` on the blocking pool (not under the IME lock, not on the client thread); `serve` saves once more at exit for a toggle the task had no turn for. AC-8: main.rs `a_toggle_is_saved_off_the_key_path_and_survives_a_restart`, `a_toggle_right_before_the_stop_is_still_saved`; ime-core state_store.rs `the_mode_survives_a_restart` (load side + "the key path itself writes nothing"); toggle.rs `tap_toggles_and_notifies_without_writing_the_store`.
4. [low] panic hook — **fixed**. main.rs `install_panic_hook` right after `harden()`: prints `vr-talex: internal error at file:line:col`; `panic_line` takes only the `Location`, so the payload cannot reach the line. Test `the_panic_line_names_only_the_place`. The hook itself is not installed in the test binary (it would hide assertion messages of every other test); it is two lines around the tested function.
5. Add-on, READY after all frontends — **done**. `run(ime, ready: Ready)`; `serve` sends READY=1 once every frontend has called `ready.notify()` or returned `Ok(())`. Tests `ready_is_reported_only_when_every_frontend_is_ready`, `a_frontend_that_never_gets_ready_keeps_the_start_report_back` (a handle dropped unused is not "ready"), `the_daemon_ends_when_no_frontend_is_left` (READY then STOPPING). Deviation 5 of the first round is thereby closed.

### API changes of this round (T5/T6 read this)
- `fe_*::run(ime: SharedIme, ready: Ready) -> ime_core::Result<()>` (was `run(ime)`).
- `Ime::new(&dyn StateStore)`, `Ime::with_clock(&dyn StateStore, clock)` (were `Box<dyn StateStore + Send>`); the IME never calls `save`.
- New: `ime_core::{Ready, ReadyWatch}`.
- The plan's `Ime` method contract is unchanged.

### Files changed in this round
crates/ime-core/src/{lib.rs, ime.rs, shared.rs, ready.rs (new)}, crates/ime-core/tests/{common/mod.rs, shared.rs, toggle.rs, state_store.rs}, crates/vr-talex/src/main.rs, crates/fe-ibus/src/lib.rs, crates/fe-fcitx/src/lib.rs, crates/fe-xim/src/lib.rs (signature + docs only, asked by the leader's add-on), .ai-dev-team/capabilities.md. No manifest or lockfile change.

## New states (round 1)
| New state / task | Quit (SIGTERM) | Error half way | Second request / concurrent writer | A call that never returns | Test |
|---|---|---|---|---|---|
| Saver task `persist_mode` + blocking write | dies with the runtime; the runtime waits for a write in flight; `serve` writes the current mode once more before returning | a failed or panicked write is ignored: only the mode at the next start is at stake | writes are serialised by `ModeSaver::writing` and each stores the mode as it is at write time, so a slow early write cannot overwrite a later mode; toggles in a burst coalesce in the watch | a hung file system blocks only a blocking-pool thread: keys and watchdog go on; at exit the final write (and the runtime's wait for the pool) can hang → systemd's stop timeout ends the process; mode of that run lost | `a_toggle_is_saved_off_the_key_path_and_survives_a_restart`, `a_toggle_right_before_the_stop_is_still_saved` |
| Not-yet-ready frontends (`unready`, `announced`) | SIGTERM before READY: STOPPING=1, exit 0 (no READY) | a frontend failing before ready: exit FAILURE, no READY | READY is sent once (`announced`) | a frontend that never reports ready: READY never sent, systemd's TimeoutStartSec handles it (leader's add-on) | `ready_is_reported_only_when_every_frontend_is_ready`, `a_frontend_that_never_gets_ready_keeps_the_start_report_back`, `a_failed_frontend_ends_the_daemon_so_systemd_restarts_it` |
| `Ime::in_call` (context of the running shared call) | n-a (in memory) | this is the error path: left set by a panic, consumed by `recover` | set and cleared under the one lock | a call that never returns holds the lock: watchdog stops, daemon restarted | shared.rs `a_panic_inside_one_call_does_not_stop_the_others` |
| Daemon exit on frontend failure | n-a | the path itself | a second failure while stopping is ignored (`tasks.shutdown`) | a frontend that does not finish dropping on cancel would hang `shutdown` → stop timeout | `a_failed_frontend_…`, `a_panicked_frontend_…` |

Not tested: a hung file system under the saver (needs a FIFO/NFS stand-in; the row above is by reading the code).

### Commands + trimmed output (final code)
`run-heavy.sh cargo test -p ime-core -p vr-talex --locked --no-fail-fast -- --nocapture` → exit 0 (qa-artifacts/T4/fix1-final-test.log):
```
tests/latency.rs     p99 16.63µs / 15.212µs / 9.557µs / 11.341µs (10,000 keys each); test result: ok. 1 passed
tests/pipeline.rs    test result: ok. 13 passed; 0 failed
tests/security.rs    test result: ok. 6 passed; 0 failed
tests/shared.rs      test result: ok. 4 passed; 0 failed
tests/state_store.rs test result: ok. 8 passed; 0 failed
tests/toggle.rs      test result: ok. 11 passed; 0 failed
vr-talex src/main.rs test result: ok. 14 passed; 0 failed
```
Guard: `cargo fmt --check` exit 0; `run-heavy.sh cargo clippy --workspace --all-targets --locked -- -D warnings` exit 0 (fix1-final-clippy.log: `Finished dev profile`).
Binary smoke (`notify_smoke.py`, fix1-notify-smoke.log): `exit 0`, stderr 0 bytes, `READY=1`, `STOPPING=1`, no state file (never toggled); its temp dir removed.
`grep unsafe` over crates/ime-core, crates/vr-talex, crates/fe-* (minus the forbid lines) → empty.

### Rule compliance rows touched by this round
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 | pass | this round's files listed above; the fe-* stub edits are the leader's add-on |
| BASE-2 | pass | plan's `Ime` methods unchanged; `run` gained the `ready` parameter by the leader's add-on (T8 contract) |
| BASE-3 | pass | fix1-red.log (finding 2), fix1-red-main.log (finding 1), fix1-mutation-red.log (add-on + finding 3: 4 FAILED); finding 4: pure-function test written with the code |
| BASE-4, BASE-25, BASE-46 | pass | fix1-final-test.log, fix1-final-clippy.log, fmt exit 0, smoke — all after the last code change |
| BASE-10, COST-10 | pass | only -p ime-core, -p vr-talex and the guard ran in this round |
| BASE-11, BASE-24 | pass | mutation undone from a scratch copy (cmp); index untouched |
| BASE-14 | pass | one run moved to the background by the harness; turn ended, resumed by its notification |
| BASE-32 | pass | D22: failed frontend → exit FAILURE, Ok = not needed (tests above); D21 items unchanged |
| AC-8 | pass | main.rs `a_toggle_is_saved_off_the_key_path_and_survives_a_restart` (through the real saver task and file), `a_toggle_right_before_the_stop_is_still_saved`; state_store.rs `the_mode_survives_a_restart` |
| SEC-1 | pass | panic hook prints the location only (`the_panic_line_names_only_the_place`); smoke stderr 0 bytes |
| SEC-5 | pass | still the only file write: `FileStateStore::try_save`, now called from `ModeSaver::save_now` only |
| SEC-17 (as reworded by D22) | pass | `a_failed_frontend_ends_the_daemon_so_systemd_restarts_it`, `a_panicked_frontend_ends_the_daemon_too`; the unit's Restart= is T8 |
| SEC-18 | pass | unchanged; the toggle path no longer does file I/O under the lock (toggle.rs `tap_toggles_and_notifies_without_writing_the_store`) |
| SEC-27 | pass | grep unsafe → empty, fe-* included |
All other rows of the first table stand unchanged.
