# Review T6 — fe-fcitx (code + security)

Verdict: **CHANGES_REQUESTED** (one major test gap; the code itself has no blocker/major defect found)

Scope: `git -C /home/rainy/DEV/vr-talex-wt-T6 diff` + untracked files, base 7759c41.

## Files read
- crates/fe-fcitx/Cargo.toml — read
- crates/fe-fcitx/src/lib.rs — read
- crates/fe-fcitx/src/server.rs — read
- crates/fe-fcitx/src/contexts.rs — read
- crates/fe-fcitx/src/wire.rs — read
- crates/fe-fcitx/tests/bus.rs — read (harness, limit, uid, leave and bus-gone tests line by line; the rest by name and assertions)
- Cargo.lock — skipped (lockfile); added package list checked: zbus 6.5.0 tree + tokio-macros only
- Followed: crates/ime-core/src/lib.rs (calling rules), shared.rs (API), zbus-6.5.0 `Body::deserialize`, main-stream queue (no overflow mode → back-pressure, no drop), install.sh (fcitx5 D-Bus activation shadowed), packaging/vr-talex.service (TimeoutStartSec=10)

## Findings

[major] crates/fe-fcitx/src/server.rs:88-92, 155-178 — SEC-16 / SEC-15 caps and client cleanup have no test
Scenario: the per-connection slot is freed only when the bus's `NameOwnerChanged` is matched (AddMatch rule, sender check, `disconnected`). If that path regresses (typo in the match rule, header check), every app start leaks a slot; after 256 connections in one session each new fcitx-module app gets `LimitsExceeded` on `CreateInputContext` and silently types without Vietnamese. No test covers `max_clients`, `queue_per_client`, or slot release (`a_client_leaving_does_not_disturb_the_others` passes even with the leak, since 3 < 256). SEC-16's verify line asks for a test per cap; SEC-15's asks for a malicious-client test with *another* client still typing (the malformed-calls test uses a single client).
Fix: (a) `max_clients: 1` — A connects, B gets `LimitsExceeded`; A leaves; B (retried) is served. (b) `queue_per_client: 1` — pipeline ~64 calls without awaiting; each reply is success or `LimitsExceeded`, the server keeps serving afterwards. (c) in `malformed_and_unknown_calls_get_errors_and_change_nothing`, have a second `App` type `vieetj ` after the bad calls.

[minor, uncertain] server.rs:364 — `ProcessKeyEventBatch` → UnknownMethod
Scenario: a Qt5 app started before install with `QT_IM_MODULE=fcitx` (this machine sets it) that uses the batch call gets an error → fcitx5-qt treats the key as unhandled → keys arrive raw (no Vietnamese, nothing lost) until the app is restarted. Not measured (spike O4); not in any AC.
Fix: leader decision — record as accepted limit in decisions.md, or implement it (`(uuubu) -> (a(uv), b)`: put the actions in the reply array instead of signals; no client variant is decoded).

[low] server.rs:380, 421 — CWE-226 SEC-4 residue in zbus buffers
Commit/preedit text is serialized into zbus `Message` buffers, and incoming `SetSurroundingText`/key bodies sit in received buffers until the `Message` drops (right after handling); both are freed without zeroizing. Readable only from a core dump or by a same-uid process reading the heap, which already defeats the model (SEC-3 covers dumps). Same as T5. Fix: none in this crate; record as accepted residual risk next to T5's.

## Judgements asked for in the brief
- SEC-8: the session bus authenticates (dbus-daemon, EXTERNAL); `GetConnectionUnixUser` per unique name is sound — unique names are never reused within a bus lifetime and the sender header is set by the bus. Calls queued while the uid lookup runs are only handled after it (server.rs:183-189), so no TOCTOU. Failure/unknown → denied.
- SEC-9: per-connection table, AccessDenied on foreign paths, every signal has a destination (server.rs:421); `NameOwnerChanged` accepted only with sender `org.freedesktop.DBus` (the bus stamps senders, so not spoofable).
- B2: one reader, `try_send` only, per-client FIFO task, signals awaited before the reply on one connection → order kept. Queue full (256 waiting calls of one app) → `LimitsExceeded`; for a key this means the key goes raw ahead of queued ones, and a refused NO_REPLY call (FocusOut) is dropped. Only reachable if that client's task stalls for 256 calls; its only awaits are bus sends and a bounded IME lock, so not reachable with human or 15 ms/key input. Accept: awaiting instead would break D22.
- B3/AC-3: FocusOut/Reset/SetCapability/DestroyIC send ime-core's commit before the reply, to the owner; disconnect destroys contexts and wipes (nowhere to send). Matches ime-core rule 3.
- SEC-12: Password (1<<3), Sensitive (1<<36), Disable (1<<40) → passthrough. Disable means "IM must not process keys", so passthrough is the right effect; accept.
- SEC-15/16 / D22: every client body is decoded by `Body::deserialize` into concrete tuples (signature-checked, error → InvalidArgs) or a signature compare; no indexing/unwrap on wire data. Caps 256 / 128 / 256 / 16×512 B (tested only for contexts and create args — see major).
- Names: `DO_NOT_QUEUE` without `ALLOW_REPLACEMENT` → fcitx5 `--replace` cannot take over; never replaces a running fcitx5; 8 s wait < TimeoutStartSec 10 s; `ready.notify()` after both names. install.sh shadows fcitx5's D-Bus activation file, so a restart gap cannot auto-start fcitx5.
- SEC-1/2: no print/log/format of text in src; error strings static; `Options` Debug holds no text.
- Coordinator check (1): no `TryFrom<Variant>`/`Value` conversion anywhere in fe-fcitx; no `v` argument is accepted. Not affected. (2): fe-fcitx is a session-bus client (`Builder::session()`); no server handshake runs. Not applicable.
- Deviations: tests written with code — accepted (two mutants each fail 5–7 tests); context path always the portal path — matches fcitx5 5.1.7; `Version -> u` and `SetSupportedCapability` — match the spike's fake / fcitx5; batch — see minor.
- Dependency audit: cargo-audit/cargo-deny not installed (project profile); not run. Added crates are zbus 6.5.0's tree, same version as T5 (expect a Cargo.lock merge overlap with T5).

## Rule check T6
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 | pass | only crates/fe-fcitx/** + Cargo.lock changed |
| BASE-2 | pass | frontend contract kept (ready after names, Ok only without bus, static Err); ime-core rules 1–7 kept |
| BASE-3 | pass | mutant-broadcast.log 7 fail, mutant-reply-first.log 5 fail; tests-with-code deviation accepted |
| BASE-8 | pass | zbus 6.5.0 (plan choice, = T5); futures-core/serde already in its tree; audit tool absent (noted) |
| BASE-9 | pass | typed/signature-checked decode on every method, arg bounds, uid + ownership checks |
| BASE-25 | pass | clippy.log exit 0, fmt --check in notes |
| AC-2 | pass (frontend part) | replays_the_spike_sequence_and_types_viet; smoke-final.log; 5,000-word run is T9 |
| AC-3 | pass | focus_out_reset_and_destroy_commit_the_word |
| AC-5 | pass (frontend part) | waits_for_the_previous_owner_to_leave, owns_both_names_once_ready |
| AC-7 | pass | password_field_passes_every_key_through |
| AC-9 | pass | no logging; callers_of_another_uid_are_refused |
| D8 | pass | both names, InputMethod1/InputContext1 as fcitx5-gtk uses them |
| SEC-1 | pass | grep: no print/log/format of text in src |
| SEC-2 | pass | no new text-holding type; ime-core redacted types reused |
| SEC-4 | pass (residual low) | surrounding text never decoded; zbus buffer residue accepted-risk candidate |
| SEC-8 | pass | GetConnectionUnixUser per unique name, held queue, deny on unknown |
| SEC-9 | pass | contexts.rs table, AccessDenied, unicast signals; another_connection_can_neither_use_nor_hear_a_context |
| SEC-12 | pass | wire.rs:27-33 |
| SEC-13 | pass | changing_to_password_commits_the_word_first |
| SEC-15 | fail | code pass; the required other-client-keeps-typing test is missing (major finding) |
| SEC-16 | fail | connection and queue caps untested (major finding) |
| SEC-27 | pass | `#![forbid(unsafe_code)]`, no `unsafe` |

## Re-check fix round 1

Verdict: **APPROVED**

Scope: crates/fe-fcitx/tests/bus.rs only (src/ unchanged, per the fix-round notes); read `App::close`, `App::type_one_by_one`, `a_client_slot_is_freed_when_its_connection_leaves`, `a_burst_beyond_the_queue_is_refused_and_serving_goes_on`, and the extended `malformed_and_unknown_calls_get_errors_and_change_nothing`; mutation logs `qa-artifacts/T6/mutant-no-slot-release.log`, `mutant-no-client-cap.log`, `fix1-test.log`.

Finding 1 — fixed:
- (a) The slot test proves both the cap (B refused while A is connected, C refused afterwards) and the slot release (B served after A leaves). It does not sleep or retry: B waits for the bus's own `NameOwnerChanged` for A. dbus-daemon sends that signal to every matching connection in one dispatch, so it reaches the frontend's socket before B's next call, and the frontend's reader handles them in that order. The two mutants each fail this test (bus.rs:670 slot not freed; bus.rs:636 no cap).
- (b) The burst test sends 64 calls back to back with `queue_per_client: 1`. It asserts that every call is answered, that both answer kinds occur, and that the same client and a second client type `việt ` afterwards. Removing the queue cap would give 0 refusals and fail the test.
- (c) A bystander client connected before the bad calls and a newcomer connected after them both type `việt ` (SEC-15).
- `grep sleep` on bus.rs finds nothing. Every wait has the 5 s `STEP` timeout.

[minor] crates/fe-fcitx/tests/bus.rs:686-725 — `refused > 0` depends on scheduling
Scenario: the assertion holds because `#[tokio::test]` uses a single thread: the test's 64 sends complete before the server runs, and the frontend's reader routes every message already in its stream without yielding to the client task. If this test is ever moved to `flavor = "multi_thread"`, the client task could keep pace and every call would be served, so the test could fail intermittently with no code defect.
Fix (optional): add a comment on the test that it relies on the current-thread runtime, or pin `#[tokio::test(flavor = "current_thread")]` explicitly.

Findings 2 and 3: settled by D25 (a) known limit, (b) accepted residual risk.

| Rule | Status | Evidence |
|---|---|---|
| SEC-15 | pass | bystander + newcomer type `việt ` after another client's bad calls |
| SEC-16 | pass | slot test (cap + release, 2 mutants fail), burst test (queue cap), contexts_per_client_are_capped |
| SEC-4 | pass (residual accepted, D25b) | — |
| BASE-3 | pass | mutant-no-slot-release.log, mutant-no-client-cap.log: 1 failed each |
