# Review M1: APPROVED

No blocker/major findings.

## Files read
crates/telex-core/src/lib.rs (read, both diffs and the callers: push, pop, finish, ends_in_tone_undo, clear, resync_raw, continue_shown)

## Notes
- minor (no user-visible effect): in `pop()` Mode::Undone with `undo_inserted` true, raw is reset to text, so `ends_in_tone_undo` can be true when the last text char is a tone letter (`lists` + BackSpace -> raw `lis`). Then `restore` (raw) equals the shown text, and the lang is En in both paths, so the committed text is identical.
- `undo_inserted` is true only after an inserted Literal. Any later letter leaves Undone (Raw), so `finish` takes the Mode != Undone-guarded path (`ends_in_tone_undo` requires Undone). Non-letter keys put a non-tone char last in raw. `w` undo: last raw key is `w`/`W`, not a tone key. A non-inserted Literal and every tone/mark apply reset it to false; `clear()` resets it; `new()` false; BackSpace back to Viet leaves it stale but Undone can only be re-entered through Literal (sets it) or a non-letter (raw ends non-letter).
- Hunk 1/2: both parents kept (`at` computed before the loop, `literal` case kept, `Step::Literal(literal, at)`); the other Step::Literal callers use the two-field shape.

## Rule check M1
| Rule | Status | Evidence |
|---|---|---|
| BASE-11 | pass | resolution touches only crates/telex-core/src/lib.rs (rest of the index is the merged remote side) |
| 311dbe0 behaviour (tone undo at tone position) | pass | `at` = tone_at / horn_at.filter, insert path kept |
| 32bb402 / a8f098e / 5b0604a (D37/D39/D40, EN-DETECT) | pass | case-kept literal, `finish` En exception kept, composition via undo_inserted |
| AC-1 (old run) | pass | dev reports telex-core (incl. golden, finish) and ime-core green; not re-run by reviewer |

REVIEW_PASS
