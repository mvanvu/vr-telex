# T10b notes: golden regeneration for D18

Tools available: Bash, Read, Edit, Write, Skill, ToolSearch, SubagentHandback (+ deferred MCP).

## Progress
- Read gen.py, README, decisions D13-D18. Did not read crates/telex-core/src.
- Added late_hat_cases / late_d_cases, new sections, D18-aware English oracle, english_now_vietnamese section.
- Regenerated TSV, ran format check, updated README.

## Files changed
- tools/golden-gen/gen.py
- crates/telex-core/tests/golden/telex_golden.tsv (regenerated)
- crates/telex-core/tests/golden/README.md

## Counts per section (total 34431, was 31552)
Sections 1-8 unchanged (15585 / 7871 / 3913 / 1392 / 852 / 402 / 1029 / 32).
New: hat after final 750 (+100 cap, +44 CAPS); tone then hat 640 (+75, +39); tone, hat, final 587 (+76, +26);
later d after final 249 (+50, +23); tone then d 142 (+56, +16); hand-written D18 14;
passthrough 464 rows (309 distinct raw words, was 476 rows / 316); english_now_vietnamese 4.

## Changed lines vs previous TSV
- Existing Vietnamese sections 1-8: no line removed or changed (diff shows only 12 removed lines, all English).
  Checked every old key with a non-adjacent repeated a/e/o/d: only the `..oeo` family (`boeo`, `boeof`, ...):
  hat on the first `o` gives an invalid syllable, so expected values stay as before.
- Removed from passthrough (12 lines): await, array, queue, safari, photo, freeze, reset, Array, Queue, AWAIT, FREEZE, RESET.
- Moved to english_now_vietnamese: photo>phôt, reset>rết, Photo>Phôt, Reset>Rết.
- Dropped (ambiguous / not a generated case): await, array, queue, safari, freeze (+ cap variants).

## Interpretations (for T10a / leader)
- Free-order cases are generated only for syllables with exactly one â/ê/ô; no case combines late hat and late d, or horn (ơ/ư/ă) keys.
- Open syllable with the hat vowel last in the nucleus (`bê`): only with a tone key between (`bese` -> `bế`), since `bee` is the ordinary key.
- Hat vowel not last in the nucleus with no final: `toio` -> `tôi` (key after the whole nucleus).
- Tone-before-hat-before-final (`vieset`) listed for syllables with a final only.

## Commands
- `python3 -I tools/golden-gen/gen.py` -> 34431 total cases, english kept 309.
- `python3 -I .../qa-artifacts/T3/check.py .../telex_golden.tsv` -> `cases 34431 problems 0 []` (exit 0).

## Rule compliance
| Rule | Result | Evidence |
|---|---|---|
| BASE-1 | pass | only gen.py and golden/** touched |
| BASE-7/24 | pass | no git add or commit |
| BASE-11 | pass | never read crates/telex-core/src or tests/rules.rs |
| BASE-19 | pass | notes from the start |
| COST-8/13 | pass | Edit tool for edits |
| BASE-15 | pass | no process killed, nothing started |
| D18 | pass | new sections, examples vieset/tiengse/vietej/duowngd/dinhd present |
| D13/D14/D15/D16 | pass | rules only, no dictionary; missing tone valid; stop-final tones s/j only |
| AC-1 | pass | format check 0 problems, 34431 cases |

Counts: pass 9, n-a 0. Nothing left running.

## Quick pass 1
- Fixed D18 example error: `duowngd` -> `đương` (no tone key), `Duowngd` -> `Đương`; added `duowngfd` -> `đường`, `Duowngfd` -> `Đường`. Other hand-written D18 rows checked (tone present only where expected value has one): ok. Regenerated: 34433 cases, check.py `problems 0`. README example fixed.
