# Review T3 (after fix round 1): CHANGES_REQUESTED

Tools available: Read, Bash, Write, Skill, SendMessage, SubagentHandback.

## Findings
[major] tools/golden-gen/gen.py:~205 (build_syllables) — untoned syllables with finals c/ch/p/t are emitted
Scenario: `tones = ["", "s", "j"]` for fin in c/ch/p/t, so the list holds `bieec>biêc`, `bawc>băc`, `baat>bât`, `chuowp>chươp`, `lwc>lưc`, `muwown`-style open cases etc. (about 990 cases in sections 1/3/4/5/6; e.g. `chuowp`, `voawn` family, `phuowp`). The brief rule and D13 say c/ch/p/t allow only sắc/nặng, so these are not valid syllables; under D15 (raw-key restore when no valid syllable) the engine should keep `bieec`, not output `biêc`. The golden then fails a correct engine, or forces the engine to accept invalid syllables.
Fix: tones for those finals = ["s", "j"] only (drop ""). Keep the plain ngang form only where the final is not c/ch/p/t.

[minor, uncertain] gen.py section "z clears the tone" and hand case `vieetjz>viêt` (also README) — result of z on a c/ch/p/t-final syllable is an invalid syllable (`đêt`, `viêt`); D15 raw restore vs z is unspecified in spec §4.
Fix: restrict section 7 to syllables whose toneless form is valid (non c/ch/p/t finals), or get the leader to decide.

[minor, uncertain] tsv `quow>quơ` (+ tones) vs README "Left out": `uơ` is dropped as ambiguous because `uow` means ươ, yet `quow>quơ` relies on the same keys. Either drop QU `ơ` or document why qu differs (u belongs to the consonant).

## Verified
- Tone placement checked by hand on ~200 sampled lines over all 9 sections (hoài, khoẻ-type oa/oe/uy second vowel, ia/ua/ưa first, ơ for ươ/ươi/ươu, ê for iê/yê/uyê, oai/oay/oeo/uyu/uya/uây). No wrong placement found.
- English list: my looser re-oracle found no word where a plausible Telex reading yields a valid syllable (hits were only non-transform words that pass through unchanged anyway: git, vue, queue, lion). Oracle caveat: cut range(0,3) never tries initial `ngh` (minor, no word affected).
- gen.py imports only os, sys, unicodedata, zlib; no network, no dictionary, no read of crates/telex-core/src. The English words are an in-script list, not Vietnamese.
- 31552 cases (>= 2000); files within scope.

## Files read
tools/golden-gen/gen.py read; crates/telex-core/tests/golden/telex_golden.tsv read (header, section starts, ~200 sampled lines, grep); crates/telex-core/tests/golden/README.md read; .ai-dev-team/workspace/04_dev_T3.md read.

## Rule check T3
| Rule | Result | Evidence |
|---|---|---|
| AC-1 | fail | ~990 untoned c/ch/p/t-final cases (`bieec>biêc`) are not what a Telex user/D15 expects; the rest of the 200 samples are correct |
| D13 | fail | placement correct, but the "c/ch/p/t only sắc/nặng" part is violated by the same cases |
| D14 | pass | rules only, no dictionary/network |
| D15 | pass | my oracle: no kept English word can form a syllable by transform |
| Independence | pass | no reference to engine src |
| BASE-1 | pass | only listed files (+ notes, qa-artifacts) |
| BASE-6 | pass | README/comments English |
| BASE-8 | pass | stdlib only |
| BASE-19 | pass | 04_dev_T3.md exists with Rule compliance |
