# Task board — EN-DETECT

| ID | Task | Owner | Depends on | Tags | Rules | Files | Verify with | Status | Rounds |
|----|------|-------|-----------|------|-------|-------|-------------|--------|--------|
| E1 | Word lists: en.txt (English words the engine changes, from SCOWL/wamerican) + vi.txt (real Vietnamese syllables) + generator + provenance/licences | be | - | - | AC-6, AC-9 | crates/telex-core/data/en.txt, crates/telex-core/data/vi.txt, tools/wordlists/**, crates/telex-core/examples/wordfilter.rs, THIRD-PARTY-NOTICES.md | format checks in generator + counts in notes | done | 1 |
| E2 | telex-core: `Lang`, `Composer::finish` (complete-syllable check, English restore, overlap by previous word) + tests + AC-7 measurement | be | E1 (relaxed: only the data format is consumed; E2 never edits data/** or tools/**) | - | AC-1, AC-2, AC-3, AC-4, AC-6, AC-7, SEC-2, SEC-4 | crates/telex-core/data/en_plain.txt, .gitignore, tools/wordlists/README.md, crates/telex-core/src/**, crates/telex-core/tests/** (not golden tsv content), README.md (short section) | cargo test -p telex-core --locked + guard | done | 1 |
| E3 | ime-core: per-context last language, finish at every word end, per-edit-mode commit, resets + tests | be | E2 | security | AC-4, AC-5, AC-6, AC-8, SEC-2, SEC-4, SEC-13, B3 | crates/ime-core/**, crates/fe-fcitx/tests/bus.rs + crates/fe-ibus/tests/protocol.rs (test data only, leader 14:55) | cargo test -p ime-core --locked, cargo test -p fe-ibus -p fe-fcitx --locked + guard | done | 1 |
| P5-1 | Phase 5 fixes in telex-core: restore uses the keys actually typed after BackSpace (corr #1); unchanged Vietnamese words set Vi unless also English (D15, corr #2, new generated list); English word ending in tone undo after an English word → keys (D14, corr #4); wipe parse temporaries (sec #2) | be | E3 | - | AC-2, AC-3, AC-4, D14, D15, SEC-4 | crates/telex-core/src/**, crates/telex-core/tests/**, crates/telex-core/data/en_both.txt, tools/wordlists/** | cargo test -p telex-core --locked + guard | done | 1 |
| P5-2 | Phase 5 fixes in ime-core: BackSpace with no word resets last (D16, corr #3); set_caps keeps the shown word in Surrounding (D17, sec #1) | be | P5-1 | security | AC-4, AC-5, D16, D17, SEC-13 | crates/ime-core/** | cargo test -p ime-core -p fe-ibus -p fe-fcitx --locked + guard | done | 0 |

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
E2 (14:45): first developer stopped on an API content-filter error during the D10 step (no edits); fresh opus developer finished D10 (en_plain.txt 423 words, accepted over 'a few hundred'). DONE gate ok. Review started (sonnet).
E2 verdict gate (14:46): review FAIL, rule table present, code correct; major on en_plain.txt (words in vi.txt). Fix round 1: rule 'en_plain ∩ vi.txt = {the}' + test. D8 (bass→bas) listed for the user on return.
E2 re-check (14:48): PASS; committed. E3 starts.
E3 DONE gate (14:55): rule table 17 pass, guard clean. Review (opus, security tag) ∥ QC (sonnet) — QC E3 doubles as feature sign-off (last task; one full workspace suite + e2e smoke with the daemon built from the tree).
E3 review verdict gate (14:58): FAIL, rule table present; blocker confirmed by reading (surrounding-mode rewrite after Reset/focus-out/disable lands at the moved cursor). Fix round 1 waits for the QC verdict (shared tree, QC builds from it), then carries review + QC issues together.
E3 QC verdict gate (15:14): QC_PASS with rule table; caveat: term once gave 'the bét' (and once lost/moved 3 spaces; installed 32bb402 0/5 vs new 1/6). Fix round 1 (15:14) = review blocker (D13) + QC term anomaly (root cause first; hypothesis to test, not a recipe: a client Reset between words resets last → overlap word turns Vietnamese).
E3 fix round 1 DONE (15:19): D13 fixed (red first); term flake attributed to harness typing before IME FocusIn (replay test added); space shift not E3. Re-check: reviewer (blocker) + qc (own caveat replay).
E3 re-checks (15:22): review PASS, QC_PASS (term caveat withdrawn as unreproduced harness timing; 3-space shift unattributed, not E3 — report). Committed. Phase 5 next (correctness + security, Agent tool).
P5 (15:29): correctness 4 major (all reproduced by leader probe: usern< → uer, email cho anh max → max, the pass → the pas; ime-core BackSpace keeps last by reading), security 2 minor. Fix rows P5-1 (telex-core) then P5-2 (ime-core) — same compile unit, sequential.
account: 1 → 2 (account 1 weekly 98%, P5-1 agent stopped on the limit 15:36; account 2 found active at 15:50)
P5-1 DONE (15:52): rule table 20 pass, guard clean. Re-check by the P5 correctness reviewer (corr #1 #2 #4) and the P5 security reviewer (sec #2). parallel: P5-2 ∥ P5-1 re-checks — files disjoint (crates/ime-core/** vs crates/telex-core/**, tools/**); P5-2 does not edit telex-core.
P5-2 DONE (15:53): rule table pass, guard clean; set_caps keeps last (dev decision, noted). Re-checks queued to the P5 reviewers.
P5 re-checks (15:55): corr #1-#4 closed, sec #1 #2 closed, sec P5-2 []; new: corr major (D15 regression: AI/UI acronyms set Vi) + sec minor (BackSpace replay composer buffers grow, unwiped). P5-1 fix round 1 carries both. P5-2 re-checked clean; commit order P5-1 then P5-2 (P5-2 files disjoint).
P5 (16:01): all re-checks clean (correctness r1 [], security qp1 []). Commits P5-1 then P5-2. Next: one qc re-verification (full suite + e2e smoke + cases, fixes touched telex-core core path), then install.
