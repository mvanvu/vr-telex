# T3 Independent Telex golden list
- Files changed: tools/golden-gen/gen.py, crates/telex-core/tests/golden/telex_golden.tsv, crates/telex-core/tests/golden/README.md; check script .ai-dev-team/workspace/qa-artifacts/T3/check.py
- Round 0 (superseded): used the LibreOffice vi_VN.dic as syllable source; the user then ruled out any dictionary.

## Fix round 1 (user decision: no dictionary)
- Removed the curl fetch, `--dic`, subprocess/tempfile and the dictionary loader from gen.py; README no longer cites a dictionary.
- Syllable set is rule-generated: initials x nuclei x finals x tones; per-nucleus final tables; c/k, g/gh, ng/ngh by following vowel; qu and gi initials (u / i belong to the initial), g+i for gì/gìn; iê/iêu spelled yê/yêu after empty initial and qu; finals c/ch/p/t only sắc/nặng; D13 tone placement.
- Other sections unchanged (mid-tone, caps, ALL CAPS, uwow, w-alone, z-clear, hand-written, English with own no-valid-syllable oracle).
- Run `python3 -I tools/golden-gen/gen.py`:
```
base syllables 3159, toned syllables 15585
 15585  tone key at the end of the word
  7871  tone key right after the vowel nucleus
  3913  capitalised
  1392  ALL CAPS sample
   852  uwow spelling
   402  w alone
  1029  z clears the tone
    32  hand-written
   476  English / code passthrough (316 words, 35 candidates rejected by the oracle)
 31552  total cases
```
- Format check: `python3 -I qa-artifacts/T3/check.py crates/telex-core/tests/golden/telex_golden.tsv` -> `cases 31552 problems 0 []`
- Spot checks: hoaf=hoà, khoer=khoẻ, thuys=thuý, mias=mía, muas=múa, muwa=mưa, quys=quý, gias=giá, gif=gì, gifn=gìn, nguowif=người, vieetj=vieejt=việt, yeeus=yếu, nghieeng=nghiêng.
- Earlier-found bug kept fixed: hand case `ddaatj` is đật (not đạt); the generator's conflict check catches it; the case is `ddatj`.
- Deviations: none. Out of scope: none. Nothing left running.

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| syllable list / golden generator | capabilities.md, repo (only LICENSE at start) | built new |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 scope | pass | only gen.py, tsv, README.md, notes, qa-artifacts/T3/check.py |
| BASE-7/24 no git add/commit | pass | nothing staged or committed |
| BASE-11 shared tree | pass | no Cargo files, nothing in crates/telex-core/src |
| BASE-14/15/18 no waiting/kill/sub-agents | pass | foreground only |
| BASE-19 notes from start | pass | this file |
| BASE-34 / DESIGN-23 | pass | no network use at all now |
| BASE-16 reuse | pass | Reuse table |
| COST-1..20 | pass | light python runs only; no servers, builds, browsers |
| other BASE-* (tests/UI/server) | n-a | data task |
| AC-1 | pass | engine src never read; own rules + D13; check.py 31552 cases, 0 problems |
| D13 | pass | spot checks above |
