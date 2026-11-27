# Task board — EN-DETECT

| ID | Task | Owner | Depends on | Tags | Rules | Files | Verify with | Status | Rounds |
|----|------|-------|-----------|------|-------|-------|-------------|--------|--------|
| E1 | Word lists: en.txt (English words the engine changes, from SCOWL/wamerican) + vi.txt (real Vietnamese syllables) + generator + provenance/licences | be | - | - | AC-6, AC-9 | crates/telex-core/data/en.txt, crates/telex-core/data/vi.txt, tools/wordlists/**, crates/telex-core/examples/wordfilter.rs, THIRD-PARTY-NOTICES.md | format checks in generator + counts in notes | done | 1 |
| E2 | telex-core: `Lang`, `Composer::finish` (complete-syllable check, English restore, overlap by previous word) + tests + AC-7 measurement | be | E1 (relaxed: only the data format is consumed; E2 never edits data/** or tools/**) | - | AC-1, AC-2, AC-3, AC-4, AC-6, AC-7, SEC-2, SEC-4 | crates/telex-core/src/**, crates/telex-core/tests/** (not golden tsv content), README.md (short section) | cargo test -p telex-core --locked + guard | review | 0 |
| E3 | ime-core: per-context last language, finish at every word end, per-edit-mode commit, resets + tests | be | E2 | security | AC-4, AC-5, AC-6, AC-8, SEC-2, SEC-4, SEC-13, B3 | crates/ime-core/** | cargo test -p ime-core --locked, cargo test -p fe-ibus -p fe-fcitx --locked + guard | queued | 0 |

## Notes
presence: away (user, 14:39)
hand-off: ready (14:39)
fable-policy: auto (user, carried from previous run 19:15 26 Nov)
commits: local, one per task, no push (user, 26 Nov 19:15; confirmed 14:21)
install: reinstall daemon from the final reviewed commit (user, 14:21)
archive: workspace → workspace_20261127-1422 (committed 8fa1928)
route: new feature, unattended; has_ui false; Phase 5 correctness + security via Agent tool (no Workflow)
phase0: paths ✓ · profile ✓ (existing, guard/tests unchanged) · local fields ✓ (written 14:22: heavy_slots 2, account_switch 2) · temporary values ✓ (none) · stray-team-files ✓ · env-drift n-a (no .env) · commit identity ✓ (repo-local, unchanged) · upstream — (local-only commits by user choice) · e2e one spec n-a (harness options per app) · test logins n-a
held for user: FR-13 follow-up question — where/how `fê` was seen (engine gives `fee`)
decisions: see decisions.md
eta: ~16:30 (set 14:24, basis: critical path E1 (~30) → E2 (~45) → E3 (~45) + sign-off qc + Phase 5 (~40), 1 agent at a time)
E1 verdict gate (14:36): review FAIL, rule table present; high finding re-graded major (vi.txt only consulted for en.txt words; reviewer's AC-1 scenario does not apply — AC-1 is structural) but fix round 1 opened (cheap, list correctness). E2 continues: consumes format only.
E1 re-check (14:39): PASS; committed below. Minor for report: add __pycache__/ to .gitignore (rides with E2 fix round); 98 engine-dropped tokens incl. thuở/huơ/boong (engine can't type).
