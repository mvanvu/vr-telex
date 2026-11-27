# Review FR-7 (code + security)

Verdict: **CHANGES_REQUESTED** (1 major: one changed behaviour has no test; 1 minor). There is no correctness or security defect in the code itself.

## Files read
- crates/ime-core/src/ime.rs: read (diff plus process_key, flush, set_caps/take_pending, focus_out/reset/destroy_context, recover)
- crates/ime-core/src/shared.rs: read (diff plus lock/poison recovery, call)
- crates/ime-core/src/action.rs, lib.rs: read (unchanged. Action zeroizes on drop, frontend rules 1-7)
- crates/ime-core/tests/enabled.rs (untracked): read
- crates/fe-ibus/src/ibus.rs: read (diff)
- crates/fe-ibus/src/session.rs: read (diff plus Drop, is_panel, panel_call, register_properties, context_call, apply_caps, emit)
- crates/fe-ibus/tests/protocol.rs, tests/security.rs: read (diff)
- tests/e2e/run.sh, lib.sh, e2e.py, stub_ime.py: read (diff, plus run.sh seeding, start_ime, ensure_vi)
- qa-artifacts/FR-7/gs/ibusManager.js (_engineChanged, _setEngine, setEngine), keyboard.js (594-630, 515-540, 691-712): read
- qa-artifacts/FR-7/after3-*.log, probe/probe3-oldbin.log: result lines read

## How the checks came out
- **B2/B3, delivered exactly once to the right context.** `set_enabled(false)` flushes each context's word into that context's own `pending`. `pending` is moved out (`mem::take`) by the next process_key (ahead of the raw key), focus_out, reset, set_caps, take_pending or destroy_context. So every word is delivered once, to the context it was typed in (SEC-13). fe-ibus sends the panel connection's words before its reply (protocol test `an_xkb_source_switches_...`: `[Commit viêt, hide]`). Words of other connections and of fe-fcitx/fe-xim lead their next call (`a_word_of_another_frontend_is_kept_across_the_switch`). A second switch-off is a no-op. Only lock order panel→ime is used, so there is no deadlock. In the `if self.is_panel()` condition, the guard is dropped before `set_enabled` runs.
- **Closed app / SEC-4.** Session::drop calls destroy_context for each context. Its pending `Action`s are dropped and zeroized by `Action::drop`. A word kept in `pending` stays in memory exactly as long as it did in the composer before. That is no regression.
- **Tap detector, saved mode, poison.** The disabled check comes before classify, so Ctrl+Shift is not seen while off. Taps are reset on both edges (`a_tap_that_spans_the_switch_does_not_toggle`). The mode is untouched and no ModeWatch event is sent. `recover()` leaves `enabled` alone. `overflowed` is cleared by flush.
- **SetGlobalEngine.** `is_xkb_engine`: `xkb:` prefix, non-empty, ≤64 bytes, `[A-Za-z0-9:_+.-]`. The shell only ever sends `xkb:us::eng` for any xkb source (keyboard.js:529-533). The name is echoed only to the caller (unicast signal). Non-panel xkb → AccessDenied (SEC-10, tested). Non-panel `vr-talex` does not switch on (tested). Panel Drop re-enables (tested). ReleaseName re-enables, but this has no test (finding 1).
- **Signal order.** `vr-talex`: reply, then GlobalEngineChanged, then RegisterProperties. ibusManager `_engineChanged` sets `_currentEngineName` and arms the one-shot `register-properties` handler, so the props are filed under `vr-talex` (keyboard.js:691). While off, a FocusIn's RegisterProperties is filed under `xkb:us::eng`, which `_ibusPropertiesRegistered` ignores. The e2e confirms `source-symbol=vi` while off and `vr-talex|VI` after switching back.
- **D32.** `indicator_symbol` gives vi/en for both the engine desc symbol and InputMode. The state file still writes `Mode::symbol()` VI/EN (state.rs:99).
- **Longname.** keyboard.js:618-624 builds `${IBus.get_language_name("vi")} (${longname})` with an empty textdomain, which reads "Vietnamese (Telex)".
- **Harness honesty.** st4/st5 use IME_STATE, which includes `_currentSource.id`, so `us|EN` and `vr-talex|EN` are told apart. The terminal golden (`j aa` raw) proves the engine is off. With the old binary, the IME stayed on: `aa` would have become `â`, and the check would FAIL. Finding 2 covers the remaining gap.
- **Pre-existing word loss.** probe3-oldbin.log shows source-symbol `VI` (uppercase, i.e. the master binary) and engine `vr-talex` throughout, so the shell never switched engines. It still lost the words (`[j x ]` against `[viêtj đx ]`). The loss is the FocusOut skip-commit in `emit` (Cause::FocusOut with client_commit), which is unchanged here. It is confirmed pre-existing and filed as FR-10.

## Findings

[major] crates/fe-ibus/src/session.rs:466: ReleaseName switching the IME back on has no test
Scenario: someone later removes or moves the `set_enabled(true)` on the ReleaseName path. The panel, with an xkb source current, releases the name and stays connected. No client can switch the IME on any more, and Vietnamese stays off for every app until the daemon restarts. No test fails. This is a changed behaviour with no test, and it guards the "never stuck off" property that the Drop path test covers only for disconnect.
Fix: in protocol.rs, add a test: panel RequestName, then SetGlobalEngine("xkb:us::eng") (assert off), then ReleaseName (assert 3 = released), then assert `bus.ime.enabled()`. Also assert that a non-owner's ReleaseName leaves the IME off.

[minor] tests/e2e/run.sh:339-357: indicator checks read only the label, and the shell's engine is not asserted
Scenario: the scenario seeds `('xkb','vn')`, whose label "vi" upper-cases to "VI", the same text as vr-talex in VI mode. ind1/ind2 and ensure_vi (run.sh:124) cannot tell the two sources apart. `$off` is printed but the PASS condition checks only `source-symbol=vi`, not `engine=xkb:us::eng`. Today the terminal golden catches a wrong source, but the label checks themselves can pass on the wrong one.
Fix: read `$IME_STATE` for ind1/ind2 and expect `vr-talex|EN` and `vr-talex|VI`. Make the off check match `*engine=xkb:us::eng*source-symbol=vi`.

Not a finding: GetGlobalEngine and the context's GetEngine still answer `vr-talex` while off. The shell reads it only on connect (ibusManager.js:227). A reconnect implies the old panel's Drop, which switches the IME on again, so the answer is true whenever it is read.

## Rule check FR-7
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 | pass | fe-ibus plus ime-core (enabled flag, required by D33 "off for every frontend") plus e2e harness |
| BASE-3 | pass | notes round 2: enabled.rs did not compile and protocol 3× InvalidArgs (red), then green; round 1 desc tests red then green |
| BASE-15 | pass | no pkill/killall in the diff; the e2e stops its own `$IME_PID` |
| BASE-19 | pass | 04_dev_FR-7.md with `## Rule compliance` |
| BASE-37 | pass | probe2 before (converts under "en") / after3-probe2 (raw under "en") |
| BASE-48 | pass | states quoted from IME_STATE/SHELL_IME_JS read-backs and terminal file content |
| SEC-4 | pass | pending is held as zeroizing `Action`s; destroyed with the session |
| SEC-9 | pass | commits emitted only for this connection's contexts; GlobalEngineChanged unicast to the caller |
| SEC-10 | pass | xkb from non-panel → AccessDenied; enabling only by the panel; tests only_the_panel_switches_the_ime_off, security.rs |
| SEC-12 | pass | password contexts compose nothing, so there is nothing to flush; off passes every key |
| SEC-13 | pass | each word goes to its own context's pending (ime.rs set_enabled) |
| SEC-15 | pass | engine name: deserialize error → InvalidArgs; charset/length bounded; no indexing on wire data |
| SEC-16 | pass | set_enabled is O(contexts), bounded by the context caps; name ≤64 bytes |

## Re-check fix round 1

Verdict: **APPROVED**

Files read: crates/fe-ibus/tests/protocol.rs (diff), tests/e2e/run.sh (diff), 04_dev_FR-7.md "Fix round 1", qa-artifacts/FR-7/fix1-{ibus,fcitx}.log (result lines). Product code is unchanged.

- Finding 1 (major): **fixed**. `the_ime_is_on_again_when_the_panel_releases_its_name` covers the non-owner ReleaseName, which returns 3 (NAME_NOT_OWNER) and leaves the IME off, and the owner's ReleaseName, which returns 1 (NAME_RELEASED) and turns the IME on so that "dd" composes and commits "đ". The test's reply codes match session.rs:54-56. The "expect reply 3" in my fix text above was wrong. The notes record a mutation check: with `set_enabled(true)` removed, the test fails.
- Finding 2 (minor): **fixed**. ind1/ind2 now read `$IME_STATE` and must equal `vr-talex|EN` and `vr-talex|VI`. The off check requires `engine=xkb:us::eng` before `source-symbol=vi`. fix1 logs: AC-4:indicator PASS on both routes, with `[vr-talex|EN, vr-talex|VI]` and `engine=xkb:us::eng`. `ensure_vi` (run.sh:124) still reads only the label. Its result is ignored, and the source-aware checks that follow now catch a wrong source, so this is not a finding.
- Nothing new was introduced.
