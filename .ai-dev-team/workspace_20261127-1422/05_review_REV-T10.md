# Review REV-T10 (revert 20cab1a): APPROVED

## Files read
- git diff 8bb3a65 20cab1a -- crates/telex-core tools/golden-gen: empty (lib.rs, rules.rs, golden tsv, README, gen.py identical to 8bb3a65). read.

## Checks
- D18 examples (vieset, tiengse, dinhd, duowngfd, rết) in crates/ime-core, fe-fcitx, tests/e2e, tests/install: no hits.
- cargo test -p telex-core -p ime-core --locked: all ok (ime-core 13+6+4+8+11+1; telex-core golden_list ok, rules 21 ok). Golden data rows: 31552 (excluding comment lines).

## Findings
None.
