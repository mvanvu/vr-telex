# E2 telex-core: `Lang`, `Composer::finish` (complete-syllable check, English restore, overlap) + tests + AC-7

## Progress
- read: spec, plan, decisions D1–D6, E1 notes, lib.rs, golden.rs, rules.rs, data format
- red: tests/finish.rs fails to compile (no Lang / finish)
- green: src/words.rs (lists + binary search), lib.rs Lang/Finished/finish/is_complete/shown_lang
- related tests green; measurement run; README section; rustfmt on changed files
- decisions D7–D9 appended; guard clean

## Files changed
- crates/telex-core/src/lib.rs — `mod words`, `pub enum Lang`, `pub struct Finished` (redacted Debug), `Composer::finish` (lib.rs:374), `is_complete` (lib.rs:741), `shown_lang` (lib.rs:755). Existing functions untouched; `text()`/`push`/`pop` unchanged.
- crates/telex-core/src/words.rs (new) — `include_str!` of data/en.txt and data/vi.txt, `is_english` / `is_vietnamese`, allocation-free binary search over the sorted file text with on-the-fly case folding; 4 unit tests.
- crates/telex-core/tests/finish.rs (new) — 12 behaviour tests (AC-1..AC-4, SEC-2, every en.txt word against the rules).
- crates/telex-core/tests/finish_measure.rs (new) — AC-7: golden assertion, 25 spec words, English sample (`#[ignore]`, reads /usr/share/dict).
- README.md — "### English words" under Usage (no Vietnamese source named, D5).
- golden.rs, rules.rs, golden tsv, data/**, tools/** untouched.

## Design / API as implemented (matches plan "telex-core API" exactly)
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Lang { #[default] Unknown, En, Vi }
#[derive(Clone, Copy, PartialEq, Eq)]   // Debug: "Finished { <redacted len=N>, lang: X }"
pub struct Finished<'a> { pub text: &'a str, pub lang: Lang }
impl Composer { pub fn finish(&self, prev: Lang) -> Finished<'_>; }
```
Additions beyond the plan: `Clone, Copy, PartialEq, Eq` and a redacted `Debug` on `Finished`.
Rule implemented (also the doc comment of `finish`):
1. Empty word → "" , prev.
2. Passthrough (invalid → raw, or after undo by repeat; mode != Viet) → text shown; Vi if it has a non-ASCII letter, else En if it has ASCII letters, else prev (D8).
3. Viet mode, text == keys (`ba`, `the`, `d`) → text, prev (D7).
4. Viet mode, text != keys:
   - no vowel (`dd`→đ) → text, Vi (D9, AC-1);
   - nucleus not complete (exact match in OPEN/OPEN_LONG without final, CLOSED with final; `úe` `ủe` `tưo` `ă` `â` `ươ`) → keys, En (AC-1);
   - keys ∉ en.txt → text, Vi;
   - keys ∈ en.txt, text ∉ vi.txt → keys (typed case), En (AC-2);
   - keys ∈ en.txt, text ∈ vi.txt → prev == En ? (keys, En) : (text, Vi) (AC-3).
Lookups: only inside `finish`, binary search O(log n) line probes on the embedded text, no index, no allocation; keys folded with `to_ascii_lowercase`, text with `char::to_lowercase`, compared char by char (UTF-8 byte order == code point order, matching the files' byte sort).

## AC-7 measurement (cargo test -p telex-core --locked --test finish_measure -- --include-ignored --nocapture)
```
spec words: sentence-first English 3/25 ["use", "user", "two"]; after an English word 25/25
english sample: 15238 words; unchanged before (text) 14241 (93.46 %), finish(Unknown) 14708 (96.52 %), finish(En) 15087 (99.01 %)
golden words: 25651 in vi.txt (unchanged by finish: 25651), 5901 not in vi.txt (221 of them changed by finish with prev Unknown or Vi, 217 of those with keys in en.txt); changed examples: ["ax->ã(en)", "bays->báy(en)", "bias->bía(en)", "bins->bín(en)", "boar->boả(en)", ...]
```
- 25 spec words: 22 are overlap words (form in vi.txt) so sentence-first they stay Vietnamese by AC-3 (user decision D1); after an English word all 25 are English.
- Golden: every word (split at non-letters) of every golden line; 100 % of the 25,651 whose text is in vi.txt unchanged with prev Unknown and Vi (asserted, language Vi when changed by the engine, else prev). Of the 5,901 not in vi.txt (rule-generated forms such as `boả`, `bêp`, `dôm`, and prefixes), 221 change: 217 English restores (keys in en.txt), 4 incomplete-syllable fallbacks.
- English sample method: every line of /usr/share/dict/american-english (wamerican) that is 2–6 lowercase ASCII letters, in file order (15,238 words; the list has no frequency, short words stand in for common ones). Remaining after finish(En): 151 words (not broken down; expected kinds: undo-by-repeat words, D8, and words not in en.txt).

## Commands run (trimmed)
`PATH=$HOME/.cargo/bin:$PATH cargo test -p telex-core --locked`
```
unittests src/lib.rs   ok. 4 passed
tests/finish.rs        ok. 12 passed   (stderr: en.txt: 1099 words, 245 end as passthrough (undo by repeat), 1 without vowel)
tests/finish_measure.rs ok. 2 passed; 1 ignored
tests/golden.rs        ok. 1 passed
tests/rules.rs         ok. 23 passed
doc-tests              ok. 0 passed
```
Guard: `cargo fmt --check` → no output (clean); `cargo clippy --workspace --all-targets --locked -- -D warnings` → `Finished dev profile` with no warnings.
Red step: tests/finish.rs failed to compile (`unresolved import telex_core::Lang`, 7× `no method named finish`).

## Deviations / open points
- D7: unchanged ASCII words keep prev (brief rule) instead of spec AC-4's "in vi.txt → Vi".
- D8 (open for leader/user): 245 en.txt words end as passthrough after an undo by repeat (`bass`→`bas`, `buses`→`bues`) and are not restored; restoring would break the Telex way of typing `as` (`ass`).
- D9: `dd` (in en.txt) stays `đ` per AC-1.
- Spec example `the best` sentence-first → `bét` (`the` is unchanged, so it does not set En); `use the best` → `best`.
- `Box`/`her` are overlap words in E1's data, so sentence-first they stay `Bõ`/`hẻ` (spec AC-2 examples assumed otherwise; data question for E1).
- `parse` (pre-existing, also run per key) allocates small Vec/String temporaries that are not wiped; finish adds none.

## Out-of-scope noticed
- `tools/golden-gen/__pycache__/` appeared untracked (not from E2; .gitignore lacks `__pycache__`).

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| syllable validity / nucleus | lib.rs `parse`, OPEN/OPEN_LONG/CLOSED | reused; `is_complete` does exact match on the same tables |
| case-folded lookup | lib.rs, no deps in Cargo.toml | new `words::contains` (no alloc), nothing to reuse |
| wiping temporaries | `wipe_string` | not needed: finish allocates nothing |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| AC-1 | pass | finish.rs `incomplete_syllable_commits_raw_keys`, `words_without_vowel_keep_their_text`, `complete_vietnamese_syllables_stay`; finish_measure.rs golden assertion (25,651/25,651 unchanged) |
| AC-2 | pass | finish.rs `every_english_list_word_follows_the_rules` (all 1,099 en.txt words, upper-case typed-case check), use/user/two |
| AC-3 | pass | finish.rs `overlap_follows_the_previous_word` (best/list/has/Best/BEST with Unknown, Vi, En) |
| AC-4 | pass | finish.rs `passthrough_and_undo_words_are_english`, `passthrough_text_with_vietnamese_letters_is_vietnamese`, `unchanged_ascii_words_keep_the_previous_language`, `empty_word_keeps_the_previous_language`; rule in `finish` doc comment + D7/D8 |
| AC-6 | pass | src/words.rs `include_str!`, binary search, no I/O, no allocation; lookups only in `finish` (push/pop untouched); data 86 KB |
| AC-7 | pass | numbers above, finish_measure.rs |
| SEC-2 | pass | `Finished` Debug redacted (`finished_debug_hides_the_text`); no logging in telex-core |
| SEC-4 | pass | no temporaries in finish/lookup (char-by-char folded comparison); Composer::clear unchanged |
| BASE-10 / COST | pass | only `cargo test -p telex-core --locked` + guard once |
| BASE-14/15 | pass | all commands foreground; nothing started in background |
| BASE-16 | pass | Reuse table |
| BASE-19 | pass | this file, progress lines |
| BASE-38 | pass | rustfmt run only on lib.rs, words.rs, finish.rs, finish_measure.rs |
| Scope | pass | no edits to ime-core, data/**, tools/**, golden.rs, rules.rs, golden tsv; nothing staged/committed |

Nothing left running.

DONE E2

## D10 addition

### Progress
- read: notes, D10, words.rs, finish(), wordfilter example, tests
- data: crates/telex-core/data/en_plain.txt curated (489 candidates → 46 changed by Telex dropped → 20 Vietnamese-reading words dropped → 423)
- red: tests/finish.rs 3 new tests failed (`the` → Unknown/Vi instead of En; every plain word)
- green: words.rs `is_plain_english`, finish() text == keys branch
- measure + README + .gitignore; related tests and guard clean

### Files changed (this step)
- crates/telex-core/data/en_plain.txt (new) — 423 words, 2.6 KB, lowercase ASCII, `LC_ALL=C sort -c -u` ok, LF, no blanks.
- crates/telex-core/src/words.rs — `EN_PLAIN` (`include_str!`), `is_plain_english` (same allocation-free binary search, ASCII case folding); unit tests cover sort/unique of the new list and `The`/`to`.
- crates/telex-core/src/lib.rs — `finish`: text == keys → `Lang::En` when keys are in the plain list, else `prev`; doc comment updated. Text never changes; all other branches unchanged.
- crates/telex-core/tests/finish.rs — `the` removed from `unchanged_ascii_words_keep_the_previous_language`; new `plain_english_words_set_english`, `vietnamese_looking_plain_words_keep_the_previous_language`, `vietnamese_sentence_stays_vietnamese`, `every_plain_english_word_is_unchanged_and_english` (every entry, lower and upper case, all three prev, and not in en.txt).
- crates/telex-core/tests/finish_measure.rs — golden assertion expects En for plain-list words (text still asserted unchanged); spec words and English sample also measured after `the`.
- tools/wordlists/README.md — en_plain.txt row + "Plain English" source paragraph (hand-curated, no third-party list, how checked, excluded examples).
- README.md — English words section: `the best`, common English words typed as is count as English.
- .gitignore — `__pycache__/`.

### Curation
- Candidates: hand-written everyday words (function words, pronouns, prepositions, auxiliaries, common verbs/adverbs, numbers, a few office nouns: file, email, project, team). Throwaway lists in $TEAM_WS/qa-artifacts/E2/ (cand.txt, cand2.txt, exclude.txt).
- Engine check: `cargo run -q -p telex-core --example wordfilter --locked -- changed < en_plain.txt | wc -l` → `0`. Dropped as changed by Telex (46), e.g. of, is, as, if, or, us, was, this, has, his, see, keep, life, six — these cannot be plain (text != keys); several are handled by en.txt.
- Judged Vietnamese reading common → left out: a, i (single letters), am, an, can, day, do, in, long, man, may, me, men, no, ran, run, so, than, to, say.
- Kept although the shape is a Vietnamese syllable without marks (reading rare or needs a tone/mark): the, then, them, he, be, go, my, on, ten, him, via, buy; stop-final words without tone are not Vietnamese (at, it, but, not, got, cut, let, met, set, sit, up).
- No overlap with en.txt (checked in the test).

### AC-7 measurement (`cargo test -p telex-core --locked --test finish_measure -- --include-ignored --nocapture`)
```
spec words: sentence-first English 3/25 ["use", "user", "two"]; after `the` 25/25; after an English word 25/25
english sample: 15238 words; unchanged before (text) 14241 (93.46 %), finish(Unknown) 14708 (96.52 %), finish(En) 15087 (99.01 %), after `the` 15087 (99.01 %)
golden words: 25651 in vi.txt (unchanged by finish: 25651; 37 of them plain English, language En), 5901 not in vi.txt (221 of them changed by finish with prev Unknown or Vi, 217 of those with keys in en.txt)
```
- Sentence-first numbers unchanged (a single word has no previous word); `the best` now gives `best` (was `bét`), `the Box` → `Box`.
- Golden: text of all 25,651 unchanged (asserted). The 37 golden words in vi.txt that are plain-list words (at, be, but, go, he, him, it, my, on, ten, the, them, then, up, via…) now report En instead of prev; text unchanged. Effect on real Vietnamese: only the next overlap word after one of them is restored as English — the judged trade-off of D10.

### Commands run (trimmed)
`cargo test -p telex-core --locked`
```
unittests src/lib.rs    ok. 4 passed
tests/finish.rs         ok. 16 passed
tests/finish_measure.rs ok. 2 passed; 1 ignored
tests/golden.rs         ok. 1 passed
tests/rules.rs          ok. 23 passed
doc-tests               ok. 0 passed
```
Red: `cargo test -p telex-core --locked --test finish` → `FAILED. 13 passed; 3 failed` (`true: got ("true", Unknown)` …).
Guard: `cargo fmt --check` → clean (no output); `cargo clippy --workspace --all-targets --locked -- -D warnings` → `Finished dev profile … in 2.03s`, no warnings.

### Rule compliance (D10)
| Rule | Status | Evidence |
|---|---|---|
| AC-3 | pass | finish.rs `plain_english_words_set_english` (`the` → En, then `best` → `best`; `the` then `Box` → `Box`); `overlap_follows_the_previous_word` unchanged and green |
| AC-4 | pass | `unchanged_ascii_words_keep_the_previous_language` (ba/to/can keep prev), `vietnamese_looking_plain_words_keep_the_previous_language`, `every_plain_english_word_is_unchanged_and_english`; rule in `finish` doc comment |
| AC-6 | pass | words.rs `EN_PLAIN` via `include_str!`, same binary search, no allocation, no I/O; lookup only in `finish`; +2.6 KB |
| AC-7 | pass | numbers above; golden text 25,651/25,651 unchanged (asserted) |
| SEC-2 | pass | no logging added; `Finished` Debug still redacted (`finished_debug_hides_the_text`) |
| SEC-4 | pass | `is_plain_english` folds on the fly, no temporaries; no new buffers in `finish` |
| BASE-10 / COST | pass | only `cargo test -p telex-core --locked` + guard once |
| BASE-14/15 | pass | all foreground, nothing started in background |
| BASE-38 | pass | rustfmt only on lib.rs, words.rs, finish.rs, finish_measure.rs |
| Scope | pass | files within the board row; nothing staged/committed |

Nothing left running.

DONE E2 (D10)

## Fix round 1
Review: $TEAM_WS/05_review_E2.md.

| Finding | Reply |
|---|---|
| [major] en_plain.txt holds common unaccented Vietnamese words | fixed — rule: no en_plain entry is a vi.txt syllable, except `the` (D10); 23 entries removed; enforced by finish.rs `plain_english_words_are_not_vietnamese_syllables` |
| [minor] no upper-case lookup of non-ASCII vi.txt entries | fixed — words.rs unit test `every_vietnamese_entry_is_found_in_upper_case` (every vi.txt line, upper-cased, through `is_vietnamese`) |

- Removed (23, all in vi.txt): at be but buy cut go got he him it let met my not on set sit ten that them then up via
- Also reviewed the flagged `one`, `kill`, `die`: not vi.txt syllables and not Vietnamese words without marks → kept. No other remaining entry judged a common unaccented Vietnamese word.
- en_plain.txt now 400 words, 2,523 bytes; `wordfilter changed` on it → `0`.
- Tests: `vietnamese_looking_plain_words_keep_the_previous_language` now also checks that, them, then, on, ten, met, be, he, my, go keep prev. No test used a removed word as plain English (the/with/would only).
- Red: before the data change the rule's check listed 23 words (`grep -xFf en_plain.txt vi.txt | grep -vx the` → 23 lines); after → 0.
- Docs: tools/wordlists/README.md (count 400, rule stated, excluded examples).

### AC-7 re-measured
```
spec words: sentence-first English 3/25 ["use", "user", "two"]; after `the` 25/25; after an English word 25/25
english sample: 15238 words; unchanged before (text) 14241 (93.46 %), finish(Unknown) 14708 (96.52 %), finish(En) 15087 (99.01 %), after `the` 15087 (99.01 %)
golden words: 25651 in vi.txt (unchanged by finish: 25651; 1 of them plain English, language En), 5901 not in vi.txt (221 changed, 217 with keys in en.txt)
```
Golden plain-English words in vi.txt: 37 → 1 (`the`).

### Commands (trimmed)
`cargo test -p telex-core --locked`: unittests 5 ok; finish 17 ok; finish_measure 2 ok, 1 ignored; golden 1 ok; rules 23 ok; doc-tests 0.
Guard: `cargo fmt --check` clean; `cargo clippy --workspace --all-targets --locked -- -D warnings` → Finished, no warnings.

### Rule compliance (round 1, rows touched)
| Rule | Status | Evidence |
|---|---|---|
| AC-3 | pass | `plain_english_words_set_english` (the best → best, the Box → Box) |
| AC-4 | pass | `vietnamese_looking_plain_words_keep_the_previous_language`, `plain_english_words_are_not_vietnamese_syllables`, `every_plain_english_word_is_unchanged_and_english` |
| AC-6 | pass | `every_vietnamese_entry_is_found_in_upper_case`; lookup code unchanged |
| AC-7 | pass | numbers above |
| SEC-2 | pass | unchanged, no logging |
| SEC-4 | pass | unchanged, no allocation in finish |
| BASE-38 | pass | rustfmt only on words.rs, finish.rs |

Nothing left running.

DONE E2 (fix round 1)
