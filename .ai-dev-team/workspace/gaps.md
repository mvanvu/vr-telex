# Gaps — run stopped on usage limit (21:34)

State on stop:
- Done and committed on master: T1, T2, T3, T4, T6 (merged 8830628), T8 (+ quick pass 5011ca2), T9 (8ccf1aa), T10 (merged dbacdd1). T7 cancelled (D19).
- T5 (fe-ibus): code + fix round 1 complete in worktree ../vr-talex-wt-T5 (branch t5-fe, UNCOMMITTED). QC_PASS. Security re-check of fix round 1 was stopped before its verdict → resume: re-send the re-check brief to a fresh opus reviewer (findings in 05_review_T5.md, replies in 04_dev_T5.md "Fix round 1"), then commit in the worktree and merge (Cargo.lock overlap with T6 → merge master into t5-fe first; sonnet developer regenerates Cargo.lock if it conflicts).
- FR-1 (QT_IM_MODULE=fcitx, D27): developer stopped right after start; check `git -C . diff -- packaging tests/install` for partial edits, then brief a fresh sonnet developer from the board row.
- Not started: sign-off (full e2e run ~2 h 50 min, `tests/e2e/run.sh --ime daemon` + install scenario), Phase 5 final review (correctness, security), Phase 6 report.

Held for the user: D1, D18, D26 (VS Code terminal loss at 15 ms/key, none at 30 ms), D9 not needed, shellcheck (`sudo apt install shellcheck`), /var/crash/_usr_bin_gnome-shell.1000.crash (safe to delete), manual real-desktop run O1.
