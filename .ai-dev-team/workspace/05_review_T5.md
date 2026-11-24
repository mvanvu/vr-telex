# Review T5 — fe-ibus (code + security)

Verdict: **CHANGES_REQUESTED** (security: ISSUES_FOUND)

Scope: `git -C /home/rainy/DEV/vr-talex-wt-T5 diff` + untracked, base 7759c41. Notes `04_dev_T5.md`. No suites run (results taken from the notes and `qa-artifacts/T5/`).

## Findings

[major / security medium] crates/fe-ibus/src/address.rs:86-88, address.rs:186, server.rs:284-301 — CWE-283 a second instance takes the live socket and address files away from the running daemon (SEC-7)
Data path: start of any second `vr-talex` process → `prepare_socket` → `remove_file` of the socket a live daemon listens on → `bind` → `write_address_file` → `Published::drop` on exit.
Scenario: the service is running; the user runs `vr-talex` by hand (`main` ignores arguments, so even `vr-talex --version` starts every frontend). fe-ibus of instance 2 finishes its file work in microseconds, before fe-fcitx gets its answer from the session bus: it removes instance 1's socket (it is "a socket of this user"), binds its own, and rewrites both address files with a new guid. gnome-shell drops its connection to instance 1 and connects to instance 2. Then instance 2's fe-fcitx `RequestName` (DO_NOT_QUEUE) fails, the daemon exits FAILURE, and `Published::drop` removes the socket path and both address files, because they hold its content. gnome-shell is disconnected and falls back to `xkb us`. Instance 1 keeps running and keeps the systemd watchdog happy, but no client can find it. Vietnamese input is gone until the service restarts or the user logs in again, and nothing reports it. Ctrl+C on a second instance has the same result.
Fix: take a single-instance lock before touching anything. Hold `rustix::fs::flock(LOCK_EX | LOCK_NB)` on `$XDG_RUNTIME_DIR/vr-talex/ibus.lock` (0600, opened with `O_NOFOLLOW`) for the whole run, and return `Err("fe-ibus: another instance is running")` when the lock is taken. At minimum, before `remove_file`, try `std::os::unix::net::UnixStream::connect(&socket)`: if it connects, refuse; remove only on `ConnectionRefused`. In `Published::drop`, remove the socket only if its `(dev, ino)` still matches what this run's `bind` created. Add a test: two `serve` in one sandbox → the second returns `Err`, the first stays reachable, and the address files are unchanged.

[major, uncertain] crates/fe-ibus/src/session.rs:640-649, 746-752 — a client without ClientCommitPreedit (Qt 5, D20 `QT_IM_MODULE=ibus`) may get the word twice on focus change
Scenario: Qt's `QIBusPlatformInputContext::commit()` (called by `QLineEdit` on focus-out and other commit paths) inserts the preedit it stored itself, then sends `Reset`. fe-ibus answers `Reset` with `CommitText("viêt")` when `client_commit == false`, so the word is inserted a second time, into the same widget or into the newly focused one. The notes call this "the same split ibus-daemon makes", but ibus-daemon sends no commit on `Reset` (the engine decides, and engines discard on reset). On `FocusOut` it commits for a non-client-commit context only when the engine's preedit mode is COMMIT. Qt's `reset()` path, by contrast, discards locally and needs the commit. Uncertain: this comes from Qt 5 `qibusplatforminputcontext.cpp` read from memory and was not run against a Qt app. No AC target app is Qt.
Fix: before changing anything, run the harness or a manual check with a Qt 5 `QLineEdit` (Tab to another field; click elsewhere in the same field while a preedit shows). If doubling is confirmed, the leader or user chooses between: follow ibus-daemon (no `CommitText` on `Reset`/`FocusOut` for non-client-commit contexts; Qt's own `commit()` keeps the word, and a Qt `reset()` loses it), or the current behaviour, with the limit documented.

[minor] crates/fe-ibus/src/server.rs:277-283 — test seam `serve_peers_of` is public API in release builds
Scenario: no client can reach it. Only Rust code that links `fe-ibus` can run a bus that admits another uid. Today only the daemon links it, and it calls `serve`. A later caller could use it by mistake.
Fix: gate it behind a `test-support` cargo feature that only `[dev-dependencies]` enables (`fe-ibus = { path = ".", features = ["test-support"] }`), or keep it and add a guard test asserting that `vr-talex` never names it.

## Judgments asked for in the brief
- SEC-6/7: dir `vr-talex` is checked with `symlink_metadata` (real dir, own uid, 0700), the socket is chmodded to 0600, and address files are written as temp files with `create_new` 0600 + `rename`, refusing link targets. Another user cannot squat the path (0700 dir owned by uid). A same-user second instance can (finding 1). libibus does reconnect after a restart: the address string changes through `guid=` (`ibus_bus_connect_async` returns only when the string is equal), the pid is live, and `every_start_publishes_a_new_address` plus the smoke "connected after ~0 s" confirm it.
- SEC-8: the only path to `session::serve` is after `peer_cred()` + `uid_allowed` (server.rs:326-331), and a `peer_cred` error drops the stream. EXTERNAL is the only mechanism. `peer_credentials` returns the kernel uid, so a lying claim fails too. No bypass found.
- SEC-15/16: no client-data `try_from`/`downcast` remains. Bodies go through `Body::deserialize` with signature check + `validate_bodies`, and variants are matched by hand (`content_type`, `flag`). The size cap is checked on the 16-byte fixed header before zbus reserves anything, and again for every message in the buffer. The handshake has a 16 KiB budget (zbus reads 1 KiB at a time) and a 5 s timeout. Descriptors are dropped (plain `read`; `can_pass_unix_fd` = false). The caps are 256 connections and 64 contexts. Residual: up to 64 queued messages × 128 KiB per connection (zbus `max_queued`), same uid only, low.
- B2: signals → reply → `try_changed` all happen before the next poll; one task per connection; the IME lock is never held across `.await`; every send has a 5 s timeout. A stalled client ends only its own task, and zbus tasks cancel on drop.
- AC-3 COMMIT mode: the commit is skipped only when `client_flushed && ClientCommitPreedit && preedit_shown` and it directly follows the `HidePreedit`. The commit text equals the last preedit (ime-core `flush`). gnome-shell's `_fullReset` sends `Set ContentType(0,0)`/`SetCapabilities(41)` before `Reset`. Neither changes `Edit::of`, so no early `CommitText` is emitted. No loss or doubling for gnome-shell. Non-client-commit: finding 2.
- SEC-12: purpose 8/9 and hint `1<<11` match the IBus enums. St password entries reach this as purpose PASSWORD through gnome-shell's `set_content_type`; the lock-screen/polkit dialog itself is n-o here (QC).
- SEC-1/2/4: no print/log/`tracing`, and errors are static strings. `Context`/`Session`/`Event` have no Debug. SetSurroundingText is dropped unread, and `Drop for Session` destroys the contexts and discards their commits. zbus buffers are D25(b) accepted residual.
- Deviations: no `Exit` — accepted (SEC-11 "if implemented"). SetSurroundingText dropped — accepted (no consumer in ime-core). Global context numbers — fine, ownership is per session map. Fixed socket name — fine for reconnect, but part of finding 1. `serve_peers_of` — finding 3. BASE-3 self-reported fail — self-attested, a process deviation for the leader. Every changed behaviour has a test, and the tests found the `TryFrom` panic, so this is not a code finding.

## Rule check T5
| Rule | Result | Evidence |
|---|---|---|
| BASE-1 | pass | `git status`: only `crates/fe-ibus/**` + `Cargo.lock` |
| BASE-2 | pass | `run(SharedIme, Ready)` per ime-core rule 6; no ime-core edit; one-service bus per D19 (plan's routing/NameOwnerChanged/Exit dropped by D19/SEC-11) |
| BASE-8 | pass | zbus 6.5.0 is the version named in the approved plan (02_plan.md:114); `default-features = false`, no `tracing`; new lock entries are zbus's tree. Audit tool not installed (profile) — static check only |
| BASE-9 | pass | uid check at accept, Hello-first, hand-matched variants, static errors |
| BASE-25 | pass | notes: `cargo fmt --check` rc 0, `clippy --workspace --all-targets --locked -D warnings` rc 0 = profile guard |
| SEC-1 | pass | grep: no print/log in src; harness leak scan 0 hits (smoke-1.out) |
| SEC-2 | pass | no Debug on text-holding types; errors static |
| SEC-4 | pass | session.rs:670-672, 228-240; zbus buffers = D25(b) |
| SEC-6 | pass | path socket `unix:path=…/vr-talex/ibus`, 0700/0600 (tests/address.rs) |
| SEC-7 | fail | live socket of a running instance removed as "stale" — finding 1 |
| SEC-8 | pass | server.rs:326-331 before handshake; session.rs:181 External only |
| SEC-9 | pass | session.rs:364-368 per-session map; signals carry `destination` = own unique name |
| SEC-10 | pass | `claim_panel` (first asker, same-pid takeover); panel gets only the InputMode property |
| SEC-11 | pass | method list in session.rs matches notes; `SetGlobalEngine`/`SetEngine` accept only `vr-talex` |
| SEC-12 | pass | ibus.rs:46-48 → `Caps.password` → ime-core `Edit::Off`; shell lock dialog n-o (QC) |
| SEC-13 | pass | `apply_caps` commits under old caps first (ime-core `set_caps`); Qt focus case → finding 2 |
| SEC-15 | pass | no client-data `try_from`/`downcast`/indexing; `validate_bodies` |
| SEC-16 | pass | socket.rs:116-130 header cap, 16 KiB/5 s handshake, 256/64 caps |
| SEC-27 | pass | `#![forbid(unsafe_code)]`, no `unsafe` in src |
| AC-2 | n-o | QC's; notes: code-term FAIL → D26 user decision |
| AC-3 | pass | gnome-shell path: harness AC-3 PASS + protocol tests; Qt → finding 2 (uncertain) |
| AC-4 | pass | harness AC-4 PASS (7 ms / 3 ms); `try_changed` after the reply |
| AC-5 | n-o | install scenario is T8/T9 |
| AC-9 | pass | 0700/0600 + uid check; SEC-1 scan 0 hits |
| D6 | pass | `InputMode` property, symbol VI/EN, RegisterProperties/UpdateProperty to the panel |
| D8 | pass | IBus frontend on a private bus |

## Files read
- crates/fe-ibus/Cargo.toml — read
- crates/fe-ibus/src/lib.rs — read
- crates/fe-ibus/src/address.rs — read
- crates/fe-ibus/src/server.rs — read
- crates/fe-ibus/src/socket.rs — read
- crates/fe-ibus/src/session.rs — read
- crates/fe-ibus/src/ibus.rs — read
- crates/fe-ibus/tests/protocol.rs, security.rs, address.rs — read in part (AC-3, size cap, handshake, restart tests); latency.rs, common/mod.rs — skipped (test helpers; results from the notes)
- Cargo.lock — skipped (lockfile; added crate list checked)
- Followed callees: ime-core `shared.rs`, `ime.rs` (set_caps/flush/focus_out/reset); zbus 6.5.0 `connection/socket/mod.rs` receive_message, handshake read size, `Connection::send`, Task drop; vr-talex `main.rs` (frontend start); fe-fcitx `RequestName` flags (master)

## Re-check fix round 1

Verdict: **APPROVED** (security: SECURE). Reviewer replaced (first run cut off). Scope: worktree diff + untracked on 7759c41, notes "Fix round 1", `qa-artifacts/T5/fix1-*`. No suites run; fix1-test.txt 63/63 ok, clippy and release Finished, red files fail before the fix (f1: 3 FAILED lines, f2: 2).

1. SEC-7 second instance — fixed. `address.rs:126-146`: dir checks, then `take_lock` (l.135) before the only removal (l.140); `server.rs:57-71` binds and writes address files only after `prepare_socket` succeeds, and `PrepareError::Running` returns before any write. Lock path: `symlink_metadata` must be a regular file of this uid (l.101-106), else `Unsafe`. Crash: flock is released by the kernel; the leftover `ibus.lock` (opened without truncate) and the dead run's socket do not block — the socket is removed under the lock, address files are overwritten through temp + rename (`a_restart_takes_over_the_socket_of_a_dead_run`). `Published::drop` (l.245-259): socket removed only when `(dev, ino)` equals the value read right after `bind`, files only when content equals this run's; `_lock` is the last field so it is released after cleanup. Early-exit paths (bind / chmod / second address file fails) clean up through the same Drop. Tests `a_second_instance_leaves_the_running_one_alone`, `stopping_leaves_a_socket_it_did_not_create` match the scenario.
2. Reset / FocusOut — fixed. `session.rs:762-773`: the commit is skipped only for a `HidePreedit → Commit` pair while `preedit_shown`; `Reset` → always, `FocusOut` → only with ClientCommitPreedit (unchanged), `Engine` → never. A held word (no preedit) has no `HidePreedit` before it and is still sent (test l.326-332, l.361-366). gnome-shell (ClientCommitPreedit): skip on both Reset and FocusOut, as before the round → AC-3 path unchanged (`focus_out_and_reset_leave_the_commit_to_a_client_that_commits_its_preedit`, smoke AC-3 PASS). Qt 5: `commit()` inserts the preedit then sends Reset → no CommitText → word once; FocusOut after that Reset has nothing left → no doubling; wire trace in qt5/run2. Residual: Qt `reset()` without `commit()` drops the word — the developer documented it as an accepted new state (ibus-daemon parity; D27 moves Qt to fcitx).
3. `serve_peers_of` — fixed. `server.rs:40`, `lib.rs:34` behind `test-support`; only `[dev-dependencies] fe-ibus = { path = ".", features = ["test-support"] }` enables it; resolver 3 keeps dev-dep features out of `cargo build --release -p vr-talex`; probe shows E0425 without the feature.

Regression check: SEC-8 — `server.rs:105-110` peer_cred + `uid_allowed` before `session::serve`, unchanged. SEC-15/16 — the only `try_from` in src are `socket.rs:41,63` with `.ok()`; no `downcast`; no `unwrap/expect` outside `#[cfg(test)]`; caps unchanged.

[minor / low] crates/fe-ibus/src/address.rs:109-114 — lock opened without `O_NOFOLLOW`
Scenario: a same-uid process swaps `ibus.lock` for a link between the `symlink_metadata` check and `open` → the daemon creates/locks the link target. Same uid only (already full access), so no gain. Fix: `.custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)` (or `libc::O_NOFOLLOW`) on the `OpenOptions`, as the first review proposed. Not blocking.

## Rule check T5 (rows changed)
| Rule | Result | Evidence |
|---|---|---|
| SEC-7 | pass (was fail) | address.rs:99-146, 245-259; tests address.rs:244, 279; qt5/run2 real second instance exit 1, inode/md5 unchanged |
| SEC-13 | pass | session.rs:762-773; protocol.rs:288 test; Qt 5 replay once (run2/c-fix.png) |
| AC-3 | pass | gnome-shell skip rule unchanged; smoke AC-3 PASS on round-1 binary |
| SEC-8 | pass | unchanged, server.rs:105-110 |
| SEC-15 | pass | only `try_from(..).ok()` (socket.rs:41,63) |
| SEC-16 | pass | caps unchanged; one extra fd per run |
| BASE-1 | pass | only crates/fe-ibus/** + Cargo.lock (+ `fe-ibus` self dev-dep line) |
| BASE-3 | pass | fix1-red-f1/f2 fail before code; f3 via probe (in-crate test impossible) |
| BASE-25 | pass | fix1-clippy.txt / fix1-fmt.txt rc 0 |

## Files read (round 1)
- crates/fe-ibus/src/address.rs, server.rs, lib.rs (l.25-40), Cargo.toml — read
- crates/fe-ibus/src/session.rs — Cause, Context, Reset/FocusOut handlers, `emit` read; rest unchanged per notes
- crates/fe-ibus/tests/address.rs (l.100-125, 240-305), protocol.rs (l.255-370) — read
- Cargo.lock — fe-ibus entry only
