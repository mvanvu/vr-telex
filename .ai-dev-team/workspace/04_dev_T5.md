# T5 fe-ibus: IBus protocol frontend

Task: private mini broker + IBus service/engine/input context + panel InputMode property + address file.
Worktree `/home/rainy/DEV/vr-talex-wt-T5`, branch `t5-fe` from 7759c41. Nothing committed (BASE-7).

## Progress
- 1. start: notes created; read spec, plan (fe-ibus contract), spike Q3/Q6, threat model, D6/D8/D19–D22, ime-core API, T1 broker, T9 notes.
- 2. leader input (T9 findings): AC-3 click-away needs preedit mode COMMIT; VS Code terminal loses letters with preedit+commit. Both taken into the design (below).
- 3. wrote `crates/fe-ibus/src/{lib,address,ibus,socket,server,session}.rs` and `crates/fe-ibus/Cargo.toml`.
- 4. wrote tests: `tests/common/mod.rs`, `tests/protocol.rs`, `tests/security.rs`, `tests/address.rs`, unit tests inline. Honest order: code and tests were written in the same pass (tests after the first compile), not strictly test-first; the tests then found one real defect (item 5).
- 5. defect found by `calls_with_wrong_arguments_fail_without_harm`: zbus `<(u32,u32)>::try_from(Variant)` panics on a struct with fewer fields (zbus-6.5.0 `src/wire/structure.rs:395`), reachable by `Properties.Set ContentType (u)` = remote abort of the daemon in release. Fixed by matching the variant by hand (`ibus::content_type`, `ibus::flag`) + unit test.
- 6. `cargo test -p fe-ibus`: 22 unit + 10 address + 13 protocol + 15 security = 60 pass.
- 7. (running) `rustfmt` on changed files + `cargo fmt --check` + clippy workspace `-D warnings` (background task b1gxodtxv).

## Design (for a developer who continues)
Module map (`crates/fe-ibus/src/`):
- `lib.rs` — `run(ime, ready)` (contract of ime-core rule 6), `Config`, `Environment`, `Config::from_values` (pure, testable; `from_env` reads the env + machine id), `Limits` (connections 256, contexts/connection 64, message 128 KiB). No display (neither WAYLAND_DISPLAY nor DISPLAY) → `ready.notify()` + `Ok(())`.
- `address.rs` — `prepare_socket` (`$XDG_RUNTIME_DIR/vr-talex` 0700, real dir owned by uid; fixed socket name `ibus`; a stale entry is removed only if it is a socket of this user, anything else → refused), `bus_address` = `unix:path=<sock>,guid=<server guid>` (the guid changes per start → libibus reconnects; `guid` is the only extra key GDBus accepts on a unix address and it is verified against the handshake, so one `Guid` serves all connections of a run), `write_address_file` (bus dir real + owned; target must be absent or a regular file of this user — a symlink is refused; temp file `.<name>.vr-talex.tmp` with `create_new` 0600, then `rename`), `address_file_names` (`<mid>-unix-<WAYLAND_DISPLAY>` and `<mid>-<host|unix>-<DISPLAY number>`; values with path separators are skipped), `Published` drop guard (removes the socket and only those address files that still hold this run's content).
- `socket.rs` — own `ReadHalf`/`WriteHalf` over tokio `OwnedReadHalf/OwnedWriteHalf` handed to `zbus::connection::Builder::socket`. Why: zbus accepts 128 MiB messages and an unbounded SASL line. `Reader::receive_message` reads the 16-byte fixed header, checks `declared_len` against `Limits::message_bytes`, then delegates to the library's default assembly on the inner `Raw` half; `Reader::recvmsg` (handshake only) has a 16 KiB budget. Plain `read()` → file descriptors are never received. `peer_credentials` returns the `SO_PEERCRED` uid/pid so the library's EXTERNAL check compares the claimed uid with the real one.
- `server.rs` — `serve(config, ime, ready)`: prepare socket → bind → chmod 0600 → write address files → `ready.notify()` → accept loop. Per accept: semaphore slot (over the cap = stream dropped), `peer_cred()` uid check `uid_allowed` BEFORE the handshake (needed: zbus accepts `AUTH EXTERNAL` + empty `DATA` without an identity), then `tokio::spawn(session::serve)` — one task per client (D22). 10 accept failures in a row → `Err`. `serve_peers_of` (doc-hidden) is the test seam for a foreign peer uid.
- `session.rs` — one connection. Handshake with `.server(guid).p2p().auth_mechanism(External).validate_bodies()` under a 5 s timeout; then a loop over `next_event` (hand-written select of the message stream and `ModeWatch::changed`, no tokio macros). `Session` owns `contexts: HashMap<u64, Context>`; context numbers come from one global counter, paths `/org/freedesktop/IBus/InputContext_<n>`; a path not in this session's map → `UnknownObject` (SEC-9 is structural: another connection cannot name the context, signals are written only to the owning connection with its unique name as destination). `Drop for Session` destroys its contexts in ime-core and frees the panel role.
- `ibus.rs` — constants and value builders with `zbus::Structure::builder()` (public API; the spike's `to_owned_variant` is `#[doc(hidden)]`, so not used; no serde dependency): `text`, `preedit_text` (underline attribute), `engine_desc`, `mode_property`, `mode_property_list`, `is_private`, `content_type`, `flag`. Layouts were compared with libibus 1.5.29 output (python gi, read-only).

Pseudo bus: `org.freedesktop.IBus` has the unique name `:1.0`, clients `:1.<n>`. `Hello` must be the first call (else AccessDenied + close). Bus methods: Hello, RequestName (only `org.freedesktop.IBus.Panel`), ReleaseName, GetNameOwner, NameHasOwner, ListNames, AddMatch/RemoveMatch (validated, not stored — no signal is ever broadcast), Peer.Ping. Any other destination → ServiceUnknown (no routing, D19).
IBus object: CreateInputContext, SetGlobalEngine (only `vr-talex`), GetGlobalEngine, ListEngines, ListActiveEngines, IsGlobalEngineEnabled, GetUseGlobalEngine; Properties Get (Engines, ActiveEngines, GlobalEngine, EmbedPreeditText), GetAll, Set (PreloadEngines, EmbedPreeditText accepted and ignored). Not implemented on purpose (SEC-11): Exit, RegisterComponent, Ping, Introspect → UnknownMethod.
Input context: ProcessKeyEvent, FocusIn, FocusOut, Reset, SetCapabilities, SetCursorLocation(+Relative) (ignored: it follows every preedit, it is not a user cursor move), SetSurroundingText (dropped unread — ime-core has no surrounding-text call and SEC-4 says keep none), SetEngine, GetEngine, PropertyActivate, Service.Destroy, Properties Set ContentType `(uu)` / ClientCommitPreedit `(b)`, GetAll → `{}`.

How ProcessKeyEvent is ordered (B2): the session task reads one message, calls `SharedIme::process_key`, writes every resulting signal, then the reply `(b)`, and only then polls the stream again. GNOME Shell sends press and release without waiting; they queue in the stream and are answered in arrival order (`keys_sent_without_waiting_are_answered_in_order`). After the reply, `ModeWatch::try_changed` → `UpdateProperty` to the panel (toggle by this key); mode changes made elsewhere (fe-fcitx) arrive through the select branch.

Preedit mode for the AC-3 click-away finding (leader input 1): a context whose client set `ClientCommitPreedit` (GNOME Shell does) gets `UpdatePreeditTextWithMode (vubu)` with mode 1 = COMMIT; the client then commits the preedit it shows on focus loss/reset. On the client's `FocusOut`/`Reset`, ime-core returns `[HidePreedit, Commit]`; `Session::emit(.., client_flushed = true)` drops exactly the `Commit` that directly follows a `HidePreedit` when a preedit was on screen (`Context::preedit_shown`), and still sends the hide (an empty, invisible preedit update — it clears a preedit that could be left if a key and a click cross on the wire). Contexts without `ClientCommitPreedit` (Qt 5) get `UpdatePreeditText (vub)` and DO get the `CommitText` on FocusOut/Reset — the same split ibus-daemon makes. Held words (no preedit capability) are always sent.

Commit order for the VS Code terminal finding (leader input 2): ime-core ends a word with `[HidePreedit, Commit]`. `emit` sends `CommitText` first and the hide after it. Reasoning from xterm.js `CompositionHelper`: hide-first reaches the client as "composition cancelled" and then a separate plain insertion; xterm.js finalizes a composition on a zero-delay timer and reads the textarea afterwards, so with keys 15 ms apart the insertion is either cut (letters after the vowel lost) or sent twice (word repeated) — the symptoms in `qa-artifacts/T9/run-20261124-203148-347872/out/diff-code-term-*.txt`. Commit-first makes the commit replace the preedit in one step (text-input-v3 `commit_string` + `done`). **Not yet proven on the real app — see "Open".**

Panel (SEC-10): one owner. `claim_panel`: first asker gets it; the same connection → ALREADY_OWNER (4); another connection of the same peer pid takes over (GNOME Shell reconnecting before its old connection's close is seen); any other process → EXISTS (3). `RegisterProperties` is sent to the panel after SetGlobalEngine (reply, `GlobalEngineChanged` signal, then the call), after a GlobalEngine read and on FocusIn; `UpdateProperty` on every mode change. Both are method calls with NO_REPLY_EXPECTED; replies/signals from clients are ignored.

Timeouts: handshake 5 s; every send 5 s (a client that does not read is dropped, others are not affected). No logging anywhere in the crate (SEC-1); errors returned from `run` are static strings.

Dependencies added to `crates/fe-ibus/Cargo.toml` only: `zbus 6.5.0` (default-features off; `tokio`, `p2p`, `bus-impl`; no `tracing` feature on purpose), `tokio` features `net, rt, time, sync, io-util`, `rustix` (workspace; `getuid`). `Cargo.lock` changed accordingly.

## Tests (all pass, 60)
- unit (`src/*.rs`): IBusText / attr list / engine desc / property / prop list layouts and signatures; `content_type`/`flag` shapes; `is_private`; `declared_len`; `uid_allowed`; `claim_panel` (4 cases); address file names, machine id, bus address; `Config::from_values`.
- `tests/protocol.rs` (13): GNOME Shell's call sequence from the spike ending in `việt` (commit before the reply, commit before hide); pipelined keys; Ctrl+Shift toggle → UpdateProperty EN/VI + word committed; Ctrl+Shift+T no toggle; toggle from another frontend; FocusOut/Reset with ClientCommitPreedit (no second commit); without it (commit sent); no-preedit client (hold); surrounding-only client; password/PIN/private hint passthrough; content type switch mid-word; Destroy; two clients typing interleaved.
- `tests/security.rs` (15): ANONYMOUS / cookie / wrong uid claim rejected; foreign peer uid dropped before the handshake; foreign context → UnknownObject for 7 calls and the owner's word intact; no signal leaks to a second connection; surface (Exit, Introspect, other engine, other name, routing → errors); 15 wrong-argument calls → InvalidArgs; Hello first; garbage / lying header / noise end only that connection; message size cap (incl. a 100 MiB header); endless handshake line; contexts per connection cap; connection cap and slot reuse; departed client frees panel; panel rule; password context sends the panel nothing.
- `tests/address.rs` (10): socket 0600 in 0700 dir; both address files 0600 with live pid and `unix:path=…,guid=…`; new address per start; stale socket taken over; symlink at address file → refused, target untouched, nothing half published; symlinked bus dir refused; temp-file symlink not followed; socket path taken by file/link/dir-link refused; missing runtime dir; stop removes own files only.

## Left to do
1. Read the result of background task b1gxodtxv (fmt check + clippy); fix findings.
2. `cargo build --release -p vr-talex` in the worktree (via run-heavy.sh), then the T9 harness from the main tree against it: `VR_TALEX_BIN=/home/rainy/DEV/vr-talex-wt-T5/target/release/vr-talex $TEAM_BIN/run-heavy.sh bash /home/rainy/DEV/vr-talex/tests/e2e/run.sh --smoke --ime daemon --out $TEAM_WS/qa-artifacts/T5` (gnome-shell connects, `vieetj ` → `việt `, toggle, AC-3 window switch + click, AC-7, SEC-1 leak scan). Run as a background task (BASE-14).
3. VS Code terminal: `run.sh --ime daemon --apps code-term --runs 2 --words 40 --scenarios ""`. If it still fails, A/B with hide-first (temporary local edit, not a flag) to confirm the cause; if the cause needs an ime-core change → `BLOCKED` with the evidence (do not edit ime-core).
4. Final `cargo test -p fe-ibus --locked` via run-heavy.sh, guard output, `## Rule compliance`, `## Reuse`, capabilities.md lines.

## Open
- VS Code integrated terminal (leader input 2): root cause is a hypothesis until step 3 runs. Evidence so far is the code reading above plus T9's diffs; no run with the real daemon yet.
- The harness reports AC-10 as SKIP for `--ime daemon` (no per-key timing interface; T9 finding 4, leader's call).

## Deviations from the plan
- Socket name is fixed (`vr-talex/ibus`, as SEC-6's `…/vr-talex/bus` intends) instead of `ibus-<rand>`; the address string changes through `guid=` instead. Why: no socket files pile up over restarts, and SEC-7's "remove a stale socket only if it is ours" has one place to check.
- No peer routing and no NameOwnerChanged signal (D19).
- `Exit` not implemented (SEC-11 "if implemented").
- SetSurroundingText is dropped: ime-core has no call for it.
- Context numbers are global, not per connection (ownership stays per connection).

## Out-of-scope issues noticed
- zbus 6.5.0: `TryFrom<Variant> for (A, B, …)` panics on a shorter struct (`src/wire/structure.rs:395`); T6 (fe-fcitx) should avoid tuple conversion of client variants too.
- zbus server handshake accepts `AUTH EXTERNAL` followed by an empty `DATA` without comparing a uid; a peer-credential check before the handshake is required in every frontend that listens on a socket.
- 8. fmt + clippy clean; release build ok; e2e smoke 1 with the real daemon (qa-artifacts/T5/smoke-1.out): term 734/734, chrome 734/734, AC-7, AC-4 (7 ms / 3 ms), AC-3 window switch + click, SEC-1 0 hits — all PASS. Next: code-term 2 runs (background).
- 9. code-term with the daemon (codeterm-1.out): 2/2 FAIL, lost 14 / lost 20, extra 0 — commit-first removed the repeats, losses remain (last letters after the vowel, some whole words). Hypothesis: xterm.js reads the composition end offset in a zero-delay timer; a real key that follows before the timer runs finalizes with a stale offset. Experiments running (exp.sh): slow = base binary at 50 ms/key; expA = temporary build where a printable boundary key is committed together with the word (no real key after the composition). Source restored to base after building bin/vr-talex-expA.
- 10. experiments (exp-slow.out, exp-expA.out): base binary at 50 ms/key → code-term PASS 639/639 (so the loss depends on timing inside the client); expA at 15 ms/key → run 2 PASS 639/639, run 1 FAIL lost 42 / extra 5 (whole words at the start of a line lost). Conclusion: the cause is in xterm.js (timer-based composition handling, see "VS Code terminal" below); no frontend ordering makes it lossless; expA is NOT kept (source is the base again). Next: omnibox + code once with the base binary, then latency test + final cargo test + guard.
- 11. omnibox + code with the base daemon (apps-1.out): PASS 639/639 each. Added `tests/latency.rs` (D24). Final `cargo test -p fe-ibus --locked`: 61 pass; fmt + clippy clean. Experiment binaries and sandbox homes removed; nothing left running. capabilities.md updated. Leader note: T6 merged to master as 8830628; this branch was not rebased (Cargo.lock is merged by the leader).

# Result
- Files changed: `crates/fe-ibus/Cargo.toml`, `crates/fe-ibus/src/lib.rs` (replaced), new `crates/fe-ibus/src/{address,ibus,server,session,socket}.rs`, new `crates/fe-ibus/tests/{address,protocol,security,latency}.rs`, `crates/fe-ibus/tests/common/mod.rs`; `Cargo.lock` (zbus and its dependencies).
- Team files: this file, `.ai-dev-team/capabilities.md` (5 lines), `qa-artifacts/T5/` (smoke-1.out, codeterm-1.out, exp-slow.out, exp-expA.out, apps-1.out, exp.sh, run-*/out + logs).

## Commands run + result (trimmed real output)
```
$ run-heavy.sh cargo test -p fe-ibus --locked -- --nocapture
unittests src/lib.rs   test result: ok. 22 passed; 0 failed
tests/address.rs       test result: ok. 10 passed; 0 failed
tests/latency.rs       ProcessKeyEvent round trip over 4000 keys: p50 371.267µs, p99 658.459µs, max 1.091263ms
                       test result: ok. 1 passed; 0 failed
tests/protocol.rs      test result: ok. 13 passed; 0 failed
tests/security.rs      test result: ok. 15 passed; 0 failed
$ cargo fmt --check                                  -> FMT-OK (rc 0)
$ run-heavy.sh cargo clippy --workspace --all-targets --locked -- -D warnings
    Finished `dev` profile [unoptimized + debuginfo] target(s)   (rc 0, no warning)
$ run-heavy.sh cargo build --release --locked -p vr-talex        -> Finished `release` profile in 52.63s
$ VR_TALEX_BIN=<worktree>/target/release/vr-talex run-heavy.sh bash tests/e2e/run.sh --smoke --ime daemon --skip-install --allow-incomplete   (smoke-1.out, rc 0)
ime (daemon) connected after ~0 s: vr-talex|VI
RESULT AC-2:term-1 PASS  expected 734 chars, got 734; lost 0, extra 0, replaced 0; mean 15.0 ms/key
RESULT AC-2:chrome-1 PASS  expected 734 chars, got 734; lost 0, extra 0, replaced 0; mean 15.1 ms/key
RESULT AC-7 PASS password field got matkhau1s raw
RESULT AC-4 PASS toggle PASS: VI->EN 7 ms, EN->VI 3 ms;combos PASS: Ctrl+Shift+P/C/V/T left the mode at VI; page saw Ctrl+Shift+[P,C,V]; pages 1 -> 2 after Ctrl+Shift+T
RESULT AC-3 PASS window switch: [việt] expected [việt]; click elsewhere (focus moved to #o): [đường] expected [đường]
RESULT AC-10 INCOMPLETE measured in unit tests (D24)
RESULT SEC-1 PASS SEC-1 leak scan: 60 tokens, 175 files, 91 journal lines since the run started, 0 hits
$ run.sh --ime daemon --apps "omnibox code" --runs 1 --words 40 --scenarios ""      (apps-1.out, rc 0)
RESULT AC-2:omnibox-1 PASS  expected 639 chars, got 639; lost 0, extra 0, replaced 0
RESULT AC-2:code-1 PASS  expected 639 chars, got 639; lost 0, extra 0, replaced 0
$ run.sh --ime daemon --apps code-term --runs 2 --words 40 --scenarios ""           (codeterm-1.out, rc 1)
RESULT AC-2:code-term-1 FAIL  expected 639 chars, got 625; lost 14, extra 0, replaced 0 (injection 21.1 ms/key)
RESULT AC-2:code-term-2 FAIL  expected 639 chars, got 619; lost 20, extra 0, replaced 0; mean 15.2 ms/key
$ exp.sh slow <base binary> --runs 1 --delay 0.05   -> code-term-1 PASS 639/639, mean 50.0 ms/key
$ exp.sh expA <temporary build> --runs 2            -> code-term-1 FAIL lost 42, extra 5; code-term-2 PASS 639/639
```
The smoke is the T9 harness (isolated `dbus-run-session`, sandbox HOME/XDG, guard), used instead of a new script on T1's lib.sh — the leader allowed it; it covers what the brief's smoke asked (gnome-shell connects, Telex words typed into gnome-terminal and read back, toggle). Live desktop untouched: the live fcitx5 is still pid 6881.

## VS Code terminal (leader input 2) — finding, NOT fixed
- Symptom with the real daemon: only losses (no repeats): the last letters of a word, sometimes whole words. gnome-terminal, Chrome textarea, omnibox and the VS Code editor are lossless at 15 ms/key with the same daemon.
- Evidence that the cause is inside the client (xterm.js), not the daemon: (1) the same binary is lossless at 50 ms/key; (2) every other target is lossless at 15 ms/key; (3) the daemon's order on the wire is proven by `keys_sent_without_waiting_are_answered_in_order` and by the smoke.
- Mechanism — from reading xterm.js `CompositionHelper` from memory, NOT measured inside VS Code, so treat it as a hypothesis that fits both experiments: xterm.js learns where a composition ends from a `setTimeout(0)` after each `compositionupdate`, and sends a finished composition from another `setTimeout(0)` guarded by one `_isSendingComposition` flag. A real key (space, Enter) that arrives before those timers ran finalizes with a stale end offset → the letters typed since are dropped (base daemon). With no real key in between (expA), a second composition that ends before the first timer ran has its send cancelled by the first → whole words dropped. The headless VS Code renders in software and its main thread is busy at 15 ms/key, so timers wait behind input events. Whether a session with a real GPU shows the loss could not be tested (the live desktop is off limits, D2).
- What the frontend does about it: commit before hide (it removed the repeated words the stub showed). No ordering of fe-ibus signals can make timer-ordered client code lossless while a preedit is used; without a preedit a terminal cannot be corrected at all (no surrounding text there; fake BackSpace is an anti-goal).
- Options (product decision, none taken): (a) accept as a client limitation, check it on the real desktop in the manual run O1, document it; (b) "hold" mode for this client — the word appears only at the boundary — but fe-ibus cannot tell the VS Code terminal from the VS Code editor (one shell context, ContentType (0,0) for both), so it needs a user-visible switch and an ime-core change; (c) expA (word + boundary character committed as one text) passed 1 of 2 runs, changes key semantics for every app and belongs in ime-core — not recommended. Proposed default: (a), plus one T9/QC run of code-term with VS Code's `terminal.integrated.gpuAcceleration` set to `off` to measure how much the headless renderer contributes.

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| broker skeleton (listener, p2p server builder, Hello/RequestName answers) | qa-artifacts/T1/broker/src/main.rs | structure reused; rewritten (no logging, limits, ownership, tests) |
| IBus value layouts | spike Q3, T1 fake_ibus.py, libibus via python gi (read-only) | reimplemented in `ibus.rs` with `Structure::builder` |
| atomic, symlink-safe file write | crates/ime-core/src/state.rs (`FileStateStore::try_save`) | same pattern in `address.rs` (the store itself is specific to the mode file) |
| getuid without unsafe | workspace `rustix` (T4) | reused |
| temp dir naming for tests | crates/vr-talex/src/main.rs tests `unique` | same convention in tests/common |
| headless smoke (guard, shell, injection, readback) | tests/e2e (T9), qa-artifacts/T1/lib.sh | T9 harness used through `VR_TALEX_BIN`; no new script |
| capabilities index | .ai-dev-team/capabilities.md | nothing IBus-side existed; 5 lines added |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 scope | pass | `git status --short` in the worktree: only `crates/fe-ibus/**` and `Cargo.lock` |
| BASE-2 contracts | pass | ime-core used as committed (`SharedIme`, `Ready`, rules 1–7); no ime-core edit; the code-term options that need one are reported, not built |
| BASE-3 tests first | fail | code and tests were written in one pass (progress 4), not red-first; every behaviour has a test and the suite found a real defect (progress 5). Reported as a process deviation for the leader to judge |
| BASE-7/24 no git add/commit | pass | no git write command run |
| BASE-8 dependencies justified | pass | comments in `crates/fe-ibus/Cargo.toml`; zbus 6.5.0 with tokio/p2p/bus-impl as in the spike; no serde or futures-util added |
| BASE-10 related tests + guard only | pass | `cargo test -p fe-ibus`, fmt, clippy; e2e limited to the smoke, 3 short target runs and 2 experiments |
| BASE-11 other worktrees untouched | pass | main tree only read (tests/e2e run through `VR_TALEX_BIN`, output to `$TEAM_WS/qa-artifacts/T5`) |
| BASE-14 no waiting loops | pass | long runs were background tasks; the turn ended each time |
| BASE-15 stop only own processes | pass | harness tag cleanup (`cleanup: stopped 21 tagged processes`); nothing stopped by name |
| BASE-16 reuse | pass | Reuse table; capabilities.md updated |
| BASE-17 install nothing | pass | crates through cargo only; no tool installed |
| BASE-18 no sub-agents | pass | none started |
| BASE-19 notes from the start | pass | progress 1–11 |
| BASE-21 no secrets in notes | pass | the corpus is synthetic |
| BASE-22 naming | pass | module and test names follow ime-core's style |
| BASE-23 test per entry path | pass | FocusOut and Reset; with/without ClientCommitPreedit; preedit / surrounding / hold; password, PIN, private hint |
| BASE-25 guard | pass | fmt --check rc 0; clippy -D warnings rc 0 |
| BASE-34 / DESIGN-23 | pass | no network use |
| BASE-38 formatters on changed files | pass | `rustfmt` only on fe-ibus files |
| other BASE rules | n-a | no UI, API, data model, migration |
| COST-8 edits | pass | files written whole; edits with perl -pi / Edit |
| COST-9 nothing left running | pass | 0 `/tmp/vrt-e2e.*` dirs, 0 processes of this task, all background tasks exited |
| COST-13 throwaway scripts | pass | `qa-artifacts/T5/exp.sh` |
| COST-16 context | pass | notes brought up to date on the leader's request |
| other COST rules | pass / n-a | heavy commands through run-heavy.sh; no browser outside the harness |
| SEC-1 no typed text in output | pass | no log or print macro in `crates/fe-ibus/src` outside tests (grep); errors are static strings; harness leak scan 0 hits in 3 runs |
| SEC-2 redaction | pass | `Context` and `Session` derive no Debug; actions are only borrowed; no unwrap/expect outside tests |
| SEC-4 minimal retention | pass | SetSurroundingText dropped unread; `Drop for Session` destroys contexts (`a_departed_client_leaves_nothing_behind`). Residual: text sits in zbus message buffers until they are dropped (the library does not wipe them) |
| SEC-6 path socket | pass | `the_socket_is_a_private_path_socket`; `address_is_a_path_address_with_the_guid` |
| SEC-7 safe creation | pass | tests/address.rs: link at the file path / bus dir / temp file / socket path refused or not followed; atomic rename |
| SEC-8 peer authentication | pass | `only_external_authentication_is_accepted`, `a_peer_of_another_user_is_dropped_before_the_handshake`, `only_the_own_user_is_allowed` |
| SEC-9 context isolation | pass | `a_context_belongs_to_the_connection_that_created_it`, `signals_of_a_context_reach_only_its_connection` |
| SEC-10 panel role | pass | `the_panel_role_follows_the_documented_rule`, `claim_panel` unit tests, `a_password_context_sends_the_panel_nothing` |
| SEC-11 minimal surface | pass | `only_the_ibus_surface_is_served`; method list under "Design" |
| SEC-12 password passthrough | pass | `password_fields_get_their_keys_untouched`; harness AC-7 PASS |
| SEC-13 transitions | pass | `a_field_turning_into_a_password_field_commits_the_word_first`; focus tests; harness AC-3 PASS |
| SEC-15 robust parsing | pass | `calls_with_wrong_arguments_fail_without_harm`, `bytes_that_are_not_dbus_end_only_that_connection`, `property_values_of_any_other_shape_are_refused` |
| SEC-16 resource caps | pass | `connections_are_limited`, `input_contexts_per_connection_are_limited`, `a_message_over_the_size_limit_ends_the_connection`, `a_handshake_that_never_ends_is_cut_off` |
| SEC-27 no unsafe | pass | `#![forbid(unsafe_code)]` in lib.rs; grep `unsafe` in src finds only that line |
| SEC-29 / D2 isolation | pass | only the T9 harness (guard) was used; live fcitx5 pid unchanged (6881) |
| AC-2 | partial | term, chrome, omnibox, code PASS (short runs); code-term FAIL — see the finding |
| AC-3 | pass | harness AC-3 PASS (window switch + click); protocol tests |
| AC-4 | pass | harness AC-4 PASS (7 ms / 3 ms; combos) |
| AC-5 | n-a here | hot connect shown (`ime (daemon) connected after ~0 s`); the install scenario belongs to T8/T9 |
| AC-9 | pass | SEC-1 scan 0 hits; socket 0600 in 0700 + uid check |
| D6 / D8 / D19–D22 | pass | InputMode property VI/EN; one-service bus with several clients (`several_clients_type_at_the_same_time_without_mixing`); one task per connection; send timeout |

## Fix round 1
Developer taking over (previous context ran out). Findings: (1) SEC-7 second instance, (2) Qt5 Reset commit (verify), (3) `serve_peers_of` public.
- f1. notes section created; read notes, review, decisions D19–D26.
- f2. finding 1 red: `a_second_instance_leaves_the_running_one_alone` (second frontend got ready = took over) and `stopping_leaves_a_socket_it_did_not_create` (left None) FAIL (qa-artifacts/T5/fix1-red-f1.txt).
- f3. finding 1 code: `address::take_lock` (`<runtime>/vr-talex/ibus.lock`, 0600, real file of this uid, `File::try_lock` = flock LOCK_EX|LOCK_NB) before the stale-socket removal; `PrepareError::Running` → `Err("fe-ibus: another instance is running")`; `Published` keeps the socket's (dev, ino) from right after bind and removes the socket only when it still matches; the lock is its last field (released after cleanup). Green: address 12/12 (fix1-green-f1.txt).
- f4. finding 3 code: `serve_peers_of` behind feature `test-support` (crates/fe-ibus/Cargo.toml), enabled only by a self dev-dependency; the release path goes through private `serve_with_peer_uid`. Cargo.lock +1 line (`fe-ibus` in fe-ibus's own dependency list).
- f5. finding 2: baseline debug daemon copied to qa-artifacts/T5/qt5/vr-talex-base; isolated session script qa-artifacts/T5/qt5/session.sh (reuses tests/e2e/lib.sh; FIFO command channel) started in background.
- f6. finding 2 investigation (baseline daemon, qa-artifacts/T5/qt5/run1): Qt 5.15.13 `libibusplatforminputcontextplugin.so` in `sqlitebrowser` (Qt5 widgets, QT_QPA_PLATFORM=wayland, QT_IM_MODULE=ibus), wire traced with `strace` on the app. (a) Without an `ibus-daemon` executable on PATH the Qt 5 plugin never connects (raw keys) — Qt 5.15 sets `valid = !findExecutable("ibus-daemon").isEmpty()`; a dummy `ibus-daemon` on the app's PATH (sandbox only) made it connect. (b) Click from filter field a into field b mid-word: wire = `Reset`, `FocusIn` → fe-ibus `CommitText("việt")` → result a="…việt" AND b="việt" (doubled; shot7/c7.png). (c) Click inside the same field outside the preedit: `Reset` → `CommitText("đường")` inserted again at the new cursor: "đường|việt|đường" (c8.png). Reviewer's finding confirmed.
- f7. finding 2 red: `a_client_that_does_not_commit_its_preedit_gets_the_word_once` FAIL (left [Commit("viêt"), hide], right [hide]) — fix1-red-f2.txt. Code: `session::Cause {Engine, FocusOut, Reset}`; on `Reset` the commit of a shown preedit is never sent (both client kinds); on `FocusOut` only for ClientCommitPreedit clients (unchanged). Green: protocol 13/13 (fix1-green-f2.txt). Fixed debug daemon → qt5/vr-talex-fix; replay in qt5/run2.
- f8. replay with the fixed debug daemon (qt5/run2): click a→b mid-word and click inside b outside the preedit → a="việt", b="đường", each once (run2/c-fix.png); wire tail shows Reset/FocusIn/FocusOut and no CommitText. Second real instance in the same session: `vr-talex` exit 1, stderr `vr-talex: frontend ibus failed: fe-ibus: another instance is running`; socket inode 15881588 and address-file md5 431c9875… unchanged before/after; the Qt app types "năm" afterwards (run2/c-second.png), shell state still `vr-talex|VI`.
- f9. guard + tests + release + daemon smoke (fix1-final.sh); clippy found `cloned_ref_to_slice_refs` in the new test → `std::slice::from_ref`; rerun clean. Probe crate (probe-f3, removed after) shows the seam is gone without the feature. Session sandboxes and the copied debug binaries removed; 0 `/tmp/vrt-e2e.*` left, no sqlitebrowser/daemon process left.

### Fix round 1 result
| # | Finding | Reply | Red → green |
|---|---|---|---|
| 1 | SEC-7 second instance takes the live socket/files | fixed: instance lock `<runtime>/vr-talex/ibus.lock` (flock via `File::try_lock`) taken before any removal or write; refusal → `Err("fe-ibus: another instance is running")` → daemon exits FAILURE; cleanup removes the socket only when its (dev, ino) is still the one this run bound, address files only when they still hold this run's content (unchanged); lock released after cleanup | `a_second_instance_leaves_the_running_one_alone`, `stopping_leaves_a_socket_it_did_not_create`: FAIL → ok (fix1-red-f1.txt → fix1-green-f1.txt); real binary in qt5/run2 (f8) |
| 2 | Qt 5 word doubled on Reset | fixed after verification with the real Qt 5 client (f6): on `Reset` the commit of a word whose preedit is shown is never sent; `FocusOut` unchanged (commit sent to non-ClientCommitPreedit clients, skipped for ClientCommitPreedit); held words (no preedit) still sent on both. GNOME Shell path unchanged (same skip rule for ClientCommitPreedit; `focus_out_and_reset_leave_the_commit_to_a_client_that_commits_its_preedit` unchanged and green; smoke AC-3 PASS) | `a_client_that_does_not_commit_its_preedit_gets_the_word_once` FAIL → ok (fix1-red-f2.txt → fix1-green-f2.txt); Qt 5 replay c7/c8 (doubled) → c-fix (once) |
| 3 | `serve_peers_of` public in release | fixed: `#[cfg(feature = "test-support")]`, feature enabled only by the crate's own dev-dependency; release path uses private `serve_with_peer_uid` | probe crate: without feature `E0425 cannot find value serve_peers_of`, with feature compiles (fix1-probe-f3.txt). No failing-first test possible inside the crate: tests always build with the feature |

Qt 5 sources relied on (Qt 5.15, `src/plugins/platforminputcontexts/ibus/qibusplatforminputcontext.cpp`, read from memory and matched by the wire trace, not by opening the file — no Qt source on this machine): `QIBusPlatformInputContext::commit()` sends a `QInputMethodEvent` with `setCommitString(d->predit)` to the focus object, then `d->context->Reset()`; `invokeAction(Click)` calls `commit()`; `QIBusPlatformInputContextPrivate` ctor: `valid = !QStandardPaths::findExecutable("ibus-daemon").isEmpty()`; `commitText` slot inserts into `qApp->focusObject()` (the new field after a focus change). `QWidget::setFocus` calls `QGuiApplication::inputMethod()->commit()` for the previous input-method widget. Trace: run1/logs/qt2.strace (Reset at 21:27:07.262459, CommitText read 21:27:07.264497, then the word in field b).

### New states (round 1)
- Lock file `ibus.lock` (stays in the 0700 runtime dir, empty). Crash/kill → kernel releases the flock; the next start takes over the stale socket (`a_restart_takes_over_the_socket_of_a_dead_run` green). Two starts at once → flock is atomic, exactly one wins (`a_second_instance_leaves_the_running_one_alone`). Lock path replaced by a link/dir → `Unsafe` → "cannot use the socket directory", nothing touched. Runtime dir is tmpfs (no hung network FS case).
- Socket identity: unreadable after bind → `None` → the socket is left on stop (the next start removes it under the lock). Replaced by someone else → left (`stopping_leaves_a_socket_it_did_not_create`).
- `Cause::Reset` skip: a client that discards its preedit on Reset (Qt `reset()`, programmatic `setText`) loses that uncommitted word — the same as ibus-daemon with an engine that discards on reset; accepted (Qt 5's focus/click paths all go through `commit()`, verified).

### Out-of-scope found this round (for the leader)
- **D20 risk**: Qt 5's IBus plugin is valid only when an `ibus-daemon` executable is on PATH. This machine has no ibus (D23), so with `QT_IM_MODULE=ibus` Qt 5 apps get raw keys — no Vietnamese at all — until something named `ibus-daemon` exists in PATH. Seen in qt5/run1 (raw "vieetj" with the plugin loaded; connects once a dummy `ibus-daemon` is on PATH). Belongs to T8/D20 (installer/env), not fe-ibus: options are a user decision (e.g. a `ibus-daemon` shim on PATH, or `QT_IM_MODULE=fcitx` for Qt with fe-fcitx).

### Commands (round 1, trimmed)
```
$ cargo fmt --check                                                     -> rc 0
$ run-heavy.sh cargo clippy --workspace --all-targets --locked -- -D warnings  -> Finished, rc 0 (after from_ref fix)
$ run-heavy.sh cargo test -p fe-ibus --locked   (fix1-test.txt)
  unittests 22 ok; address 12 ok; latency 1 ok; protocol 13 ok; security 15 ok  (63)
$ cargo test -p fe-ibus --locked --test protocol (after the lint fix)   -> 13 passed
$ run-heavy.sh cargo build --release --locked -p vr-talex               -> Finished release
$ run.sh --smoke --ime daemon --skip-install --allow-incomplete (fix1-smoke.out, rc 0)
  AC-2 term/chrome 734/734 PASS; AC-7 PASS; AC-4 PASS (1 ms / 4 ms); AC-3 PASS window switch [việt], click [đường]; SEC-1 0 hits; AC-10 INCOMPLETE (D24)
```
Files changed this round: crates/fe-ibus/src/{address,server,session,lib}.rs, crates/fe-ibus/Cargo.toml (feature + self dev-dependency), crates/fe-ibus/tests/{address,protocol}.rs, Cargo.lock (+1 line: `fe-ibus` in fe-ibus's dependency list).

### Rule compliance — rows changed in round 1
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 scope | pass | `git status`: only crates/fe-ibus/** and Cargo.lock (+1 line from the self dev-dependency) |
| BASE-3 test fails first | pass (round 1) | f1/f2 red files before code; f3: probe evidence (in-crate test impossible, see table) |
| BASE-7/24 | pass | no git write |
| BASE-14 | pass | sessions, final run as background tasks; no waiting loops in my turns |
| BASE-15 | pass | only own tagged processes stopped (session cleanup "stopped 18 tagged processes" ×2; Qt app killed by pid after checking its VRT_E2E_TAG) |
| BASE-19 | pass | "Fix round 1" f1–f9 |
| BASE-25 guard | pass | fmt rc 0, clippy rc 0 |
| BASE-38 | pass | rustfmt only on the 6 changed fe-ibus files |
| COST-9 | pass | 0 /tmp/vrt-e2e.*, no sqlitebrowser/daemon left, probe target removed |
| COST-13 | pass | scripts in qa-artifacts/T5 (qt5/session.sh, fix1-final.sh, probe-f3) |
| SEC-7 | pass (was fail) | finding 1 tests + qt5/run2 real second instance |
| SEC-13 | pass | Qt focus/click path verified on the real client (no loss, no doubling) |
| SEC-16 | pass | unchanged caps; lock adds one fd per run |
| SEC-29 / D2 | pass | only isolated dbus-run-session sandboxes via tests/e2e/lib.sh guard; live desktop/fcitx5 not touched |
| AC-3 | pass | smoke AC-3 PASS with the round-1 release binary; Qt 5 click cases once |

Merge resolution: Cargo.lock conflict resolved by taking master's lock (:3) and running cargo update -w --offline; zbus 6.5.0, tokio 1.54.1 same as both parents; fe-ibus and fe-fcitx tests, fmt and clippy pass.
