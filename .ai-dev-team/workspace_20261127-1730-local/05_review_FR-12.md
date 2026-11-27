# Review FR-12 (code) - APPROVED

Tools available: Read, Bash, Write, Skill, SendMessage, SubagentHandback.

## Files read
- crates/telex-core/src/lib.rs (diff + push/pop/apply/resync_raw/clear/enter_passthrough): read
- crates/telex-core/tests/rules.rs (diff): read
- .ai-dev-team/* : skipped - team files

## Findings
No blocker/major. One minor note.
- [minor] lib.rs:218 / :112 - `undo_inserted` is only reset in `clear()`, not in `resync_raw()`/when mode returns to Viet (e.g. `tuwrw` + BackSpace -> Viet "tủ", flag stays true). Scenario: a later undo that does not insert (aa/dd) followed by BackSpace would rewrite `raw` from `text` instead of the typed keys. I could not reproduce a visible wrong result (raw equals text in all shapes tried); harmless today. Fix: reset `undo_inserted = false` in the Undone->Viet branch of pop() and in resync_raw().

## Verification
`cargo test -p telex-core --locked`: 24 + 1 golden passed (ran once). Scratch probe (qa-artifacts/FR-12) of ~40 key sequences: lists->list, LISTS->LIST, lisst stays raw (D17), listsa raw (D17), lists<a->lisa, lists<<a->lia, ass<aa->aa, aass->âs, ddd->dd, DDD->DD, vieetss<->viêt, hoasng<s->hoans (raw resynced after BackSpace, consistent), tuws->tứ, tuwss->tưs. No regressions in aa/dd/w/tone/upper-case undo; offsets stay correct because tone_at/horn_at are letter counts (1 char per letter, NFC) and resync_raw re-bases them after BackSpace; out-of-range index falls back to push.

## Rule check FR-12
| Rule | Status | Evidence |
|---|---|---|
| AC-1 | pass | new tests + golden green (rerun) |
| BASE-37 | pass | `lists` red (got "lits") per notes, green on rerun |
| SEC-2 | pass | no Debug/Display added |
| SEC-4 | pass | raw rewrite uses wipe_string; clear() resets new fields |
| SEC-27 | pass | forbid(unsafe_code) untouched |

## Re-check (quick pass)
Diff read: `undo_inserted` is now set true/false on every undo in push(), reset in resync_raw() (called by the Undone->Viet branch of pop()) and in clear(). The earlier minor finding is fixed and opens nothing new. `cargo test -p telex-core --locked`: 24 + 1 passed. Verdict: APPROVED.
