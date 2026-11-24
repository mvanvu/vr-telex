# Telex golden list

`telex_golden.tsv` is an engine-independent expectation list for the Telex rules
(spec section 4, decisions D5 and D13). It was produced without reading any
engine code and without any dictionary or third-party word list.

## Format
- One case per line: `keys<TAB>expected`. `keys` are the typed ASCII characters of one word,
  `expected` is the committed text in Unicode NFC.
- Lines starting with `#` are section headers (with the case count); no other comments, no blank lines.
- No duplicate `keys`; the generator fails on a key that maps to two different results.
- UTF-8, LF line endings.

## Source
- Vietnamese syllables are rule-generated in `tools/golden-gen/gen.py`: initials x nuclei x finals x tones
  with the standard spelling restrictions:
  - `c`/`k`, `g`/`gh`, `ng`/`ngh` chosen by the following vowel (front vowels `e ê i y` take `k`, `gh`, `ngh`);
  - the `u` of `qu` and the `i` of `gi` belong to the initial (`quý`, `giá`), except `gì`, `gìn` where `i` is the only vowel;
  - each nucleus has its own list of allowed finals (`a`: `c ch m n ng nh p t`; `ă â`: no open syllable; `ư`: `c ng t`; ...);
  - `iê`/`iêu` are spelled `yê`/`yêu` without a consonant initial and after `qu`;
  - finals `c ch p t` take only sắc and nặng.
- Tone placement follows D13 (modern): tone on the diacritic vowel (`ơ` for `ươ`, `ê` for `iê/yê/uyê`),
  `oa/oe/uy` on the second vowel, `ia/ua/ưa` open syllables on the first, middle vowel of three-vowel nuclei.
- The reverse function (syllable -> Telex keys) is in the same script.
- English / code words: a hand-written list in the script, filtered so that no Telex reading of the word
  (key letters kept, dropped, doubled or collapsed, and since D18 any later `a`/`e`/`o`/`d` that repeats an
  earlier letter dropped as a free-order key) can be a valid Vietnamese syllable.

## Regenerate
`python3 -I tools/golden-gen/gen.py` (Python 3 standard library only, no network; `--out PATH` writes elsewhere).
Check the result: tab count, NFC, duplicates, at least 2,000 cases.

## Sections
1. Tone key at the end of the word (`vieetj`).
2. Tone key right after the vowel nucleus, before the final consonant (`vieejt`).
3. Capitalised (`Vieetj` -> `Việt`), about 1 in 4 syllables, tone position alternating.
4. ALL CAPS sample (`VIEETJ` -> `VIỆT`), about 1 in 11.
5. `uwow` spelling of `ươ` (the base form is `uow`).
6. `w` alone as `ư` (`tw` -> `tư`, `nhwng` -> `nhưng`).
7. `z` clears the tone and keeps the diacritics (`vieetjz` -> `viêt`).
8. Hand-written: `dd`, `w`, `uow`, undo by repetition (`ass`, `aaa`, `ddd`, `ww`), `asz`.
9. Free-order circumflex (D18), only for syllables with one `â`/`ê`/`ô`, the hat key typed late as a plain
   `a`/`e`/`o` with no adjacent pair. Three placements, each with a capitalised and an ALL CAPS sample:
   after the final, tone last (`vietej` -> `việt`, `viete` -> `viêt`); tone key then hat key (`tiengse` -> `tiếng`);
   tone key, hat key, then the final (`vieset` -> `viết`). Open syllables whose hat vowel is last in the nucleus
   appear only with a tone between the two keys (`bese` -> `bế`); `toio` -> `tôi`.
10. Free-order `đ` (D18): initial `d` plus a later `d` after the final (`duowngd` -> `đương`, `dinhd` -> `đinh`)
    or after the tone key (`duowngfd` -> `đường`), with capitalised and ALL CAPS samples.
11. Hand-written D18 cases (the examples of the decision, `ana` -> `ân`, `dad` -> `đa`, ...).
12. English / code words that stay raw under D18 (`class`, `https`, `git`, `windows`, ...), plain, capitalised
    for a sample, upper case for a sample (309 distinct words).
13. `english_now_vietnamese`: English words whose keys now form a valid syllable (`reset` -> `rết`, `photo` -> `phôt`),
    plain and capitalised. Other words that the D18 reading turns into a syllable but whose result is not one
    of the generated cases (`await`, `array`, `queue`, `safari`, `freeze`) are dropped from both lists.

Sections 1-8 are unchanged by D18. Keys such as `boeo` (a later `o` would put a hat on the first `o`) give no
valid syllable, so they stay as in section 1-8: `boeo` -> `boeo`.

Expected values use D13: `hoà`, `khoẻ`, `thuý`, `mía`, `múa`, `mưa`, `quý`, `giá`, `gì`, `gìn`,
`người` (ơ), `việt` (ê).

## Left out because ambiguous under the spec
- Nucleus `uơ` (`thuở`, `huơ`, ...): the keys `uow` produce `ươ` by rule, so `uơ` has no unambiguous spelling. `quơ` is not affected: the `u` of `qu` belongs to the initial, so its nucleus is plain `ơ`.
- Syllables with a literal doubled vowel (`boong`, `xoong`): `oo`/`ee`/`aa` are transforms, the literal needs
  the undo rule and its continuation is unspecified.
- Undo followed by more keys (`vieeet`, `asss`, `www`): the spec does not say how the rest of the word behaves.
- Tone key typed before the vowel; digits and punctuation inside a word (word boundaries are an engine concern).
- Mixed-case pairs that split a transform (`dD`, `aA`, `uW`).
- English words that a Telex reading can turn into a valid syllable (`test`, `yes`, `music`, `three`, `shift`,
  `screen`, `error`, `drop`, `json`, ...): the generator drops them automatically and prints the list;
  the same applies to words whose keys collide with a Vietnamese case (`chown` = `chơn`).
- Rare or archaic combinations not in the nucleus/final tables of the script (for example `ưn`, `ênh` after `qu`).
