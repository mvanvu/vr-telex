# Review FR-12 — PASS (APPROVED)

## Findings
[minor] crates/telex-core/src/lib.rs:332 — undone key is read from the char before the new key, so after a non-alphabetic key in Undone mode it is that symbol
Scenario: `liss1s` / `ass1s` → undone = '1', so the same-key exemption cannot fire and the word continues shown (`lis1s`); `liss1a` still restores raw (`liss1a`). Both are consistent with D37 (consonant continues, vowel keeps raw); only the same-key exemption is skipped. No test pins it.
Fix: optional — pin the behaviour in a test, or leave as is.

[minor] crates/telex-core/tests/rules.rs:187 — missing cases: uppercase (`LISST`, `Dddt`), `ww`+consonant (lone-w ư removed), BackSpace after continue for dd/horn families
Scenario: code is correct by reading (keys lowercased; `uww`+t, `www`+t, `dddt` go through the same path; replay of shown text on BackSpace equals the text only when it truly re-forms, e.g. `lisst<<` → `li`), but nothing guards it.
Fix: add 3-4 table rows.

Checked, no defect: undone-key detection per family (s f r x j, aa/ee/oo, w incl. `uwwt`/`towwn`, dd incl. `dddt`/`dddd`); BackSpace after continue_shown (raw = shown text, replay of `lis`/`nex`/`aa` gives a different text so it stays Raw; replay of `te` gives same text and swaps back to Viet, which is correct); shown text with ê/đ in raw (`vieetss`+t): replay still yields identical text; `raw()` is only used for the key-count cap in ime-core (byte length, slightly lower cap for multi-byte, harmless); SEC-4: raw is wiped before text is copied in, text is the same data, no extra copy; README line 71 matches behaviour (xooong → xoong), line 60 still true. D17 text in decisions.md is superseded by D38.

## Rule check FR-12
| Rule | Result | Evidence |
|---|---|---|
| AC-1 golden >=2000 | pass | `cargo test -p telex-core --locked`: golden 1 pass, rules 22 pass (reran) |
| D37 | pass | vowel keys, l/r, same key keep raw; other consonants continue shown (tests `consonant_after_undo_continues_the_shown_text`) |
| D38 | pass | aaat/seeet/booot/xooong covered; old xooong expectation replaced |
| BASE-25 guard | pass | dev notes: fmt+clippy clean; no new deps |
| Comments English, no bug history | pass | comments at lib.rs:147, 332-348 describe behaviour only |

## Files read
crates/telex-core/src/lib.rs read; crates/telex-core/tests/rules.rs read; README.md read.
