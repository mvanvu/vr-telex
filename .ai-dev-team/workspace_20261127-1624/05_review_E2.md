# Review E2 — CHANGES_REQUESTED (FAIL)

## Findings
[major] crates/telex-core/data/en_plain.txt — entries that are common unaccented Vietnamese
Scenario: a user typing Vietnamese without marks writes `that` (thật), `them` (thêm), `on` (ổn), `ten` (tên), `met` (mệt), `be` (bé), `he` (hè), also `then`, `my`, `go`, `him`. Each sets `Lang::En` (text unchanged), so the next overlap word is restored as English: `on` then `best`/`list`/`has` gives the English raw keys. (`the` is the D10 decision itself and is not filed.) The brief and the D10 criterion say "not common as unaccented Vietnamese". The notes' own exclusion list (an, can, day, do, no, so, to, say) uses the same test, but applies it unevenly.
Fix: drop at least `that, them, then, on, ten, met, be, he`. Consider `my, go, him, via, buy, one, kill, die, set, let`. The golden measure shows 37 plain words that are also in vi.txt. Use that list as the audit, and drop every entry whose Vietnamese reading is a common word.

[minor] crates/telex-core/tests/finish.rs — no case-fold check for a non-ASCII entry of vi.txt
Scenario: the lookup is correct (see AC-6 below), but only en.txt and en_plain.txt entries are probed against `finish`. Fix: add a test that looks up every vi.txt line through `is_vietnamese` with upper-case input. Optional.

## Verified, no finding
- AC-6 lookup order: `LC_ALL=C sort -c -u` passes on en.txt, en_plain.txt and vi.txt. A probe of the `contains` code looked up every line of each list: 0 misses. 0 false positives for `line+"x"`. The char-wise comparison matches the byte order of the files. Uppercase Vietnamese text is folded by `char::to_lowercase`; text is NFC.
- Probes in $TEAM_WS/qa-artifacts/E2-review/pr, run for all three prev values:
  - `BEST`/`Best`/`best` with prev En → raw in typed case. With Unknown/Vi → `BÉT`/`Bét` (AC-3).
  - `dd`/`DD`/`Dd` → `đ`/`Đ`, Vi.
  - `qu`, `gi`, `GI` keep their text. They take prev, or En under prev En (D7). Fine.
  - `ass` → `as` En (D8). `use`/`user`/`USER` → raw keys, En.
  - `the` → En. `the` then `Box` → `Box` (En). Sentence-first `Box` → `Bõ` (known E1 data issue, noted in the dev notes).
  - A 40-key word and an 80-key word run without panic or allocation in `finish`. An empty composer, and one emptied by pop, give `""` with prev.
- AC-7: reran the measure test with `--include-ignored`. The numbers match the notes (25 words 3/25 sentence-first, 25/25 after `the`; sample 96.52 % / 99.01 %; golden 25,651 unchanged). Reproducible.
- SEC-2: `Finished` Debug is redacted. No logging in the crate. SEC-4: `finish` allocates nothing and the lookups use on-the-fly folding. The `parse` temporaries are pre-existing and per key, not E2.
- en_plain.txt: sorted, unique and lowercase. The dev notes say the wordfilter `changed` run gives 0 (not rerun here). No overlap with en.txt (tested).
- API: matches the plan. Additions (Copy/PartialEq on Finished, redacted Debug) are benign for E3. Lang derives Default.
- Deviations D7/D8/D9 are documented. D8 (245 words end as passthrough after an undo by repeat, `bass` → `bas`) stays open for the user.

## Files read
crates/telex-core/src/lib.rs (diff) read; src/words.rs read; data/en_plain.txt read; data/en.txt, vi.txt skipped — generated lists (sort and lookup probed); tests/finish.rs, tests/finish_measure.rs read (head, measure run); README.md, tools/wordlists/README.md, .gitignore skipped — docs and config, not behaviour.

## Rule check E2
| Rule | Result | Note |
|---|---|---|
| AC-1 | pass | probes, golden 25,651/25,651 |
| AC-2 | pass | raw in typed case |
| AC-3 | pass | |
| AC-4 | pass | D7/D8/D9 documented; D10 content finding above |
| AC-6 | pass | binary search, every line found, no allocation |
| AC-7 | pass | rerun matches |
| SEC-2 | pass | |
| SEC-4 | pass | |
| D10 plain-list criteria | fail | Vietnamese-reading words (major above) |

## Re-check fix round 1 — APPROVED (PASS)
- Major closed: en_plain.txt is now 400 words. `that, them, then, on, ten, met, be, he, my, go` are gone, as are `him, via, buy, it, at, but, up, cut, got, let, set, sit, not`. `grep -xFf en_plain.txt vi.txt` returns only `the` (D10). `finish` keeps prev for the removed words, and `them best` from Unknown gives `bét` (the plain list no longer sets En). The `vietnamese_looking_plain_words_keep_the_previous_language` test covers the ten words.
- Wordfilter `changed` on en_plain.txt: 0 (rerun).
- Rule test sound: it derives the check from the vi.txt syllable set, so any future entry that is a Vietnamese syllable fails unless it is `the`. A scan of the remaining 400 found no common unaccented Vietnamese word. `one`, `kill`, `die`, `line`, `name` and `new` are not vi.txt syllables, so they are acceptable.
- Minor closed: `every_vietnamese_entry_is_found_in_upper_case` looks up every vi.txt line in upper case.
- `cargo test -p telex-core --locked`, run once: unit 5, finish 17, measure 2 (1 ignored), golden 1, rules 23, all ok.

| Rule | Result |
|---|---|
| AC-3 | pass |
| AC-4 | pass |
| AC-6 | pass |
| AC-7 | pass (golden plain words in vi.txt 37 → 1) |
| SEC-2 | pass |
| SEC-4 | pass |
| D10 plain-list criteria | pass |
