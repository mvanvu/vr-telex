# FR-12 tone-undo duplicate letter (fix, be)
- Progress: read lib.rs -> red (`lists` -> `lits`) -> fix -> related tests -> guard.
- Root cause: undo-by-repeat (`Step::Literal`) always appended the literal key at the END of the word. A tone/horn key typed earlier than later letters (`lis|t`) therefore moved to the end: engine gave `lits` (the app, which diffs against what is on screen after `lít`, showed `lisst`). Expected is the typed order `list`.
- Fix (crates/telex-core/src/lib.rs): `Step::Literal(char, Option<usize>)`; Composer records `tone_at` (letter count when the tone key was applied) and `horn_at` (same for the last `w`). On undo the literal key is inserted at that letter index instead of appended; `undo_inserted` makes BackSpace in Undone mode keep `raw` equal to the shown text (so `lists`, BS, `a` -> `lisa`). resync_raw/clear reset them. Existing undo path reused, no dictionary.
- Files: crates/telex-core/src/lib.rs, crates/telex-core/tests/rules.rs. Golden tsv untouched (all cases pass).
## Cases pinned (tests/rules.rs)
lists->list, LISTS->LIST, tets->tét, tetss->tets, hocjj->hocj, toanxx->toanx, toanff->toanf, vieetss->viêts, ass->as, bass->bas; w: chuwngw->chuwng, tuwrw->tủw, aww->aw; BackSpace after mid-word undo.
Not changed (D17/D28 shapes): `lisst` (undo then more letters keeps raw keys), aa/ee/oo and dd undo (undo key is adjacent/last already). `uwow`+w undo inserts a single w at the last w position (edge, harmless).
## Red / green (BASE-37)
Red (tone insertion disabled): `lists: want "list", got "lits"`, `LISTS: want "LIST", got "LITS"`; test result FAILED.
Green: `cargo test -p telex-core --locked` -> 24 passed (rules) + 1 passed (golden), 0 failed.
## Guard (BASE-25)
`run-heavy.sh bash -c 'cargo fmt --check && cargo clippy --workspace --all-targets --locked -- -D warnings'` -> fmt clean; clippy `Finished dev profile`, no warnings.
## Reuse
| Needed | Looked in | Result |
|---|---|---|
| undo path | lib.rs Step::Literal | extended, no new mechanism |
## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| AC-1 | pass | rules.rs new tests + golden test green |
| BASE-7 | pass | no commits |
| BASE-11 | pass | no checkout/restore/stash/reset used |
| BASE-24 | pass | nothing staged |
| BASE-25 | pass | guard output above |
| BASE-37 | pass | `l i s t s` red then green (engine level) |
| COST | pass | related tests only, guard once |
| SEC-2 | pass | Debug impl untouched (redacted) |
| SEC-4 | pass | new raw rewrite uses wipe_string; buffers cleared in clear() |
| SEC-27 | pass | forbid(unsafe_code) untouched |
Open nits: Raw-branch keys Vec not wiped — untouched. Nothing left running.

## Quick pass
- Finding: `undo_inserted` only reset in `clear()`. Fix in crates/telex-core/src/lib.rs: the flag is now set on every undo (true when the key is inserted, false when appended) and also reset in `resync_raw()`, so it reflects only the latest undo and the Undone->Viet branch of `pop()` (which calls `resync_raw`) clears it.
- Pinning test: none exists. A non-inserting undo after an inserting one needs further letters, which restore raw (Raw mode, flag unused); and an inserted undo cannot return to Viet via BackSpace (shown text never equals the letters render). Reviewer could not produce one either.
- Related tests: `cargo test -p telex-core --locked` 24 + 1 passed. Guard (fmt + clippy -D warnings): clean, `Finished dev profile`. Nothing staged/committed, nothing left running.
