# Task board — APT

| ID | Task | Owner | Depends on | Tags | Rules | Files | Verify with | Status | Rounds |
|----|------|-------|-----------|------|-------|-------|-------------|--------|--------|
| A1 | Rename vr-talex → vr-telex everywhere + automatic migration of an old vr-talex install (install.sh/uninstall.sh/common.sh) + tests/install scenarios; drop tracked tests/install/stubs/__pycache__ | be | - | security | AC-1, AC-2, SEC-19..24 | whole repo except .ai-dev-team/workspace_* (crates/vr-talex → crates/vr-telex via git mv) | cargo test --workspace --locked, tests/install/run.sh, guard | queued | 0 |
| A2 | Packaged per-user setup: `vr-telex-setup` / `--remove` reusing install/uninstall logic with /usr/bin/vr-telex and the system user unit; root refused | be | A1 | security | AC-3, AC-2 | install.sh, uninstall.sh, packaging/** (except packaging/apt/**), new packaging/vr-telex-setup, tests/install/** | tests/install/run.sh | queued | 0 |
| A3 | Debian package via cargo-deb: metadata, maintainer scripts, contents/control test | be | A1 (A2 relaxed: asset paths fixed by the plan) | - | AC-4 | crates/vr-telex/Cargo.toml ([package.metadata.deb] only), packaging/deb/**, tests/deb/** | tests/deb/run.sh | queued | 0 |
| A4 | Signed apt repo script + local apt test + release workflow + README apt section | be | A3 | security | AC-5, AC-6, AC-7 | tools/apt-repo/**, .github/workflows/**, tests/apt/**, README.md (install section) | tests/apt/run.sh | queued | 0 |

## Notes
presence: present (user typed, 16:24)
fable-policy: auto (carried)
commits: local, one per task, no push (push / tag / gh-pages / secrets only on the user's go)
route: new feature; Phase 5 (correctness + security) at the end
phase0: paths ✓ · profile ✓ · local fields ✓ · stray-team-files ✓ · commit identity ✓ (unchanged) · upstream ✓ (pushed 16:18, up to date) · archive: workspace → workspace_20261127-1624 (c9d47d6)
order: A1 alone (touches every file). Then A2 ∥ A3 (files disjoint: scripts/packaging vs Cargo.toml metadata + packaging/deb + tests/deb; contract in 02_plan.md). Then A4.
held for user: FR-13 `fê` question; D-entries of EN-DETECT confirm-on-return (archived workspace_20261127-1624/decisions.md)
stopped (16:29, user asked to record progress for the next session): A1 developer stopped before any file change (tree clean). Next session: /ai-dev-team:dev-team continue → start A1 from the brief (spec 01_spec.md, plan 02_plan.md); nothing to resume from code.
