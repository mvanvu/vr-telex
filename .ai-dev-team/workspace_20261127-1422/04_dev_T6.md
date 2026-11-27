# T6 fe-fcitx: fcitx5 D-Bus frontend (InputMethod1 / InputContext1, portal name)

Worktree /home/rainy/DEV/vr-talex-wt-T6, branch t6-fe from 7759c41. Nothing committed, git index untouched.

## Progress
- start: notes created; reading spec/plan/spike/threat model/T4 notes.
- read inputs; wrote crates/fe-fcitx/src/{lib,server,wire,contexts}.rs + Cargo.toml (zbus 6.5.0 tokio, futures-core, serde, rustix); builds offline. Unit tests in wire.rs/contexts.rs written with the code (pure functions).
- integration tests (tests/bus.rs, private dbus-daemon per test): first run 7/13 red — test bus policy rejected receives (fixed in test conf: stock session.conf policy) and expect_signature compared '(iiiid)' to 'iiiid' (fixed: to_string_no_parens). Now 13/13 green. Mutation checks: broadcast signals -> 7 fail; reply-before-signals -> 5 fail (logs qa-artifacts/T6/mutant-*.log).
- smoke (qa-artifacts/T6/smoke.sh, log qa-artifacts/T6/logs/smoke/): gnome-terminal GTK_IM_MODULE=fcitx in headless gnome-shell, real vr-talex debug binary -> typed [việt |xin chào các bạn|class https git|] SMOKE PASS; daemon output 0 lines; live fcitx5 6881 running before/after; cleanup stopped 30 tagged processes, 0 left.
- guards: rustfmt on the changed files, `cargo fmt --check` exit 0; clippy --workspace --all-targets -D warnings: first run 1 error (assert_eq! with a literal bool in tests/bus.rs) fixed, then exit 0; `cargo test -p fe-fcitx --locked` 10 + 13 green; smoke rerun on the final build: PASS.
- done: notes, capabilities.md updated.

## Files changed
- `crates/fe-fcitx/Cargo.toml` — zbus 6.5.0 (default-features off, `tokio`), futures-core 0.3.34 and serde 1.0.229 (both already in zbus's tree; used for the `Stream` trait and the body bound), tokio (rt, sync, time), rustix (workspace; getuid); dev: tokio macros.
- `crates/fe-fcitx/src/lib.rs` — `run`, `serve` re-export, `Options` (uid, name_wait 8 s < unit TimeoutStartSec 10 s, max_clients 256, max_contexts_per_client 128, queue_per_client 256), `FCITX_NAME`, `PORTAL_NAME`.
- `crates/fe-fcitx/src/server.rs` — names, reader, one task per client, InputMethod1 / InputContext1 dispatch, signals.
- `crates/fe-fcitx/src/wire.rs` — capability / key / cursor mapping, argument bounds, uid decision (+ unit tests).
- `crates/fe-fcitx/src/contexts.rs` — per-connection context table with cap (+ unit tests).
- `crates/fe-fcitx/tests/bus.rs` — 13 integration tests on a private dbus-daemon.
- `Cargo.lock` — +44 packages, all zbus 6.5.0's tree (+ tokio-macros for tests).
- Team files: `qa-artifacts/T6/smoke.sh`; logs `qa-artifacts/T6/{bus-run1,bus-run2,mutant-broadcast,mutant-reply-first,clippy,test-final,smoke-final}.log`, `qa-artifacts/T6/logs/smoke/`.

## Design (as built)
- One zbus connection on the session bus, low level (no ObjectServer, no tracing feature). An unfiltered `MessageStream` is created before AddMatch / RequestName so no call is missed.
- Names: `RequestName(name, DO_NOT_QUEUE)` for `org.fcitx.Fcitx5`, then `org.freedesktop.portal.Fcitx`; reply Exists → retry every 200 ms until `name_wait`, then `Err("fcitx: another program still owns the fcitx5 bus names")`. No ALLOW_REPLACEMENT: no other process can take the clients over while we run. `ready.notify()` only after both names (T8 health check).
- Reader: a method call goes to its sender's bounded queue with `try_send` (the reader never awaits a client, D22); a full queue or a 257th client gets `LimitsExceeded`. `NameOwnerChanged` with an empty new owner — accepted only when the signal's sender is `org.freedesktop.DBus`, so a client cannot fake another's disconnect — drops that client's queue; its task finishes what was queued, then destroys its contexts (commits are wiped; nowhere to send them). Stream end → `Err("fcitx: the session bus connection closed")`.
- Client task: asks the bus `GetConnectionUnixUser(sender)` once; uid not ours (or unknown) → every call answered `AccessDenied` (SEC-8). Then strictly in order: signals for the actions first, then the reply (B2; ime-core rules 1–3).
- Objects (fcitx5 5.1.7 `src/frontend/dbusfrontend/dbusfrontend.cpp`): `InputMethod1` at `/org/freedesktop/portal/inputmethod` and `/inputmethod`: `CreateInputContext(a(ss)) -> (o, ay)` (args bounded to 16 pairs × 512 bytes and ignored; 16-byte random id), `Version() -> u` = 1 (as fcitx5; fcitx5-gtk calls it, spike Q4). Contexts are always `/org/freedesktop/portal/inputcontext/N` (fcitx5 does the same for both input-method paths); N is global and never reused.
- `InputContext1`: FocusIn; FocusOut and Reset (commit); SetCapability(t) (→ `set_caps`, its commit sent first, SEC-13); ProcessKeyEvent(uuubu) -> b; DestroyIC (commit to the owner, then the path is forgotten). Accepted and ignored after a signature check: SetCursorRect(iiii), SetCursorRectV2(iiiid), SetSupportedCapability(t), SetSurroundingText(suu) (body never decoded, SEC-4), SetSurroundingTextPosition(uu). Anything else → UnknownMethod; another interface → UnknownInterface; another path → UnknownObject; a context path the caller did not create → AccessDenied (SEC-9). NO_REPLY_EXPECTED is honoured.
- Signals, destination = the owner's unique name only (SEC-9): `CommitString(s)`; `UpdateFormattedPreedit(a(si)i)` with format Underline (TextFormatFlag 1<<3, as the spike's fake used) and the cursor as a UTF-8 byte offset (`byte_cursor`), empty list for HidePreedit; `DeleteSurroundingText(iu)`. ForwardKey / UpdateClientSideUI are never sent.
- Capabilities (fcitx5 5.1.7 `src/lib/fcitx-utils/capabilityflags.h`, copy in `qa-artifacts/T1/src-fcitx/capabilityflags.h`): Preedit 1<<1 → `preedit`; SurroundingText 1<<6 → `surrounding_text`; Password 1<<3, Sensitive 1<<36, Disable 1<<40 → `password` (passthrough). VTE's 962089451570 → preedit only.
- Keys: `KeyEvent { keysym: keyval, keycode, state: state & !(1<<30), is_release: b }`. fcitx5 passes the state unmasked (`KeyStates(state)`, KeyState values from fcitx5 `keysym.h`); the IBus-style release bit 30 is cleared because fcitx carries release in its own argument. Repeat (1<<31) is passed on; ime-core ignores it.

## Commands + trimmed output
```
$ cargo test -p fe-fcitx --offline --test bus      # run 1 (red)
test result: FAILED. 6 passed; 7 failed
  panicked at tests/bus.rs:171:14: FDO(InvalidArgs("unexpected arguments"))   # signature compared as "(iiiid)"
  (an earlier attempt hung: the test bus policy rejected receives; fixed with the stock session.conf policy)
mutation: signals without destination (broadcast)   -> test result: FAILED. 6 passed; 7 failed
mutation: reply before the ProcessKeyEvent signals   -> test result: FAILED. 8 passed; 5 failed
$ run-heavy.sh cargo test -p fe-fcitx --locked --offline   # final
     Running unittests src/lib.rs
test result: ok. 10 passed; 0 failed
     Running tests/bus.rs
test result: ok. 13 passed; 0 failed; finished in 0.64s
$ cargo fmt --check                                       -> exit 0
$ run-heavy.sh cargo clippy --workspace --all-targets --locked --offline -- -D warnings
    Finished `dev` profile [unoptimized + debuginfo] target(s)      (exit 0)
$ run-heavy.sh bash qa-artifacts/T6/smoke.sh target/debug/vr-talex   # final build
live fcitx5 pid 6881 before: running
vr-talex pid 426377; owner pid of org.fcitx.Fcitx5: (uint32 426377,); of org.freedesktop.portal.Fcitx: (uint32 426377,)
windows: (true, '"gnome-terminal-server/wayland/focus=true"')
rd: type 8 keys in 133 ms (16.6 ms/key)
typed file: [việt |xin chào các bạn|class https git|]
SMOKE PASS
daemon stdout/stderr lines: 0; typed-text hits: 0
live fcitx5 pid 6881 after: running
(tagged cleanup; afterwards 0 processes carry the run's tag)
```
Smoke setup: `dbus-run-session`, own HOME/XDG/XDG_RUNTIME_DIR under `qa-artifacts/T6/{h,r}`, `GTK_IM_MODULE=fcitx` etc. for the whole isolated session; T1's `lib.sh` (guard, cleanup, start_shell) sourced with `A` pointed at the T6 dir; T1's `rd.py` and `fake_systemd.py`. fe-ibus is still the stub on this branch, so the Vietnamese text can only have come through fe-fcitx.

## Tests added
- Unit (`src/wire.rs`, `src/contexts.rs`, 10): vte_capability_is_preedit_without_surrounding_text, each_capability_bit_maps_alone, key_mapping_keeps_fields_and_trusts_the_release_argument, cursor_is_a_byte_offset, create_args_are_bounded, only_the_same_uid_is_served, a_path_is_found_only_by_the_connection_that_created_it, the_cap_refuses_one_more_context, drain_hands_back_every_context_once, paths_follow_the_fcitx5_layout.
- Integration (`tests/bus.rs`, 13): replays_the_spike_sequence_and_types_viet (Version, CreateInputContext [display, program], SetCapability 962089451570, SetCursorRectV2, FocusIn, press+release pipelined without waiting, FocusOut, DestroyIC; asserts preedit `việt` with cursor 6 bytes and the commit right before the reply that hands the space back), focus_out_reset_and_destroy_commit_the_word, password_field_passes_every_key_through, changing_to_password_commits_the_word_first, another_connection_can_neither_use_nor_hear_a_context, malformed_and_unknown_calls_get_errors_and_change_nothing, contexts_per_client_are_capped, callers_of_another_uid_are_refused, owns_both_names_once_ready, waits_for_the_previous_owner_to_leave, fails_when_the_previous_owner_stays, a_client_leaving_does_not_disturb_the_others, ends_with_an_error_when_the_bus_goes_away.

## Deviations from the plan / brief (with reason)
- Tests were written in the same pass as the code, not strictly before it; the red run and two mutation runs above show they fail on the defects they target.
- IC paths are always `/org/freedesktop/portal/inputcontext/N`, also when created through `/inputmethod` — that is what fcitx5 5.1.7 does; there is no separate non-portal IC path in fcitx5.
- Accepted beyond the brief's list: `Version` (fcitx5-gtk calls it, spike Q4) and `SetSupportedCapability` (no-op; part of fcitx5's InputContext1). `ProcessKeyEventBatch`, paging, candidate and virtual-keyboard methods → UnknownMethod.
- Capability `Disable` (1<<40, "raw keyboard only") maps to `password` (keys pass through).
- `Options` / `serve` are public so tests (and a later harness) can run the frontend on a private bus; `run` is the daemon entry.

## Out-of-scope issues noticed
- fcitx5-qt clients (`QT_IM_MODULE=fcitx`, spike O4) may use `ProcessKeyEventBatch` (`a(uv)b`); not implemented, such Qt apps started before install would get UnknownMethod (keys pass raw). Not measured on this machine.
- zbus copies commit/preedit text into its message buffers, which are not zeroized on drop (SEC-4 best effort; ime-core's own buffers are wiped).
- ime-core exposes no context count, so the disconnect test checks behaviour (others keep working), not that the departed client's contexts are gone.

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| D-Bus library | plan Toolchain, T1 broker (`qa-artifacts/T1/broker`) | zbus 6.5.0 (same as T5 / spike), low-level API |
| fcitx protocol details | spike Q4, `qa-artifacts/T1/fake_fcitx.py`, `src-fcitx/capabilityflags.h` | reused; signatures cross-checked against fcitx5 5.1.7 dbusfrontend.cpp / keysym.h online |
| IME calls, redaction, wipe-on-drop | capabilities.md (T4: SharedIme, Action, KeyEvent) | reused as committed |
| Headless session, key injection | capabilities.md, `qa-artifacts/T1/lib.sh`, `rd.py`, `fake_systemd.py` | reused by sourcing with T6 dirs (no copy) |
| Private test bus | `grep -rn dbus-daemon tests/ crates/` (T8 sandbox is a shell harness) | new small helper `Bus` in tests/bus.rs (each Rust test needs its own bus) |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 | pass | `git status`: only crates/fe-fcitx/** + Cargo.lock (lock = deps of crates/fe-fcitx/Cargo.toml, per the merge route) |
| BASE-2 | pass | ime-core unchanged and used as committed; frontend contract: `ready.notify()` after both names (server.rs:69), Ok(()) only without a session bus (lib.rs `session_bus_configured`), Err with static text; tests fails_when_the_previous_owner_stays, ends_with_an_error_when_the_bus_goes_away |
| BASE-3 | pass | red seen: bus-run1.log (7/13), mutant-broadcast.log (7 fail), mutant-reply-first.log (5 fail); tests written alongside the code (deviation noted) |
| BASE-4 | pass | trimmed outputs above; full logs qa-artifacts/T6/test-final.log, clippy.log, smoke-final.log |
| BASE-5 | pass | tests, builds, clippy, smoke via run-heavy.sh; nothing left running (tag scan 0; no test dbus-daemon left) |
| BASE-6 | pass | English; comments explain why |
| BASE-7 | pass | no commit |
| BASE-8 | pass | zbus 6.5.0 = plan Toolchain choice (same as T5); futures-core 0.3.34 / serde 1.0.229 already in zbus's tree (no new crate); rustix workspace dep |
| BASE-9 | pass | signature check or typed deserialize on every method; `create_args_ok`; uid check server.rs:183; per-connection ownership (contexts.rs, AccessDenied); no logging in src |
| BASE-10 | pass | only `cargo test -p fe-fcitx` + fmt/clippy guard |
| BASE-11 | pass | code only in the T6 worktree; main tree untouched except team files |
| BASE-14 | pass | one long run went to the background and was resumed by notification; later runs bounded by timeouts |
| BASE-15 | pass | stopped only own processes: test dbus-daemons through their Child handle on drop, smoke processes by its own VRT1_TAG (lib.sh cleanup) |
| BASE-16 | pass | `## Reuse` table |
| BASE-17 | pass | nothing installed |
| BASE-18 | pass | no agents started |
| BASE-19 | pass | progress lines from the start |
| BASE-21 | pass | no secrets in outputs |
| BASE-22 | pass | names follow crate neighbours (`run`, `Options`) and fcitx5 naming |
| BASE-23 | pass | both InputMethod1 paths tested: portal path in every `App::open`, `/inputmethod` in contexts_per_client_are_capped |
| BASE-24 | pass | no git index/history command |
| BASE-25 | pass | `cargo fmt --check` exit 0; clippy --workspace --all-targets -D warnings exit 0 |
| BASE-32 | pass | D2/SEC-29 (private buses, isolated session, live fcitx5 6881 running before/after), D8/D19 (fcitx route for gnome-terminal), D22 (one task per client; reader only `try_send`s, server.rs:156) |
| BASE-34 | pass | no blocked step |
| BASE-38 | pass | rustfmt only on crates/fe-fcitx/src/*.rs and tests/bus.rs |
| BASE-45 | pass | AC-2/3/5/7/9 as in 01_spec.md §6 |
| BASE-46 | pass | final test, clippy and smoke runs came after the last code edit |
| COST-1 | pass | heavy commands through run-heavy.sh |
| COST-2 | pass | own tests + the one smoke the brief asks |
| COST-3 | pass | no polling loops of mine (smoke waits with `gdbus wait`) |
| COST-4 | pass | no full suite |
| COST-5 | pass | headless shell and terminal stopped by tagged cleanup; 0 left |
| COST-8 | pass | new files written whole, edits batched |
| COST-9 | pass | nothing of mine left running |
| COST-10 | pass | `grep -rl fe_fcitx crates` → only crates/vr-talex/src/main.rs (call site unchanged, compiled by clippy) + new tests |
| COST-13 | pass | scripts only under qa-artifacts/T6 |
| COST-16 | pass | full outputs in qa-artifacts/T6/*.log |
| AC-2 | pass (fcitx route part) | smoke typed exactly `việt |xin chào các bạn|class https git|`; pipelined ordering test replays_the_spike_sequence_and_types_viet; the 5,000-word stress run is T9 |
| AC-3 | pass | focus_out_reset_and_destroy_commit_the_word |
| AC-5 | pass (frontend part) | waits_for_the_previous_owner_to_leave, owns_both_names_once_ready; smoke: both names owned by the daemon pid |
| AC-7 | pass | password_field_passes_every_key_through (`matkhau1s` exact, no signals) |
| AC-9 | pass | smoke: daemon output 0 lines, 0 typed-text hits; callers_of_another_uid_are_refused |
| D8 | pass | fcitx5 frontend on the session bus serves GTK_IM_MODULE=fcitx apps (smoke) |
| SEC-1 | pass | no print/log calls in crates/fe-fcitx/src; static error strings; smoke 0 hits |
| SEC-2 | pass | no new text-holding type; ime-core's redacted `Action` / `KeyEvent` reused |
| SEC-4 | pass | surrounding text never decoded (server.rs:362); dropped actions wiped by ime-core; zbus buffer residue noted |
| SEC-8 | pass | GetConnectionUnixUser per client (server.rs:183, wire.rs:71); callers_of_another_uid_are_refused, only_the_same_uid_is_served |
| SEC-9 | pass | per-connection table (contexts.rs), AccessDenied on foreign paths, unicast signals (server.rs:421); another_connection_can_neither_use_nor_hear_a_context; broadcast mutant fails 7 tests |
| SEC-12 | pass | Password / Sensitive / Disable → passthrough (wire.rs:27); password_field_passes_every_key_through |
| SEC-13 | pass | set_caps commit sent before the reply: changing_to_password_commits_the_word_first |
| SEC-15 | pass | malformed_and_unknown_calls_get_errors_and_change_nothing (8 InvalidArgs, 5 unknown cases, context still works); no indexing / unwrap on wire data in src |
| SEC-16 | pass | 256 clients, 128 contexts/client, 256 queued calls/client, create args 16×512 B; contexts_per_client_are_capped, the_cap_refuses_one_more_context, create_args_are_bounded |
| SEC-27 | pass | `#![forbid(unsafe_code)]` (lib.rs) + workspace lint; no `unsafe` in crates/fe-fcitx |

## Fix round 1
Review: `05_review_T6.md`, verdict CHANGES_REQUESTED; QC passed.
- Finding 1 (major, caps and client-slot cleanup not tested) — **fixed** by adding tests. The tests found no code bug, so `src/` is unchanged; only `crates/fe-fcitx/tests/bus.rs` changed.
  - (a) `a_client_slot_is_freed_when_its_connection_leaves`: runs with `max_clients: 1`.
    - B is refused with `LimitsExceeded` while A is connected.
    - A closes its socket. B waits for the bus's `NameOwnerChanged` for A; the bus queues it to the frontend before B's next call, so the test needs no sleep and no retry.
    - B then creates a context and types `vieetj ` → `việt `.
    - A third client C is refused, because B now holds the only slot.
  - (b) `a_burst_beyond_the_queue_is_refused_and_serving_goes_on`: runs with `queue_per_client: 1`.
    - One client sends 64 `ProcessKeyEvent` calls without waiting for any reply.
    - Every call gets an answer, either success or `LimitsExceeded`, and the test checks that both kinds occur.
    - Afterwards that client and a second client each type `vieetj ` → `việt `, waiting for each reply.
  - (c) `malformed_and_unknown_calls_get_errors_and_change_nothing` is extended: after one client's bad calls, a bystander client connected beforehand and a newcomer connected afterwards both type `vieetj ` → `việt `.
  - Test helpers added: `App::close` (closes the socket, as when an app exits) and `App::type_one_by_one`.
  - The tests catch regressions in the code they cover (logs in `qa-artifacts/T6/`):
    - With the disconnect detection broken (`disconnected()` member name changed), (a) fails with `slot freed after A left: FDO(LimitsExceeded("too many clients"))` (`mutant-no-slot-release.log`).
    - With the client cap removed, (a) fails (`mutant-no-client-cap.log`).
    - `server.rs` was restored after each run, checked with grep.
  - Stability: the three new and changed tests passed in 5 of 5 repeated runs.
- Finding 2 (`ProcessKeyEventBatch` → UnknownMethod) — **not coded, per D25(a)**. It is a known limit. Only Qt apps started with `QT_IM_MODULE=fcitx` before install are affected; their keys arrive raw (nothing is lost) until the app restarts or the next login (D20).
- Finding 3 (commit and preedit text left in zbus message buffers without zeroize, CWE-226) — **not coded, per D25(b)**. It is an accepted residual risk for fe-fcitx and fe-ibus. Reading it needs a core dump (disabled by SEC-3) or a same-uid process reading the heap.

Commands, run in the worktree:
```
$ cargo test -p fe-fcitx --locked --offline --test bus          # new tests, first run
test result: ok. 15 passed; 0 failed
$ 5 runs: cargo test --test bus -- a_burst a_client_slot malformed
test result: ok. 3 passed; 0 failed   (x5)
$ mutation: disconnected() never matches   -> test result: FAILED. 0 passed; 1 failed
$ mutation: no max_clients check           -> exit 101 (a_client_slot fails)
$ cargo fmt --check                         -> exit 0
$ run-heavy.sh cargo clippy --workspace --all-targets --locked --offline -- -D warnings
    Checking fe-fcitx … Checking vr-talex … Finished (exit 0)
$ run-heavy.sh cargo test -p fe-fcitx --locked --offline
  unittests: test result: ok. 10 passed; 0 failed
  tests/bus.rs: test result: ok. 15 passed; 0 failed; finished in 0.67s
```
Logs: `qa-artifacts/T6/fix1-run1.log`, `fix1-clippy.log`, `fix1-test.log`, `mutant-no-slot-release.log`, `mutant-no-client-cap.log`.

Rule rows this round touches:
| Rule | Status | Evidence |
|---|---|---|
| SEC-15 | pass | malformed_and_unknown_calls_get_errors_and_change_nothing: a bystander and a newcomer type `việt ` after another client's bad calls |
| SEC-16 | pass | a_client_slot_is_freed_when_its_connection_leaves (max_clients); a_burst_beyond_the_queue_is_refused_and_serving_goes_on (queue_per_client); contexts_per_client_are_capped; mutant-no-slot-release.log, mutant-no-client-cap.log |
| SEC-4 | pass (residual accepted) | D25(b) |
| BASE-10 | pass | only `cargo test -p fe-fcitx` + fmt/clippy |
| BASE-38 | pass | rustfmt only on crates/fe-fcitx/tests/bus.rs |
| BASE-46 | pass | the final test and clippy runs came after the last edit; no src change, so the earlier smoke still applies to the same daemon code |
| COST-9 | pass | nothing left running (each test's dbus-daemon is stopped when the test ends; no background task) |

n-a: BASE-12 (no other repository) · BASE-13 (only my own test tmp dirs removed) · BASE-20 (nothing removed; the stub body was replaced) · BASE-26 (no rewrite) · BASE-27, BASE-30 (no shared data) · BASE-28 (no third-party code changed) · BASE-29, BASE-41 (no browser session or credentials) · BASE-31 (no container) · BASE-33 (no remote system) · BASE-35 (no user-rules lines for this area) · BASE-36 (single app) · BASE-37 (not a runtime-defect fix) · BASE-39 (no schema) · BASE-40 (no outward writes) · BASE-42 (no test-runner settings changed) · BASE-43 (no access rule change) · BASE-44 (no fake data adapter) · BASE-47 (no value fix) · COST-6 (no UI) · COST-7 (no web data) · COST-11 (no e2e spec; the smoke is the brief's one smoke) · COST-12 (leader rule) · COST-14 (no CI) · COST-15, COST-17 (no goldens) · COST-18 (no full run) · COST-19, COST-20 (qc rules, no screens)
