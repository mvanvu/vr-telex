# Review FR-8 (code + security) — APPROVED

Scope: `git diff master...fr8-omnibox -- crates tests` (e1778d5 + merge b1b8a08). `git diff master fr8-omnibox` has the same 6 files, so the merge left nothing of master's changed.

## Files read
| File | Status |
|---|---|
| crates/fe-ibus/src/ibus.rs | read |
| crates/fe-ibus/src/session.rs | read (whole diff + bus_call, ibus_call, context_call, apply_caps, emit, preedit) |
| crates/fe-ibus/tests/common/mod.rs | read (+ `shell_context` helper) |
| crates/fe-ibus/tests/protocol.rs | read |
| tests/e2e/e2e.py | read |
| tests/e2e/run.sh | read (+ lib.sh cleanup tag) |
| Also checked | ime-core ime.rs `set_caps`/`flush`/`Edit::of`, shared.rs, lib.rs rules 1-3; decisions D10, D22, D35; qa-artifacts/FR-8/e2e/run-20261125-053640-3056509 |

## Checks asked in the brief
- **D35 shell safety.** `Context::caps(shell)` masks `surrounding_text` when `client_commit || is_panel()`. Caps are re-applied on SetCapabilities, ContentType, ClientCommitPreedit and, for every context, on a granted panel claim, all inside the connection's own task before its next message. A switch out of Surrounding mode flushes nothing (`flush` sends no Delete or Commit in Surrounding mode), so a stray Delete cannot be produced during the switch. Once a context counts as the shell's, `Edit::Surrounding` cannot be chosen, so the guard at session.rs:898 cannot be reached. That also means no Delete can be dropped while its Commit still goes out, so no text can be duplicated. Losing the panel later keeps the mask on, which is the safe side. If a non-shell client sets ClientCommitPreedit, it only loses a capability. Nothing is exploitable.
- **Address gap and ordering.** `tokio::time::sleep` runs in emit, which only this connection's task runs. `SharedIme::call` has already released the IME lock (process_key/set_caps return a `Vec`), so other connections are not blocked (D22c). The order on the wire is hide, 5 ms, CommitText, then the `handled` reply (session.rs:699-700), so lib.rs rule 2 holds. A key or FocusOut sent during the gap waits in the connection's queue until emit finishes, and the engine has already committed the word, so nothing is doubled. A FocusOut/Reset with the preedit shown takes the `skip_commit` arm first (FR-10 behaviour unchanged).
- **Root cause.** The Chromium OnDone → UpdateCompositionIfTextSelected chain fits the traces: one `done` drops the completion, and with separate `done`s it is kept (exp4 trace 47.536338 done(233) | 47.542290 done(234) → github.test). Merged run 053640: FR-8 PASS on all 12 cases. AC-2 term/chrome/omnibox each 1906/1906 with 0 lost, 0 extra. AC-3, AC-3:chrome-kept and AC-3:term PASS. SEC-1 PASS. No `meta_wayland_text_input` assertion or crash.
- **Tests.** The notes record the red run (13 passed, 2 FAILED, with the messages) and the green run with 21 protocol tests. Both new tests assert what their names say. The address test also pins the non-URL order (Commit then hide), and the Delete test covers all three ways a context becomes the shell's.
- **Merge.** SetGlobalEngine/set_enabled from FR-7 (session.rs:613-654, 492) is intact. The test list differs from master only by the 2 new tests, and FR-10's FocusOut test is kept.

## Findings
[minor] crates/fe-ibus/src/session.rs:878-886 — a focus change inside the 5 ms gap moves the word
Scenario: in the address bar, the boundary key goes out, then the shell moves the focus within 5 ms. The shell already holds a cleared preedit, so it commits nothing on focus-out. Our CommitText then arrives after the focus has moved, so the word may land in the newly focused field or be dropped. Before this change the commit went out first, so this window did not exist. No user path reaches it: Enter and Tab act only after the reply, and a click 5 ms after a key is not a human timing. Reachability is uncertain.
Fix: none needed in code. Add it to the report's known limits next to the "+5 ms, word briefly cleared" trade-off.

[minor] 04_dev_FR-8.md "Merge with master" — the claim "shell.log 0 assertion/crash lines" is not exact (BASE-48)
Scenario: run 053640 shell.log has 6 GLib-CRITICAL `g_variant_get_boolean` assertion groups. They are not caused by FR-8: run 050938 (master daemon) has 3 and the earlier runs have 0–5. A reader who checks the file finds the claim false.
Fix: write "0 mutter text-input assertions or crashes; GLib-CRITICAL g_variant lines pre-existing (also in the master-daemon run 050938)".

## Rule check FR-8
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 scope | pass | product change limited to fe-ibus caps/emit + PURPOSE_URL; ime-core, fe-fcitx untouched |
| BASE-3 contracts | pass | IBus signal set unchanged; only the hide/commit order and timing change, and only for ClientCommitPreedit + purpose 5 |
| BASE-7/24 tests | pass | red: 2 FAILED with messages in the notes; green: protocol 21; e2e suggest FAIL before (050938) → PASS (052836, 053640) |
| BASE-19 notes | pass | Continuation + Merge sections |
| BASE-37 before/after | pass | runs 050938 / 053640, same scenario |
| BASE-48 quoted read-back | pass (minor finding 2) | RESULT lines match run 053640; one claim imprecise |
| ime-core rules 1-3 (B2/B3) | pass | serial per connection; signals before reply; set_caps output emitted to its context first (SEC-13) |
| D22(c) | pass | sleep only in the connection's task, IME lock not held |
| D35 | pass | caps mask + re-apply on ClientCommitPreedit and on panel claim + emit guard; test `gnome_shell_never_gets_a_delete_surrounding_text` |
| SEC-1 | pass | no logging added; RESULT SEC-1 PASS 0 hits |
| SEC-12 | pass | password path untouched; `caps.password` still wins in `Edit::of`; AC-7 PASS (052836) |
| D2 / SEC-29 | pass | site server bound to 127.0.0.1, inherits VRT_E2E_TAG (stopped by cleanup); proxy bypass only for `.test` hosts; `MAP * ~NOTFOUND` kept |
| BASE-15 / COST-13 | pass | no pkill/killall; scratch in qa-artifacts/FR-8 |
