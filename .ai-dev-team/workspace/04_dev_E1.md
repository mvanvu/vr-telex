# E1 notes — word lists

Files: crates/telex-core/data/en.txt, crates/telex-core/data/vi.txt, tools/wordlists/{gen.py,vi_rhymes.py,vi_overrides.py,README.md}, crates/telex-core/examples/wordfilter.rs, THIRD-PARTY-NOTICES.md. Decision D6 appended.

## Sources and licences
English: wamerican 2020.12.07-2 (SCOWL, permissive; notice reproduced). Vietnamese: authored rhyme table merged with the syllables of an optional word list passed on the command line (not shipped, not named in the repo, D4/D5).

## Counts
english candidates (ASCII lowercase, len>=2) 63849; en.txt lines 1099 (6392 B); distinct Vietnamese forms from en.txt 990, judged real 338; vi source tokens 10523 -> valid complete syllables 7299; authored syllables 12900 (5757 only in the authored table); dropped by engine check 18 (huơ/khuơ/thuơ + tones, untypeable); vi.txt lines 12866 (79936 B). Total 86 KB.

## 30 overlap rows (english -> vietnamese form -> real?)
airs -> ái -> real
barfs -> bá -> real
barns -> bán -> real
bars -> bá -> real
bast -> bát -> real
boom -> bôm -> real
burns -> bún -> real
burst -> bút -> real
cars -> cá -> real
chary -> chảy -> real
cuts -> cút -> real
dos -> dó -> real
goon -> gôn -> real
hangs -> háng -> real
huts -> hút -> real
loots -> lốt -> real
lost -> lót -> real
moor -> mổ -> real
mos -> mó -> real
mow -> mơ -> real
nos -> nó -> real
oops -> ốp -> real
ow -> ơ -> real
secs -> séc -> real
sons -> són -> real
tams -> tám -> real
this -> thí -> real
thorns -> thón -> real
turfs -> tú -> real
vets -> vét -> real

## The 25 spec words
Overlap (in en.txt and form in vi.txt): this thí, see sê, now nơ, how hơ, was ứa, is í, as á, us ú, has há, his hí, her hẻ, most mót, host hót, box bõ, mix mĩ, max mã, tax tã, car cả, test tét, best bét, last lát, list lít. English-only (form not real, restored at word end): use úe, user ủe, two tưo. All 25 are in en.txt.

## Format checks
LC_ALL=C sort -c -u passes on both files; no blank lines, no CR; en.txt matches [a-z]{2,}; vi.txt NFC lowercase; gen.py asserts these and runs the engine `check` mode on every vi.txt entry (typed keys -> syllable).

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| AC-6 | pass | data only; 86 KB total <= 1.5 MB; no src/tests edits |
| AC-9 | pass | tools/wordlists/README.md, THIRD-PARTY-NOTICES.md (SCOWL text); no GPL/CC-BY-SA shipped; no network |
| Data contract | pass | sorted/unique/LF/lowercase; en.txt only engine-changed words |
| vi.txt content | pass | authored + inventory, 990 en forms decided, engine-validated |
| BASE/COST guard | pass | cargo fmt --check, cargo clippy --workspace --all-targets --locked -- -D warnings: clean |
| SEC-2 | pass | wordfilter prints only word lists |

## Fix round 1
Cause: the reference tokens were kept only when their shape existed in the golden-gen tables (GI, GH_OK, QU were narrow). Fix (tools/wordlists only; tools/golden-gen/gen.py untouched):
- tools/wordlists/gen.py: `parse_token` splits every reference token (initial, nucleus, final, tone) with its own initial/final lists and no shape table; the token is kept when the engine check reproduces it from its Telex keys (gen.py's existing `engine("check")` step).
- tools/wordlists/vi_rhymes.py: `EXTRA` widened with authored gi-, ngh-, qu- rhymes and the ngoạm/khoằm/cửi shapes.

Counts before -> after: source tokens 10523 (case-sensitive) -> 9103 (lowercased, distinct); valid syllables from source 7299 -> 7613; authored 12900 -> 13227 (only in authored table 5757 -> 5979); engine-dropped 18 -> 98 (junk tokens and untypeable shapes such as thuở/huơ, boong, xoong); vi.txt 12866 -> 13319 lines (79936 -> 82889 B): 453 added, 0 removed. en.txt unchanged (1099 lines, 6392 B); overrides unchanged.

Spot check: all 51 named families (nghĩa, giúp, giống, giọng, giỏi, giọt, giỗ, giun, gióng, giẻ, giập, giũa, giông, nghêu, nghịu, nghễu, quặm, quạu, quệt, ngoạm, khoằm, cửi and the reviewer's other gi-/ngh-/qu-/ngoàm/khoăm/hoắm tokens) present in every tone (stop finals: s/j). Format: sort -c -u (LC_ALL=C) ok, no CR/blank lines. Guard: cargo fmt --check and cargo clippy --workspace --all-targets --locked -- -D warnings clean.
