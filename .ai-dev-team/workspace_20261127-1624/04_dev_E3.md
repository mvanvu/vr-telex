# E3 ime-core: per-context last language, finish at every word end, per-edit-mode commit, resets + tests

## Progress
- read: brief, plan "ime-core (E3)", E2 notes, decisions D1–D10, ime.rs, tests/pipeline.rs, tests/common, fe-ibus emit()
- red: tests/word_end.rs 13 tests, 9 fail for the right reason (shown text committed: `úe`, `the bét`, Commit len 3 vs 4); 4 pass (Vietnamese stays, EN/password, surrounding equal, Debug)
- green: src/ime.rs `last`, `flush` via finish per edit mode, `flush_and_forget`, resets; ime-core 64/64 green after 2 expectation updates
- related: fe-ibus / fe-fcitx — 2 test expectations change by AC-1 (incomplete syllables) in files outside my scope; edit denied → BLOCKED for the scope extension
- guard: fmt clean, clippy clean
- decision D11 appended

## Files changed
- crates/ime-core/src/ime.rs — `Context.last: Lang`; `flush` commits `composer.finish(self.last)` per edit mode and stores `finished.lang`; new `flush_and_forget` (flush, then `last = Unknown`); `focus_in` resets `last`; `focus_out`, `reset`, mode toggle, `set_enabled(false)` use `flush_and_forget`; overflow flush sets `last = En`; `recover` resets `last` of the broken context.
- crates/ime-core/tests/word_end.rs (new) — 13 tests (below).
- crates/ime-core/tests/pipeline.rs — one changed expectation (overflow test).
- crates/ime-core/tests/security.rs — one changed expectation (password test).

## Design
- `last` is a `telex_core::Lang` (Copy enum); no text kept beyond the composer (SEC-2/SEC-4).
- `flush` (the single word-end path): `shown = composer.text()`, `finished = composer.finish(last)`; then
  - Preedit → `HidePreedit` + `Commit(finished.text)` (unchanged shape; fe-ibus `emit()` reorders as before — address-field order untouched, fe-ibus address.rs 12/12 green);
  - Hold → `Commit(finished.text)`;
  - Surrounding → if `finished.text != shown`: `DeleteSurrounding{offset:-n, chars:n}` (n = shown chars) + `Commit(finished.text)`; nothing when equal;
  - Off → nothing (composer is always empty there).
  Then `last = finished.lang`, `composer.clear()`. Boundary key still passes after the actions (unchanged).
- Copies: `finished.text.to_owned()` goes straight into `Action::Commit`, which zeroizes on drop; `finish` allocates nothing; no other temporary (SEC-4).
- AC-6: `finish` is only called inside `flush` (word end); `compose` (per key) unchanged. latency.rs p99 test green.

## Reset ordering
The word ending at an event is finished with the context's current `last`, THEN `last` becomes Unknown:
| Event | flush uses | `last` after |
|---|---|---|
| boundary key, COMMAND chord, EN/password flush | `last` | finished.lang |
| set_caps (edit mode changes, SEC-13) | `last` | finished.lang |
| focus_out, reset, mode toggle, set_enabled(false) | `last` | Unknown |
| focus_in, create_context | (no flush) | Unknown |
| overflow (MAX_WORD_KEYS) | `last` | En (plan) |
| recover: broken context / other contexts | (cleared) / `last` | Unknown / finished.lang |
| destroy_context | `last` | (context gone) |
EN mode keys pass through, the composer stays empty, so no word is decided there.

## Tests added (crates/ime-core/tests/word_end.rs)
english_after_a_plain_english_word_is_restored_in_every_edit_mode (`the best ` → `the best `, `use the best list `), vietnamese_words_stay_in_every_edit_mode (`raats bets ` → `rất bét `, `tiếng Việt`), an_incomplete_syllable_commits_its_keys (`use ` → `use `), an_overlap_word_first_in_a_field_is_vietnamese (data: `her` ∈ en.txt, `hẻ` ∈ vi.txt → first in field `hẻ `, after `the` → `her `), the_boundary_key_emits_the_finished_text_per_edit_mode (exact actions per mode, incl. Surrounding `DeleteSurrounding(3)` + `Commit("best")`), surrounding_mode_rewrites_nothing_when_the_text_stays, every_word_end_event_commits_the_finished_text (focus_out, reset, destroy, set_enabled(false), set_caps, mode toggle, Ctrl+a — each mode), the_language_starts_over_at_focus_reset_mode_and_enable_changes, the_word_ending_at_a_reset_still_uses_the_language_of_its_context, contexts_keep_their_own_language, english_mode_and_password_fields_pass_every_key, an_overlong_run_of_letters_counts_as_english, debug_prints_no_word.

## Changed expectations
- crates/ime-core/tests/pipeline.rs `an_overlong_word_is_committed_and_the_rest_passes_through`: after the overlong run, ` as ` gave `á`; now `as` — AC-3 (overlap `as`/`á` after an English run; plan: overflow → En). Extended with `dduwowcj` → `được` to keep the "composing resumes" intent.
- crates/ime-core/tests/security.rs `turning_into_a_password_field_commits_the_word_first`: ` aas ` → `ấ` is now `aas` — AC-1 (`â` nucleus without final is incomplete). Word changed to ` aans ` → `ấn` to keep the intent (composing resumes after the password field).
- NOT APPLIED (outside crates/ime-core/**, edit denied): see Blocker.

## Round 2 — frontend test data (scope widened by the leader)
Applied: crates/fe-fcitx/tests/bus.rs:892-893 `ddaau ` / `đâu `; crates/fe-ibus/tests/protocol.rs:505 `dduwcs`, :512 `đức`. No frontend source change. D12 (preedit reset/focus-out keeps the shown text, known limit) documented on `Ime::reset` in crates/ime-core/src/ime.rs.
Rerun: `cargo test -p fe-ibus -p fe-fcitx --locked` → fe-fcitx unittests 10 ok, bus.rs 15 ok; fe-ibus unittests 25 ok, address.rs 12 ok, latency.rs 1 ok, protocol.rs 22 ok, security.rs 15 ok. `cargo test -p ime-core --locked` → 8+1+13+6+4+8+11+13 ok. Guard: `cargo fmt --check` clean; clippy `Finished dev profile ... in 5.49s`, no warnings.

### Round 1 failure (before the edits)
`cargo test -p fe-ibus -p fe-fcitx --locked --no-fail-fast`:
```
fe-fcitx tests/bus.rs  FAILED 14 passed; 1 failed — a_client_leaving_does_not_disturb_the_others (bus.rs:893) left: "ddaa " right: "đâ "
fe-ibus  tests/protocol.rs FAILED 21 passed; 1 failed — several_clients_type_at_the_same_time_without_mixing (protocol.rs:512) left: Commit("dduowf") right: Commit("đườ")
fe-fcitx unittests 10 ok; fe-ibus unittests 25 ok, address.rs 12 ok, latency.rs 1 ok, security.rs 15 ok
```
Both inputs are incomplete syllables (`đâ`, `đườ`), so AC-1 now commits the keys: the new output is correct, the test data must change. Proposed edits (test data only, no frontend source):
- crates/fe-fcitx/tests/bus.rs:892-893 `c.type_pipelined("ddaa ")` / `"đâ "` → `"ddaau "` / `"đâu "` (`đâu` ∈ vi.txt).
- crates/fe-ibus/tests/protocol.rs:505 `"dduowf"` → `"dduwcs"` (6 keys, zip length kept) and :512 `"đườ"` → `"đức"` (`đức` ∈ vi.txt).

## Out-of-scope noticed
- fe-ibus `emit()` with `Cause::Reset` (and FocusOut with client_commit) skips the IME's Commit when a preedit is shown, because the client commits the shown preedit itself (PREEDIT_COMMIT). So in preedit mode a reset/focus-out commits the shown text (`bét`), not the finished text (`best`). ime-core emits the finished text (tested); making the frontend honour it (e.g. update the preedit to the finished text before the reset reaches the client, which is not possible after the fact, or not using commit-on-reset) is a frontend decision for the leader. Boundary keys are unaffected.

## Commands run (trimmed)
`cargo test -p ime-core --locked`
```
unittests 0; enabled.rs 8 ok; latency.rs 1 ok; pipeline.rs 13 ok; security.rs 6 ok; shared.rs 4 ok; state_store.rs 8 ok; toggle.rs 11 ok; word_end.rs 13 ok; doc-tests 0
```
Red (before ime.rs change): `cargo test -p ime-core --locked --test word_end` → `FAILED. 4 passed; 9 failed` (e.g. left "úe " right "use "; left "the bét " right "the best ").
Guard: `cargo fmt --check` → no output; `cargo clippy --workspace --all-targets --locked -- -D warnings` → `Finished dev profile ... in 11.76s`, no warnings.
rustfmt run only on ime.rs, word_end.rs, pipeline.rs, security.rs.

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| word-end decision | telex-core `Composer::finish` (E2) | reused |
| surrounding delete+commit | ime.rs `compose` diff | same action shape; whole word replaced per plan |
| test client | tests/common `App`, `tap_ctrl_shift` | reused |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| AC-1 | pass | word_end.rs `an_incomplete_syllable_commits_its_keys`; security.rs `ấn` change |
| AC-2 | pass | word_end.rs `english_after_a_plain_english_word_is_restored_in_every_edit_mode` |
| AC-3 | pass | word_end.rs `an_overlap_word_first_in_a_field_is_vietnamese`, `vietnamese_words_stay_in_every_edit_mode`, `contexts_keep_their_own_language` |
| AC-4 | pass | ime.rs `Context.last`, `flush` stores `finished.lang`; reset table above; `the_language_starts_over_at_focus_reset_mode_and_enable_changes`, `the_word_ending_at_a_reset_still_uses_the_language_of_its_context` |
| AC-5 | pass | `the_boundary_key_emits_the_finished_text_per_edit_mode`, `every_word_end_event_commits_the_finished_text`, `surrounding_mode_rewrites_nothing_when_the_text_stays`; fe-ibus address.rs 12/12 |
| AC-6 | pass | finish only in `flush`; `compose` unchanged; latency.rs ok (ime-core and fe-ibus) |
| AC-8 | pass | ime-core 64/64; fe-ibus 25+12+1+22+15, fe-fcitx 10+15 all ok after the test-data edits (round 2); changed expectations listed above |
| SEC-2 | pass | `Ime` Debug unchanged (counts); `debug_prints_no_word`; security.rs `debug_output_never_shows_text_or_keys` |
| SEC-4 | pass | no temporary copies; commit text owned by `Action` (zeroize on drop) |
| SEC-13 | pass | set_caps flush unchanged; `every_word_end_event_commits_the_finished_text` (set_caps), pipeline.rs `a_capability_change_commits_the_word_under_the_old_capabilities` |
| B3 | pass | every flush emits the word; focus_out/reset/destroy/disable/toggle tested |
| BASE-10 / COST | pass | only related suites + guard once |
| BASE-14/15 | pass | all foreground, nothing started in background |
| BASE-16 | pass | Reuse table |
| BASE-19 | pass | progress lines |
| BASE-38 | pass | rustfmt on the 4 changed files only |
| Scope | pass | only crates/ime-core/**; nothing staged or committed |

Nothing left running.


DONE E3

## Fix round 1

### Progress
- read: 05_review_E3.md, D12/D13, 05_qc_report.md `## QC E3 / sign-off`, qa-artifacts/E3 (new2, smoke2, flow.sh), tests/e2e/lib.sh `wait_win`, spike notes 03_spike.md (IBus calls), fe-ibus Reset/FocusOut path
- red: word_end.rs `every_word_end_event_commits_the_finished_text` changed to the D13 expectation + new `surrounding_mode_never_rewrites_after_a_click_or_focus_change` → 2 failed (`left: [DeleteSurrounding(3), Commit(<redacted len=4>)] right: []`, `assertion failed: ime.reset(id).is_empty()`)
- green: ime.rs `end_word(out, at_cursor)`; ime-core 72 ok; fe 100 ok; guard clean
- D11 overflow note added

### 1) Review blocker (D13) — fixed
- crates/ime-core/src/ime.rs: `flush` (key-driven, `at_cursor = true`) and new `flush_away` (`at_cursor = false`) both call `end_word`; the Surrounding arm rewrites only when `at_cursor && finished.text != shown`. `flush_away_and_forget` replaces `flush_and_forget`.
- Call sites: focus_out, reset, set_enabled(false) → `flush_away_and_forget`; destroy_context, recover (other contexts) → `flush_away`; boundary key, COMMAND chord, EN/password flush, overflow, set_caps → `flush`; Ctrl+Shift tap → `flush` then `last = Unknown`. Preedit and Hold are unchanged by `at_cursor` (D12 is the frontend's preedit case). `last` still takes `finished.lang` on an away flush (then forgotten where the event says so).
- Tests: `every_word_end_event_commits_the_finished_text` now expects `[]` in SURROUNDING for focus_out / reset / destroy / disable, and Delete+Commit for set_caps / toggle / Ctrl+a; new `surrounding_mode_never_rewrites_after_a_click_or_focus_change` (`hello world the bét` + reset/disable/focus-out/destroy → nothing sent).
- D11 now notes that the overflow flush commits `finish` output (raw keys for a changed 32-key run, AC-1).

### 2) QC term flake — root cause (outside ime-core, no code change)
Evidence:
- Run new2 (qa-artifacts/E3/new2/run-*/out/results.txt): only the FIRST two term lines failed (`has ` raw, `the bét `); lines 3–7 and all Chrome/omnibox cases passed. Term cases are typed right after `gnome-terminal` opens (flow.sh:318-322: `wait_win` = window frame + `activate()` + 1 s, tests/e2e/lib.sh:108-116); nothing waits for the terminal's text-input / IBus FocusIn.
- `has ` raw cannot come from ime-core with the context as it was: nothing had been typed in the session before (term is the first app, results.txt shows no corpus before the cases), so `last` was Unknown (fresh context, and focus_in/toggle reset it), and `finish(Unknown)` on `has` gives `há` (overlap, D1). The only ways to get raw `has`: the keys bypassed the IME (text-input not yet enabled for the new window), or a Reset/FocusIn split the word (`ha` committed, `s` a new raw word).
- `the bét` likewise needs the IME to see `best` with `last != En`: a Reset/FocusIn between `the ` and `best`, or `the` (partly) bypassing the IME.
- Replay test `a_reset_mid_word_or_between_words_replays_the_terminal_flake` (word_end.rs): `ha` + Reset + `s ` + `the ` + Reset + `best ` → exactly `has the bét ` — the observed output, produced by the IME following its rules (a reset ends the word, D12 preedit; a new focus/reset starts Unknown, AC-4).
- Against the hypothesis "the shell sends Reset between words routinely": then `the best` would fail every time in term; QC's `rep` run had 25/25 `the best ` and 25/25 `has ` in term, term1..3 7/7 each (90 term PASS rows in total). The extra calls only happen around the window opening.
- Pre-existing part: line 1 (`has` split or bypassed) gives the same raw `has` with the installed 32bb402 binary (no E3 code is involved in a bypass or a mid-word reset). Line 2 only differs because before E3 `best` was always `bét`.
- Conclusion: harness timing — keys injected before the terminal's input-method focus has settled (late FocusIn/Reset from GNOME Shell after `activate()`). Not an ime-core defect; ime-core behaves as AC-4 / D12 specify. Suggested harness fix (not mine, tests/e2e is out of scope): type and discard a warm-up line, or wait for the engine's FocusIn, before the first case. No e2e launch made: one more run cannot show an intermittent window-open event, and the daemon has no call tracing (daemon.stderr empty).

### Space anomaly (smoke2) — not related to E3
- diff-term-1.txt: line 2, the spaces after `ghẽn`, `biệng`, `tìn` appear after `mưc` (`lost 3, extra 3`, same text otherwise).
- Keys (corpus.json line 2): `ghexn bieejng tifn muwc`, all VI mode, between two EN-mode tokens (toggles around them). For these words E3 emits exactly the same actions as before (HidePreedit + Commit of the same text: keys not in en.txt → `finish` returns the shown text, and `mưc` stayed as shown in the output); the spaces are unhandled keys the shell forwards itself. A reorder of forwarded keys against commits is outside ime-core's output, which did not change for this line.
- Rate: new binary 1 in 6 term corpus runs vs baseline 0 in 5 — not a significant difference (QC ran under load with the reviewer in parallel). Classified as frontend/shell timing, not E3.

### Commands (fix round 1, trimmed)
`cargo test -p ime-core --locked --test word_end` (red) → `FAILED. 13 passed; 2 failed`.
`cargo test -p ime-core --locked` → enabled 8, latency 1, pipeline 13, security 6, shared 4, state_store 8, toggle 11, word_end 15 — all ok.
`cargo test -p fe-ibus -p fe-fcitx --locked` → fe-fcitx 10 + bus 15; fe-ibus 25 + address 12 + latency 1 + protocol 22 + security 15 — all ok.
Guard: `cargo fmt --check` clean; `cargo clippy --workspace --all-targets --locked -- -D warnings` → `Finished dev profile`, no warnings. rustfmt only on ime.rs and word_end.rs.

### Rule compliance (fix round 1)
| Rule | Status | Evidence |
|---|---|---|
| AC-4 | pass | resets unchanged; `the_language_starts_over_*`; replay test |
| AC-5 | pass | `every_word_end_event_commits_the_finished_text` (D13 rows), `surrounding_mode_never_rewrites_after_a_click_or_focus_change`, `the_boundary_key_emits_the_finished_text_per_edit_mode` |
| AC-6 | pass | `compose` untouched; latency.rs ok |
| AC-8 | pass | ime-core 72, fe-ibus 75, fe-fcitx 25, all ok |
| SEC-2 | pass | no new output; `debug_prints_no_word` |
| SEC-4 | pass | no new copies (`end_word` only borrows) |
| SEC-13 | pass | set_caps still `flush` under the old caps (rewrites in Surrounding) |
| B3 | pass | Preedit/Hold still commit on every away event; Surrounding keeps the shown word in the client (nothing dropped) |
| D13 | pass | tests above |
| BASE-11 | pass | no checkout/stash/restore; red shown by tests |
| BASE-10 / COST | pass | related suites + guard once, no e2e launch |
| BASE-14/15 | pass | all foreground, nothing started |
| BASE-19 | pass | progress lines above |
| BASE-38 | pass | rustfmt on the 2 changed files only |
| Scope | pass | crates/ime-core/** only this round; nothing staged or committed |

Nothing left running.

DONE E3 (fix round 1)
