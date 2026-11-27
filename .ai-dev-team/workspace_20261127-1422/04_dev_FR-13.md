# FR-13 mark undo by repeat duplicates a letter
- Root cause: `Composer::keeps_raw_after_undo` (crates/telex-core/src/lib.rs) applied the D37 raw restore (vowel, l/r, same key) after any undo, tone or mark. Second cause: undoing a lone upper-case `W` lost its case (`Ww` showed `w`), so `Wwa` could not continue as `Wa`.
- Change: `keeps_raw_after_undo` returns false when the undone key is a mark key (a e o d w), so the word continues from the shown text; tone keys (s f r x j) keep D37. In `Composer::horn` the literal key left by a lone-`W` undo takes the case of the removed letter.
- Tests: crates/telex-core/tests/rules.rs: new `letters_after_a_mark_undo_continue_the_shown_text` (14 rows incl. all D39 rows + FR-12 rows); pop table gained `wwa<`->`w`, `ddda<`->`dd` (both pass). Red step: leader probe on master showed the wrong outputs; I applied test and fix together (the test failed once on `Wwa` before the case fix).
- No golden conflicts; golden tsv unchanged.
- `cargo test -p telex-core --locked`: rules 23 passed 0 failed, golden 1 passed.
- Guard `cargo fmt --check && cargo clippy --workspace --all-targets --locked -- -D warnings`: clean (Finished).
- No new buffers; nothing running.

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| D39 | pass | test `letters_after_a_mark_undo_continue_the_shown_text`, `wwa<`/`ddda<` rows in `backspace_after_undo_removes_last_shown_char` |
| D37 | pass | `more_letters_after_undo_restore_raw`, `consonant_after_undo_continues_the_shown_text` unchanged and green |
| AC-1 | pass | whole telex-core suite incl. golden green |
| BASE / COST | pass | related tests only, guard once |
| SEC-2 / SEC-4 | pass | no logging added, no new temp buffers |

## Quick pass 1
- Red: added `www`->`www`, `WWW`, `aaaa`, `dddd`, `WWa`, `tuwswa`, `ddd<d`, `www<`; failed first (`www` got `ww`, `WWW` got `WW`, `aaaa` got `aaa`, `dddd` got `ddd`, `www<` got `w`).
- Fix: in `keeps_raw_after_undo`, after a mark undo only the same key restores raw; everything else continues the shown text.
- Note: `aaaa`->`aaaa` and `dddd`->`dddd` (rows given by the leader) need the same-key restore for every mark key, not just `w`. D40's claim that D39 gives the same text for them is wrong: D39 alone gives `aaa`/`ddd`. The code follows the listed rows.
- BackSpace after `www`: `www<` -> `ww` (raw word, last char removed).
- Tests: rules 23 passed, golden 1 passed. Guard (`cargo fmt --check && cargo clippy --workspace --all-targets --locked -- -D warnings`): clean.

| Rule | Status | Evidence |
|---|---|---|
| D40 | pass | `www`, `WWW`, `www<` rows |
| D39 | pass | `letters_after_a_mark_undo_continue_the_shown_text`, `ddd<d`, `WWa`, `tuwswa` |
| D37 | pass | `more_letters_after_undo_restore_raw` and `consonant_after_undo...` green |
