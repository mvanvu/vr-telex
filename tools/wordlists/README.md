# Word lists for English detection

Generated data embedded by `telex-core` (`include_str!`):

| File | Content | Lines |
|---|---|---|
| `crates/telex-core/data/en.txt` | lowercase ASCII English words (length >= 2) whose Telex reading the engine changes | 1099 |
| `crates/telex-core/data/vi.txt` | lowercase NFC Vietnamese syllables with marks and tone | see `gen.py` output |

Format of both: one entry per line, unique, sorted by byte order, LF, no comments, no blank lines.

## Sources and licences

- English: `wamerican` 2020.12.07-2 (`/usr/share/dict/american-english`), derived from SCOWL
  (Spell Checker Oriented Word Lists, Kevin Atkinson). Permissive licence, notice text in
  `THIRD-PARTY-NOTICES.md`. Dropped: entries with non-ASCII letters, apostrophes, capitals
  (proper nouns), length < 2. Kept: only words the engine changes (the real `Composer` is run
  key by key by the cargo example `crates/telex-core/examples/wordfilter.rs`).
- Vietnamese: the syllable inventory is team-authored (`vi_rhymes.py`: a table of which initials
  go with which rhymes, over the rule-valid shapes of `tools/golden-gen/gen.py`; inclusive when in
  doubt) and merged with the syllables found in an optional Vietnamese word list (any, one word
  per line) given on the command line. Only the set of syllables (facts) is used; no word list is
  shipped or copied into the repository. Every entry is checked against the engine: typing its
  Telex keys must give the syllable back. Syllables that cannot be typed with the engine (`thuở`,
  `huơ`, `khuơ`, `quơ` and their tones) are left out.
- Overlap decisions (`vi_overrides.py`): every Vietnamese form that an `en.txt` word produces was
  judged real or not real. Forms judged not real are removed from `vi.txt`, so those English words
  are restored as English.

No GPL or CC-BY-SA data is shipped. No network access is needed.

## Regenerate

From the repository root (needs `cargo` and `python3`):

```
PATH=$HOME/.cargo/bin:$PATH python3 -I tools/wordlists/gen.py [--viet-source WORDLIST] [--english PATH]
```

`--viet-source` is optional (a Vietnamese word list, one word per line, never committed); without it
`vi.txt` holds only the authored syllables. `--english` defaults to
`/usr/share/dict/american-english`. The script prints the counts and writes both files.
The engine filter alone: `cargo run -q -p telex-core --example wordfilter --locked -- pairs < words.txt`
(modes: `changed`, `pairs`, `check`).
