# M1 Resolve merge conflict in crates/telex-core/src/lib.rs

## Progress
- read both commits (311dbe0, 32bb402) and the two conflict hunks
- resolved both hunks; first test run: finish.rs every_english_list_word_follows_the_rules red (73 mismatches, all "passthrough prev En")
- fixed the composition in ends_in_tone_undo; telex-core and ime-core green; guard clean

- Files changed: crates/telex-core/src/lib.rs (only)
- Tests added: none (existing tests on both sides cover the merged behaviour)

## Hunk resolution
1. Hunk 1 (horn undo setup, ~line 680): kept both. Local `let at = ... self.horn_at.filter(|&p| p <= end)` (311dbe0: put the undone `w` back at its own position, none when a lone-`w` ư is in the nucleus) is computed first, before the loop mutates the letters; remote `let mut literal = ch;` (32bb402: the shown `w` keeps the case of the lone-ư key it came from) follows.
2. Hunk 2 (return, ~line 715): `return Step::Literal(literal, at);` — remote's case-kept key with local's two-field `Step::Literal(char, Option<usize>)` shape. All other `Step::Literal` callers already used the local shape after the auto-merge (tone undo `Some(self.tone_at)`, `dd`/circumflex undo `None`).
3. Composition fix outside the hunks (auto-merged code that no longer composed): remote `finish()` exception (word ending in a tone-key undo, ASCII, keys in the English list, prev En -> commit the raw keys; "the pass") relies on `ends_in_tone_undo()`, which required `text.ends_with(key)`. With local 311dbe0 the undone tone key can be inserted mid-word (`lists` shows `list`), so the text no longer ends in the key and 73 English-list words (`lists`, `costs`, `hosts`, ...) committed the shown text after an English word instead of their keys. Changed the check to `(self.undo_inserted || self.text.ends_with(k))`. `undo_inserted` is true only right after a mid-word Literal (a later push leaves Undone; a pop in Undone resets raw to the text), and for a `w` undo the last raw key is `w`, not a tone key, so nothing else changes.
   - Not a behaviour conflict: local rows test the shown text (`lists` -> text `list`, unchanged); the remote row tests the commit at word end (`lists` + prev En -> `lists`, prev other -> shown text `list`). Both hold together.
- Checked: `clear()` resets `tone_at`, `horn_at`, `undo_inserted`; `resync_raw()` resets them too; remote `keeps_raw_after_undo` / `continue_shown` read `raw` (typed keys), which local insertion leaves untouched.

## Commands (trimmed real output)
`cargo test -p telex-core --locked`
- unittests 7 passed; finish.rs 28 passed; finish_measure.rs 2 passed 1 ignored; golden.rs 1 passed; rules.rs 26 passed; doctests 0. 0 failed.
`cargo test -p ime-core --locked`
- enabled 8, latency 1, pipeline 13, security 6, shared 4, state_store 8, toggle 11, word_end 18 passed; 0 failed.
Guard `cargo fmt --check && cargo clippy --workspace --all-targets --locked -- -D warnings`
```
    Checking telex-core v0.1.0 (/home/rainy/DEV/vr-telex/crates/telex-core)
    Checking ime-core v0.1.0 (...)
    Checking fe-ibus / fe-fcitx / fe-xim / vr-telex v0.1.0
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 3.59s
```
(fmt printed nothing; clippy no warnings.) Conflict markers left: 0.

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| mark the inserted undo in finish() | lib.rs fields | reused local `undo_inserted` |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-24 | pass | no git stage/commit/stash/checkout/restore/reset run |
| BASE-11 | pass | only crates/telex-core/src/lib.rs edited (plus this notes file) |
| BASE-25 | pass | guard run once at the end, output above |
| behaviour of both sides | pass | telex-core + ime-core suites green; no row conflict found |
| COST | pass | only telex-core and ime-core tests run |
| BASE-14/15 | pass | no background tasks or servers started; nothing left running |
