# Task board — vr-talex

| ID | Task | Owner | Depends on | Tags | Rules | Files | Verify with | Status | Rounds |
|----|------|-------|-----------|------|-------|-------|-------------|--------|--------|
| T1 | Spike: hot apply + client routes on GNOME 46 (headless nested shell): does gnome-shell connect to a non-ibus broker via the address file without restart; which route gnome-terminal, Chrome, VS Code take on this machine (fcitx module / text-input-v3 / XIM); record the exact IBus calls gnome-shell makes; prove Mutter RemoteDesktop key injection works headless | be | - | - | AC-5, D4, D8, D9, D12, SEC-29 | `.ai-dev-team/workspace/03_spike.md`, throwaway code in `.ai-dev-team/workspace/qa-artifacts/T1/` only | report with commands + output | done | 0 |
| T2 | Scaffold Cargo workspace (all crates, frontend `run` stubs, main wiring) + `telex-core` engine, TDD | be | - | - | TOOL, AC-1, SEC-25, SEC-26, SEC-27 | `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `crates/*/Cargo.toml`, `crates/*/src/lib.rs` (stubs), `crates/vr-talex/src/main.rs`, `crates/telex-core/**`, `.gitignore`, `README.md` | `cargo test -p telex-core`, `cargo clippy --workspace -- -D warnings` | done | 0 |
| T3 | Independent Telex golden list (≥ 2,000 cases) from a public Vietnamese syllable list + own reverse function word→keys, plus English passthrough words | be | - | - | AC-1, D13 | `crates/telex-core/tests/golden/telex_golden.tsv`, `crates/telex-core/tests/golden/README.md`, generator in `tools/golden-gen/` | file format check; T2's golden test reads it | done | 1 |
| T4 | `ime-core`: contexts, serial pipeline, global mode + StateStore, Ctrl+Shift tap detector, preedit/commit/surrounding policy, never-drop on focus-out/reset, password passthrough | be | T2 | security | AC-3, AC-4, AC-7, AC-8, AC-10, D6, D7, D10, SEC-1, SEC-2, SEC-3, SEC-4, SEC-5, SEC-12, SEC-13, SEC-17, SEC-18, SEC-27 | `crates/ime-core/**`, `crates/vr-talex/src/main.rs` (hardening, state store, watchdog only) | `cargo test -p ime-core` | in-progress | 0 |
| T5 | `fe-ibus`: private mini broker + IBus service/engine/input context + panel InputMode property + address file | be | T1, T4 | security | AC-2, AC-3, AC-4, AC-5, AC-9, D6, D8, SEC-1, SEC-2, SEC-4, SEC-6, SEC-7, SEC-8, SEC-9, SEC-10, SEC-11, SEC-12, SEC-13, SEC-15, SEC-16, SEC-27 | `crates/fe-ibus/**` (worktree) | `cargo test -p fe-ibus` + gnome-shell headless smoke from T1 | todo | 0 |
| T6 | `fe-fcitx`: fcitx5 D-Bus frontend (InputMethod1 / InputContext1, portal name) | be | T1, T4 | security | AC-2, AC-3, AC-5, AC-7, AC-9, D8, SEC-1, SEC-2, SEC-4, SEC-8, SEC-9, SEC-12, SEC-13, SEC-15, SEC-16, SEC-27 | `crates/fe-fcitx/**` (worktree) | `cargo test -p fe-fcitx` + fcitx5-gtk client smoke | todo | 0 |
| T7 | `fe-xim`: XIM server (only if T1 shows an XIM route is used) | be | T1, T4 | security | AC-2, AC-9, D8, SEC-1, SEC-2, SEC-4, SEC-9, SEC-14, SEC-15, SEC-16, SEC-27 | `crates/fe-xim/**` (worktree) | `cargo test -p fe-xim` + xterm smoke | cancelled (T1: no app uses XIM; D19) | 0 |
| T8 | `install.sh` / `uninstall.sh` + systemd user unit + environment.d + fcitx5 hand-over + gsettings source + backups/restore, idempotent | be | T1, T2 | security | AC-5, AC-6, D1, D9, D11, SEC-3, SEC-17, SEC-19, SEC-20, SEC-21, SEC-22, SEC-23, SEC-24, SEC-28 | `install.sh`, `uninstall.sh`, `packaging/**`, `tests/install/**` | script tests with temp HOME + `GSETTINGS_BACKEND=keyfile` | todo | 0 |
| T9 | E2E stress harness: headless nested gnome-shell, RemoteDesktop key injection at 15 ms, gnome-terminal / Chrome (CDP) / VS Code readback, 5,000-word corpus, 3 runs per app, latency p99 | be | T1 | - | AC-2, AC-3, AC-4, AC-5, AC-6, AC-7, AC-10, D12, SEC-1, SEC-29 | `tests/e2e/**` | `tests/e2e/run.sh --smoke` | todo | 0 |
| T10 | Free-order circumflex and đ (aa/ee/oo, dd non-adjacent, D18) + golden regeneration + T2 re-check nits | be | T2, T3 | - | AC-1, D18, SEC-2, SEC-4 | worktree ../vr-talex-wt-T10: `crates/telex-core/src/**`, `crates/telex-core/tests/rules.rs`, `crates/telex-core/tests/golden/**`, `tools/golden-gen/gen.py` | `cargo test -p telex-core` | in-progress | 0 |

## Notes
presence: present (user typed, 19:54)
hand-off: ready (19:52)
fable-policy: auto (user, 19:15) — Fable (case 3 high-risk + complex) for T4 (concurrency), T5 (protocol broker + security); case 2 (real-environment only) for T1
commits: local, one per task, no push (user, 19:15)
after-plan: build without waiting (user, 19:15) — overrides greenfield plan gate
unattended phase5: Agent tool, no Workflow
decisions: see decisions.md (D1, D9 confirm-on-return; D14, D15 user)
route: greenfield, plan-only request ("lên plan") extended to build by the user's hand-off answer
phase0: paths ✓ · profile — (greenfield, Phase 1 after T2 scaffold) · stray-team-files ✓ · gitignore ✓ · rust ✓ (rustc 1.100.0, cargo in ~/.cargo/bin, not on PATH of non-login shells) · commit identity ✓ (repo-local user.email = mvanvu account, set by user 19:38; 7024d2a rewritten as a2777e1 by user request)
parallel: T1 ∥ T2 ∥ T3 — files disjoint (T1 only team files; T3 only tests/golden + tools/golden-gen; T2 owns Cargo.lock — T3 adds no crate until T2 committed: generator is a standalone script, not a workspace member)
parallel later: T5 ∥ T6 ∥ T7 each in its own worktree (shared compile unit + Cargo.lock); merge order T5 → T6 → T7. T8 ∥ T9 on main tree (files disjoint from crates/).
waiting: T5, T6 (T4)
eta: ~01:50 (set 19:22, basis: critical path T1∥T2 90 min → T4 60 → T5 120 → e2e run + fixes 90 → sign-off + Phase 5 60; max_agents 5)
follow-up nits (T2 re-check, minor, not blocking): telex-core lib.rs:194-203 Undone→Viet resume can report Composing on unparsable letters (`tw n w <`); lib.rs:210 Raw-branch `keys` Vec not wiped (SEC-4 best effort) — to ride along the next telex-core change or go in the report.
worktree: T10 → ../vr-talex-wt-T10 (branch t10-free-order, from 8bb3a65). T10a engine (opus) ∥ T10b golden (sonnet) in that worktree, files disjoint (src+rules.rs vs tests/golden + tools/golden-gen). Merge into master after T4 is committed; T4 does not touch crates/telex-core.
