# Task board — APT

| ID | Task | Owner | Depends on | Tags | Rules | Files | Verify with | Status | Rounds |
|----|------|-------|-----------|------|-------|-------|-------------|--------|--------|
| A1 | Verify (user, 17:47: shrunk) that the merged tree meets AC-1/AC-2 (rename + migration already in abac0f3); leftovers only (e.g. stray tracked files) as a quick pass | be | - | security | AC-1, AC-2, SEC-19..24 | whole repo except .ai-dev-team/workspace_* (crates/vr-talex → crates/vr-telex via git mv) | cargo test --workspace --locked, tests/install/run.sh, guard | fix | 1 |
| A2 | Packaged per-user setup: `vr-telex-setup` / `--remove` reusing install/uninstall logic with /usr/bin/vr-telex and the system user unit; root refused | be | A1 | security | AC-3, AC-2 | install.sh, uninstall.sh, packaging/** (except packaging/apt/**), new packaging/vr-telex-setup, tests/install/** | tests/install/run.sh | queued | 0 |
| A3 | Debian package via cargo-deb: metadata, maintainer scripts, contents/control test | be | A1 (A2 relaxed: asset paths fixed by the plan) | - | AC-4 | crates/vr-telex/Cargo.toml ([package.metadata.deb] only), packaging/deb/**, tests/deb/** | tests/deb/run.sh | done | 0 |
| A4 | Signed apt repo script + local apt test + release workflow + README apt section | be | A3 (relaxed: consumes only the .deb file name vr-telex_*_amd64.deb and tests/deb/run.sh VR_TELEX_DEB_STRICT; no edits to A3 files) | security | AC-5, AC-6, AC-7 | tools/apt-repo/**, .github/workflows/**, tests/apt/**, README.md (install section) | tests/apt/run.sh | in progress | 0 |
| M1 | Resolve the merge conflict in crates/telex-core/src/lib.rs (merge of origin/master 40c3f02 into local master): keep local 311dbe0 (tone undo at the tone position) and remote 32bb402 + EN-DETECT (mark undo continues the shown text, word-end language decision); both sides' tests green | be | - | - | AC-1 (old run), D37, D39, D40 | crates/telex-core/src/lib.rs only | cargo test -p telex-core --locked, cargo test -p ime-core --locked, guard | done | 0 |

## Notes
presence: away (user, 17:47)
fable-policy: auto (carried)
commits: local, one per task, no push (push / tag / gh-pages / secrets only on the user's go)
route: new feature; Phase 5 (correctness + security) at the end
phase0: paths ✓ · profile ✓ · local fields ✓ · stray-team-files ✓ · commit identity ✓ (unchanged) · upstream ✓ (pushed 16:18, up to date) · archive: workspace → workspace_20261127-1624 (c9d47d6)
order: A1 alone (touches every file). Then A2 ∥ A3 (files disjoint: scripts/packaging vs Cargo.toml metadata + packaging/deb + tests/deb; contract in 02_plan.md). Then A4.
held for user: FR-13 `fê` question; D-entries of EN-DETECT confirm-on-return (archived workspace_20261127-1624/decisions.md)
stopped (16:29, user asked to record progress for the next session): A1 developer stopped before any file change (tree clean). Next session: /ai-dev-team:dev-team continue → start A1 from the brief (spec 01_spec.md, plan 02_plan.md); nothing to resume from code.
resume 17:32 (this machine, plugin 1.0.43, TEAM_BIN=/home/rainy/.claude/plugins/cache/mvanvu/ai-dev-team/1.0.43/skills/project-profiling/references): found a merge in progress of origin/master 40c3f02 into local master (local 6 ahead: FR-12 tone undo 311dbe0, FR-13 rename abac0f3 + live migration; remote 12 ahead: undo fixes 32bb402, EN-DETECT, APT plan). Team-file conflicts resolved by the leader: local run's board/decisions/spec/plan/FR notes archived to workspace_20261127-1730-local (local FR-12/FR-13 differ from the remote FR-12/FR-13 of workspace_20261127-1422); workspace = remote APT board. Code conflict left: crates/telex-core/src/lib.rs → M1.
M1 model: opus (reason: semantic merge of two interacting undo fixes in the engine, not a marker removal).
A1 overlap: local abac0f3 already renamed vr-talex → vr-telex with migration and tests/install scenarios, and the live machine was migrated (AC-1, AC-2, AC-8 part). Proposed to the user: A1 becomes a verification of AC-1/AC-2 on the merged tree plus the leftovers only.
monitor: on (user, 17:30), plugin_src /home/rainy/DEV/ai-dev-team
monitor-last: 17:34 (0 findings, 5 notes; plan: sonnet reviewer on M1 after DONE)
M1 DONE gate 17:35: no markers, rule table present, guard clean, telex-core 64 + ime-core 69 tests pass; one change outside the hunks (ends_in_tone_undo uses undo_inserted). Reviewer: sonnet (engine logic, not high-risk).
M1 verdict gate 17:36: sonnet REVIEW_PASS, rule check table present, 1 minor (BackSpace in Undone resets raw; no visible effect) for the report. M1 done; merge committed locally (commits: local, no push).
A1 decision 17:47 (user): shrink A1 to verification of AC-1/AC-2 on the merged tree + leftovers.
answers 17:48 (user, before leaving): AC-8 install on this machine when done — yes, from a clean checkout of the final reviewed commit, read back service + input source. Real repo GPG key — created by the leader 17:48: rsa4096 sign, expires 2029-11-26, fpr 2C30E91F97E5A566BEFF373736C30B9165329B85, GNUPGHOME ~/.local/share/vr-telex-apt-gnupg (no passphrase, outside the repo), public key ~/.local/share/vr-telex-apt-gnupg/vr-telex.asc → A4 commits it as packaging/apt/vr-telex.asc. Push, gh secret set, Pages, tag: held for user.
tools 17:48: cargo-deb 3.8.0 in /home/rainy/.local/state/ai-dev-team/qa-tools/cargo-deb/bin; dpkg-deb, apt-ftparchive, gpg, shellcheck present. account_switch: none (cswap present). Plugin 1.0.43 = marketplace.
A3 start 17:48: depends A1 relaxed — rename already committed (abac0f3/e14cbc2); A3 files (crates/vr-telex/Cargo.toml [package.metadata.deb], packaging/deb/**, tests/deb/**) disjoint from A1 leftovers. A2 waits on A1 verify (shares tests/install/**).
parallel: A1 verify ∥ A3 — files disjoint (A1 read-only now).
eta: ~20:00 (set 17:48, updated after A1 round 1; basis: A1 verify 20m → A2 60m; A3 45m → A4 60m; Phase 5 30m; install 10m)
hand-off: ready (17:48)
A1 review 17:51: opus REVIEW_FAIL, rule table ✓ — 4 major (selection not kept on migration install.sh:543; tests missing for same position, runtime/address-file cleanup, mode no-overwrite). Spec AC-2 says keep the selection → code fix, no user decision. Round 1 waits for A1 qc (shared tree).
A1 qc 17:52: sonnet QC_PASS (247 tests, 40 install scenarios, guard clean), rule table ✓; its AC-2 mapping is weaker than the review's (did not confirm runtime-file cleanup). Round 1 opened 17:52: 4 review majors, fresh developer (opus: installer + security tag). Files: install.sh, uninstall.sh, packaging/common.sh, tests/install/** — disjoint from A3.
A3 DONE gate 17:56: rule table ✓, guard ✓; one edit outside the row ([package] description in crates/vr-telex/Cargo.toml — cargo-deb needs it for AC-4) accepted for review. Test passes with an A2 placeholder; strict mode for A4. Reviewer sonnet (not high-risk), qc sonnet.
A4 start 17:56: relaxed dependency on A3 (see row); files tools/apt-repo/**, .github/workflows/**, tests/apt/**, README.md (install section), packaging/apt/vr-telex.asc — disjoint from A1 fix (install.sh, uninstall.sh, packaging/common.sh, tests/install/**) and A3. parallel: A1 fix ∥ A3 verify ∥ A4. Developer opus (security tag).
A3 review 17:56: sonnet REVIEW_PASS, rule table ✓; minors: rerun tests/deb/run.sh plain after A2 (A2 brief), SCOWL licence by reference (report). Waiting on A3 qc.
A1 round 1 DONE 17:58: 44 install scenarios 0 failed, guard ✓, rule table ✓; re-check sent to the opus reviewer. Open note for user report: reruns after a migration still put vr-telex first (D33).
A3 qc 17:58: sonnet QC_PASS, rule table ✓; unverified until A2: content of /usr/bin/vr-telex-setup (rerun tests/deb/run.sh with VR_TELEX_DEB_STRICT=1 in A2). A3 done, committed.
