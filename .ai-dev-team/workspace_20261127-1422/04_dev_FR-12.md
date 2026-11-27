# FR-12 notes
Files: crates/telex-core/src/lib.rs (Composer::push, keeps_raw_after_undo, continue_shown), crates/telex-core/tests/rules.rs. Removed examples/probe.rs.
Rule (D37 refined): after undo-by-repeat, next letter keeps raw keys if: vowel key (aeiouyw), or l/r, or same key as the undone one. Otherwise continue from shown text, then Raw with raw = shown text.
Golden conflicts with plain D37: offline/Offline/OFFLINE (3) fixed by l/r exemption; asss kept raw by same-key exemption.
Families covered: s, f, r, x, j, w, dd and circumflex aa/ee/oo (aaat->aat, seeet->seet, booot->boot, xooong->xoong; D38).
Tests: cargo test -p telex-core --locked: golden 1 pass (31552 cases), rules 22 pass. Guard fmt+clippy clean.
## Rule compliance
BASE pass, COST pass, AC-1 pass (31552/31552), D37 pass (refined).
