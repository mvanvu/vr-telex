# Review T4 — ime-core + daemon shell (code + security)

Verdict: **CHANGES_REQUESTED** (1 major; SEC-17 needs a written decision)

Tools available to the reviewer: Read, Bash (read-only use), Write (this file only), Skill. Dependency audit: `cargo-audit` / `cargo-deny` are not installed (profile line 13) — no advisory scan was run; static check of the lock additions only.

## Findings

### [major] crates/vr-talex/src/main.rs:101-121 — SEC-17: a failed frontend is never restarted
Scenario: fe-ibus returns `Err` (listener lost, bus error) or its task panics in an unwinding build while fe-fcitx / fe-xim are still running → `serve` logs, sets `status = FAILURE`, decrements `running` and keeps waiting. The process stays alive, so `Restart=always` never fires, and every IBus client (GNOME's default route) types raw ASCII for the rest of the session. The watchdog keeps pinging because the runtime thread is free.
Fix: on `Some(Ok((name, Err(_))))` and `Some(Err(_))` break out of the loop and return `ExitCode::FAILURE` (after STOPPING=1 + `tasks.shutdown()`), so systemd restarts the whole daemon. Keep `Ok(())` as "frontend not needed here" (no fcitx, no X display) so a deterministic absence does not become a restart loop; state that Ok/Err meaning in the frontend contract for T5–T7. Add a `serve` test: one frontend `Err`, one `pending()` → serve returns FAILURE.

### SEC-17 / D21 item 6 — judgment on `panic = "abort"` (decision for the leader, not a code defect of T4)
Abort is acceptable and I recommend keeping it, but SEC-17's text ("no panic=abort hiding this; handlers isolated") must be amended, because neither option meets it today: there is no per-connection isolation (each frontend is one task on one thread, one shared `Ime`), so with unwinding a panic kills a whole frontend and — with the finding above — leaves the daemon half-alive, which is worse than abort. Abort also never runs Drop/formatting code on a broken state and leaves no core (SEC-3). Required with abort: (1) the fix above; (2) T8's unit has `Restart=always`, `RestartSec<=1s`, `WatchdogSec=`, `Type=notify`, `NotifyAccess=main`; (3) SEC-17 reworded to "a panic restarts the daemon within RestartSec; words in progress in all clients are lost on a crash (accepted risk)", recorded in decisions.md. If the leader prefers unwinding instead: per-connection tasks in T5–T7 plus the minor finding on `recover()` below become mandatory.

### SEC-18 / D21 item 1 — judgment on the watchdog
Acceptable. `process_key` is synchronous, bounded (32-key cap) and the lock is never held across an await, so a "not handled after 50 ms" timer could only fire for a call that is still running on the same thread — impossible to deliver and, if made possible, a double key. The ping proves the key thread is not stuck. What it does not prove: a frontend awaiting one stalled client while other connections queue behind it. Condition to record for T5–T7: one task per client connection (or never await a client reply on the shared read loop), otherwise one frozen app stalls typing everywhere with the watchdog still green.

### [minor] crates/ime-core/src/ime.rs:426-433 + src/shared.rs:345-349 — poison recovery drops the words of every context
Scenario (unwinding builds only: tests, debug): a panic in context A → next call clears the composers and `pending` commits of B, C… — B's preedit `vie` vanishes (tests/shared.rs:146 asserts exactly that). Unreachable in release while `panic = "abort"`. If unwinding is ever chosen, flush other contexts into their `pending` instead of clearing them, and only clear the context whose call panicked (record its id before the call).

### [minor] crates/ime-core/src/ime.rs:343 — state-file write under the global lock on the key path
Scenario: home on NFS / a busy encrypted disk → the `create_new` + `write` + `rename` of a toggle takes tens of ms or more; every client of every frontend waits on the lock meanwhile. Fix (cheap): have `main.rs` subscribe a `ModeWatch` and call `try_save` from that task (or `spawn_blocking`), and keep `StateStore::save` out of `process_key`.

### [low] crates/vr-talex/src/main.rs:27 — CWE-532 no panic hook: std panic payloads may carry text
Data path: a bug in telex-core/ime-core hitting a std panic (str slicing, `RefCell`, index) → default hook prints the payload (e.g. `byte index 3 is not a char boundary; it is inside 'ê' … of \`viêt\``) to stderr → journal. Reviewed slices in ime.rs (194, 203) are on char boundaries, so this is defense in depth, not a reachable leak I found. Fix: `std::panic::set_hook(Box::new(|info| eprintln!("vr-talex: internal error at {:?}", info.location())))` right after `harden()` (location only, never the payload).

## Traces (no finding)
- B2: every `SharedIme` method is one synchronous call under a `std::sync::Mutex`; the guard is never returned or held across `.await`; poison is recovered, not propagated, so no key is dropped by a lock error. Order per context rests on frontend rule 1–2 (lib.rs docs).
- B3/AC-3: `focus_out`, `reset`, `destroy_context` take `pending` then `flush`; `set_caps` flushes into `pending` only when the edit mode changes, `SharedIme::set_caps` returns it, otherwise it leads the next `process_key`/focus result. Surrounding mode correctly commits nothing at flush.
- D7: both orders, L/R bits, auto-repeat (`down |=` idempotent), release without seen press ignored, any letter/boundary/backspace/other modifier/foreign mask/reset spoils, 1 s from first press, every chord/modifier path returns `handled: false`. Ctrl+Shift+T/P/C/V: the letter spoils.
- D10: three modes + Off; `Action` has no key variant — no fake key. Surrounding diff slices are on char boundaries.
- AC-7/SEC-12: Off/EN path returns before any composer call; the tap detector holds only modifier bits.
- SEC-3/5: harden first in `main`, fails closed; dir 0700 + chmod, file `create_new` 0600 + rename, symlinked dir refused, symlinked file not followed on read.

## Rule check T4
| Rule | Result | Evidence |
|---|---|---|
| BASE-1 | pass | diff = ime-core/**, vr-talex main.rs + manifests/lock (D21 item 2) |
| BASE-2 | pass | ime.rs signatures match plan §Contracts ime-core; additions only; D21 3–4 cover Action/set_caps |
| BASE-3 | pass | qa-artifacts/T4/red.log 39 failed; main-mutation-red.log 3 failed |
| BASE-8 | pass | zeroize 1.9.1, rustix 1.1.6 (std+process), tokio +sync (ime-core), +signal+time (vr-talex); young errno/mio held back; audit tool absent (stated above) |
| BASE-9 | pass | unknown CtxId → no-op; bounded state-file read; no text in output |
| BASE-25 | pass | final-clippy.log exit 0, fmt clean in notes |
| BASE-27 | pass | state tests under CARGO_TARGET_TMPDIR, sockets removed on drop; no real HOME/XDG touched |
| AC-3 | pass | pipeline.rs focus_out/reset/destroy exactly once (core level) |
| AC-4 | pass | toggle.rs tap/shortcut tests (indicator 100 ms is T5) |
| AC-7 | pass | security.rs `matkhau1s` |
| AC-8 | pass | state_store.rs restart through the file |
| AC-10 | pass | latency.rs 4×10k keys incl. cap worst case, p99 ≤ 17.5 µs; excludes lock + file save (qc stress test covers end to end) |
| D6 | pass | one `mode` in Ime, watch + store |
| D7 | pass | trace above; toggle.rs 11 tests |
| D10 | pass | ime.rs `Edit::of`, `compose`, `flush` |
| D21 (1) | pass | judgment above, condition for T5–T7 |
| D21 (6) | fail | see SEC-17 |
| SEC-1 | pass | no log in ime-core; main.rs eprintln static; panic hook advisory (low) |
| SEC-2 | pass | hand-written redacted Debug for Action/KeyEvent/Ime/SharedIme; KeyResult derive prints redacted Actions |
| SEC-3 | pass | main.rs:29 harden before runtime/sockets, test checks dumpable + rlimit |
| SEC-4 | pass | Action Drop zeroize, diff buffer zeroize, Composer::clear wipes |
| SEC-5 | pass | state.rs:74-106 |
| SEC-12 | pass | ime.rs:359 before any composer access |
| SEC-13 | pass | ime.rs:268-278, shared.rs:365 |
| SEC-17 | fail | major finding main.rs:101-121; panic=abort needs SEC-17 amended |
| SEC-18 | pass | watchdog via lock on key thread + 32-key cap (D21 1) |
| SEC-27 | pass | `#![forbid(unsafe_code)]` both roots + workspace lint; rustix instead of a sys module |

## Files read
- Cargo.toml — read; Cargo.lock — skipped (lockfile; additions listed by name/version only)
- crates/ime-core/Cargo.toml, src/lib.rs, action.rs, ime.rs, key.rs, shared.rs, state.rs, toggle.rs — read
- crates/ime-core/tests/latency.rs, shared.rs (74-154), toggle.rs (121-250), common/mod.rs (1-80) — read; pipeline.rs, security.rs, state_store.rs — test names and isolation lines only
- crates/vr-talex/Cargo.toml, src/main.rs — read

## Re-check fix round 1

Verdict: **APPROVED**

Read: crates/ime-core/src/{ready.rs, shared.rs}, ime.rs (`in_call`, `enter`/`leave`, `recover`, `new`/`with_clock`), lib.rs rules 6–7, crates/vr-talex/src/main.rs (non-test part, new test names/asserts), crates/fe-ibus/src/lib.rs stub; qa-artifacts/T4/fix1-final-test.log (all green, main.rs 14 passed).

1. **Failed frontend (SEC-17, D22)** — fixed. main.rs:222-232: `Finished(_, Err)` and a `JoinError` set FAILURE and break → STOPPING=1, `tasks.shutdown()`, final save, exit FAILURE. `Ok(())` = not needed, others keep running. Tests `a_failed_frontend_…`, `a_panicked_frontend_…` (seen red in fix1-red-main.log).
2. **Poison recovery** — fixed. `SharedIme::call` sets `in_call` under the lock; a panic skips `leave`, so `recover` clears only that context and flushes every other one into its `pending` (Preedit/Hold commit, Surrounding nothing — correct), which leads its next result. Calls without a context (`create_context`, `mode`) leave `in_call = None` → every context is flushed, none cleared: safe.
3. **Mode save off the lock** — no lost or reordered toggle found. `persist_mode` subscribes before the first await of `serve`, awaits each `spawn_blocking` write in turn, and each write stores the mode as read at write time under `writing`; a toggle during a write marks the watch changed → another write. The exit path writes once more after `tasks.shutdown()`. Residual window (accepted, no finding): a crash/abort or SIGKILL between a toggle and its write loses that toggle; a hung file system can stall the stop until systemd's stop timeout (noted by the developer).
4. **Panic hook** — fixed. main.rs:108-125 prints only `file:line:col` from `Location`; installed right after `harden()`, before any socket.
5. **READY ordering** — correct. READY=1 is sent once, only when every frontend has sent `notify()` or returned `Ok(())`; a dropped-unused `Ready` keeps it back (TimeoutStartSec covers it); a failure before ready exits without READY.
6. **`Ime::new(&dyn StateStore)`** — acceptable: the plan's contract does not name the constructor; `Ime` now only loads, and `FileStateStore::try_save` is still the only write (SEC-5). T5/T6 must use the new `run(ime, ready)` signature (documented in lib.rs rule 6 and each stub).

Note (no finding, T8/T5): the current stubs all return `Ok(())` at once, so the daemon exits 0 right after start until T5 lands; with `Restart=always` that is a restart loop in an interim build only.

| Rule | Result | Evidence |
|---|---|---|
| SEC-17 (as reworded by D22) | pass | main.rs:222-232 + two tests |
| D21 (6) / D22 | pass | abort kept; whole-daemon restart on frontend failure |
| SEC-1 | pass | panic hook location-only (`the_panic_line_names_only_the_place`) |
| SEC-5 | pass | only `try_save` writes, from `ModeSaver::save_now` |
| SEC-18 | pass | no file I/O under the IME lock; lib.rs rule 7 records the one-task-per-connection condition |
| AC-3 / B3 | pass | recovery keeps other contexts' words (tests/shared.rs rewritten) |
| AC-8 | pass | `a_toggle_is_saved_off_the_key_path_…`, `a_toggle_right_before_the_stop_is_still_saved` |
| BASE-2 | pass | plan's `Ime` methods unchanged; `run` signature change is the leader's add-on |
| BASE-3 | pass | fix1-red.log, fix1-red-main.log, fix1-mutation-red.log |
