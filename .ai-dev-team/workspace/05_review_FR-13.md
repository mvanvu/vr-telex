# Review FR-13 (code + security) — CHANGES_REQUESTED

Scope: `git -C /home/rainy/DEV/vr-telex-wt-FR13 diff` + untracked files (worktree, branch fr13-rename from de15649).
Tools available: Read, Bash, Write, Skill, SendMessage, SubagentHandback.

## Walk of the user's real state (vr-talex.service active, sources [xkb us, ibus vr-talex], backup from de15649, fcitx5 purged)
preflight ok (vr-talex owns both names, so `ibus_daemon_running` is false) -> `legacy_found` (backup dir) -> `plan_migration`: snapshot, ROLLBACK=1, `legacy_copy_backup` (cp -a to a temp dir, rewrite, one `mv -T`; the vr-talex backup stays untouched) -> RERUN path, `install_files` (xinputrc/autostart/shadow equal the vr-talex records, so they are overwritten as ours) -> `migrate_live` (disable --now vr-talex, in-place rename mru then sources, mode copied) -> select/start/health -> `migrate_commit` (exact compare against `backup/installed/*`, then removal; backup removed last). Failure at any step before commit returns to the snapshot and starts vr-talex again; the vr-talex backup is never written before commit. Templates match the de15649 ones byte for byte after the name swap; the fixture under tests/install/legacy matches `git show de15649:` byte for byte; crates/vr-telex equals the old crate with only the name swapped. Engine name, runtime dir, state dir, unit, SystemdService= and the source string all agree. I found no data-loss path for the user's real machine.

## Findings

[medium / major] packaging/common.sh:544 (used by :554 `legacy_found`, :705 `legacy_retire_file`, uninstall.sh:73-75 and :85) — CWE-706: a user file is deleted because its name is ~/.local/bin/vr-talex and it contains the text "vr-talex" (SEC-21 "removes only what install created"; the brief calls this SEC-24)
Scenario: there is no vr-talex backup (vr-telex was installed fresh, or there was never any install) and the user has their own wrapper `~/.local/bin/vr-talex` containing `exec "$HOME/src/vr-talex/target/release/vr-talex" "$@"`. Probe `$TEAM_WS/qa-artifacts/FR-13/weak_bin_probe.sh` (temp HOME) prints `legacy_is_ours: YES`, `legacy_found: YES`. With a vr-telex install, `./install.sh` then migrates and `migrate_commit -> legacy_cleanup -> legacy_retire_file` runs `rm -f` on the wrapper. Without one, `./uninstall.sh` takes the `legacy_found` branch, and `legacy_cleanup 0` deletes it. Both say "removed" or "moved" and give no warning. The test `foreign_legacy_name_only` only uses `echo mine`, so it misses this case.
Fix: without a record, never count the binary as ours by its content. Two options: (a) make it ours only when `head -c4` is `\x7fELF` and the vr-talex unit file is also ours by template (its ExecStart names this path); (b) drop the binary from the `legacy_found` probes and leave an unrecorded binary in place with the existing "not the file vr-talex installed" warning. Add the wrapper-script case to `foreign_legacy_name_only`, both with and without an existing vr-telex install.

[minor] install.sh:60 — `on_exit` deletes MIG_SNAP even when `restore_legacy` returned 1.
Scenario: during rollback, `replace_with` fails for ~/.xinputrc or the D-Bus shadow (for example, the disk is full). The output says "rollback is incomplete", and the only pre-run copy is deleted with the snapshot. The vr-talex backup's `installed/` copy still holds the same content, so this can be recovered by hand, but the script does not say so.
Fix: keep MIG_SNAP when `restore_legacy` fails, and print its path.

[minor] packaging/common.sh:745 — `legacy_cleanup` is documented as "Never fails; problems are warnings", but its bare `rm -rf` runs under `set -e` (migrate_commit is not called in a condition context).
Scenario: a file in ~/.local/share/vr-talex/backup cannot be removed. install.sh then exits non-zero after a successful health check, without the "installed" line, and leaves `from-vr-talex` in place. The next run recovers.
Fix: `rm -rf -- … || warn "could not remove $LEGACY_BACKUP"`.

[minor] install.sh:418 — `restore_legacy` runs `gsettings set` for both keys even when the value is the schema default or unchanged. A key the user never set (often `mru-sources`) ends up set explicitly after a rollback.
Fix: skip the write when the current value equals the snapshot value, and use `gs_put` (reset for default values).

Not filed as findings: after a rollback, an IBus address file the failed vr-telex daemon wrote under a different display name, and the `$XDG_RUNTIME_DIR/vr-telex` dir, can stay behind (tmpfs, ignored once vr-talex rewrites its own file). The threat model still names vr-talex paths in SEC-21/SEC-22 (the developer noted this; it is for the leader to update).

## Rule check FR-13
| Rule | Result | Evidence |
|---|---|---|
| AC-5 | pass | migration installs and starts without logout: `migrate_live` before `start_daemon`, `legacy_migrate` checks `started_with_vr_head`; real session: n-o (qc) |
| AC-6 | pass | 2nd run takes the normal re-run path (nothing legacy is left); uninstall uses the rewritten manifest; `legacy_migrate`, `uninstall_legacy` byte-identical snapshots |
| D37 | pass | `git grep -i talex` outside .ai-dev-team: only README upgrade section, legacy code in install/uninstall/common.sh, tests, fake-ime role, frozen fixture; crate equals old crate with name swapped |
| D11 | pass | backup copied and rewritten (`legacy_rewrite_backup` refuses unknown entries); only user-level paths |
| D31 | pass | rollback returns to vr-talex (`restore_legacy`), not to fcitx5; `legacy_rollback` asserts unit active+enabled and name owner |
| D33/D34 | pass | in-place rename keeps order (`legacy_renamed_sources`), mru renamed before sources, daemon restarted after `select_source` |
| SEC-19 | pass | sources renamed in `migrate_live` before `start_daemon`; rollback restores gsettings first (install.sh:417-419) |
| SEC-20 | pass | no sudo/pkexec; writes under HOME/XDG-in-HOME; `systemctl --user` only |
| SEC-21 | fail | backup before change and exact restore are correct, but the weak binary check deletes a user file (finding 1) |
| SEC-22 | pass | re-run after migration is a no-op on legacy state (`legacy_migrate`, `legacy_both_dirs`, `legacy_foreign_file`) |
| SEC-23 | pass | every `rm -rf` uses `${DATA_HOME:?}/…`, `${tmp:?}` or `${MIG_SNAP:?}` (mktemp); expansions quoted; no pkill. shellcheck: n-o (not installed) |
| SEC-24 (threat model: no remote code) | pass | no curl/wget/rustup; `cargo build --locked` local only |
| SEC-24 (brief: never delete non-ours) | fail | see SEC-21 row and finding 1 |
| BASE-16 | pass | reuses `replace_with`, `same_entry`, `without_source`, `remove_created_dirs` |
| BASE-3/4 | pass | notes carry red/green and outputs (37/37, cargo test, fmt/clippy) |

## Files read
| File | Status |
|---|---|
| .gitignore | read |
| Cargo.toml | read |
| Cargo.lock | read (one `name =` line) |
| README.md | read |
| crates/fe-fcitx/src/lib.rs | read |
| crates/fe-ibus/src/address.rs | read |
| crates/fe-ibus/src/ibus.rs | read |
| crates/fe-ibus/src/lib.rs | read |
| crates/fe-ibus/tests/address.rs | read |
| crates/fe-ibus/tests/common/mod.rs | read |
| crates/fe-ibus/tests/protocol.rs | read |
| crates/fe-xim/src/lib.rs | read |
| crates/ime-core/src/state.rs | read |
| crates/ime-core/tests/state_store.rs | read |
| crates/vr-telex/Cargo.toml | read (diffed vs old crate with name swap: identical) |
| crates/vr-telex/src/main.rs | read (diffed vs old crate with name swap: identical) |
| install.sh | read |
| uninstall.sh | read |
| packaging/common.sh | read |
| packaging/vr-telex.service | read (template parity vs de15649) |
| packaging/90-vr-telex.conf | read (template parity vs de15649) |
| packaging/org.fcitx.Fcitx5.desktop | read |
| packaging/org.fcitx.Fcitx5.service | read |
| packaging/xinputrc | read |
| tests/e2e/README.md | read |
| tests/e2e/install_scenario.sh | read |
| tests/e2e/lib.sh | read |
| tests/e2e/run.sh | read |
| tests/e2e/stub_ime.py | read |
| tests/install/run.sh | read (legacy scenarios and helpers) |
| tests/install/stubs/fake-ime | read |
| tests/install/stubs/broken-vr-telex | read |
| tests/install/legacy/** | skipped — byte-exact copies of de15649 files (verified with cmp against `git show de15649:`) |
| tests/install/stubs/__pycache__/fake-imecpython-312.pyc | skipped — deleted build artifact |

## Re-check round 1 — APPROVED

Read: install.sh (on_exit/KEEP_SNAP, restore_legacy gs loop), packaging/common.sh (legacy_is_ours, legacy_found, legacy_retire_file, legacy_cleanup), tests/install/run.sh (foreign_legacy_name_only, legacy_without_backup, legacy_rollback_restore_fails, legacy_backup_rm_fails, legacy_rollback_default_key).

| # | Finding | Status | Evidence |
|---|---|---|---|
| 1 | weak ownership check for an unrecorded ~/.local/bin/vr-talex | fixed | content rule removed (common.sh:545-549); `legacy_retire_file` warns and leaves an unrecorded binary; probe with systemctl stubbed (`qa-artifacts/FR-13/weak_bin_probe2.sh`): `legacy_is_ours: no`, `legacy_found: no`, `wrapper kept`; `foreign_legacy_name_only` covers uninstall-only and install->uninstall with the wrapper |
| 2 | snapshot deleted after a failed restore_legacy | fixed | `KEEP_SNAP=1` + path printed (install.sh:46-47, :64); `legacy_rollback_restore_fails` |
| 3 | bare `rm -rf` under set -e in legacy_cleanup | fixed | `if rm -rf …; then … else warn` (common.sh:748-752); other removals `|| warn`; `legacy_backup_rm_fails` exits 0 |
| 4 | rollback writes keys at default | fixed | skip-unchanged + `gs_put` (install.sh:424-425); `legacy_rollback_default_key` keyfile byte-identical |

Nothing new opened: with a backup record the binary check is still the exact compare (real-machine path unchanged); unit/env keep full-file template compare; a kept snapshot lives in `$DATA_HOME/.vr-telex-migrate.*` and does not affect the next run (new mktemp).
Install suite run once by the reviewer: 40 scenarios, 0 failed (`qa-artifacts/FR-13/review-r1-install-suite.log`).

Note (not blocking): the new test comments start with "Review FR-13 minor N" — review history in code comments; the leader may ask to drop that prefix.

## Rule check FR-13 (round 1)
| Rule | Result | Evidence |
|---|---|---|
| AC-5 | pass | unchanged; suite 40/0 |
| AC-6 | pass | unchanged; `legacy_migrate`, `uninstall_legacy` pass |
| D37 | pass | unchanged |
| D11 | pass | unchanged |
| D31 | pass | rollback to vr-talex; `legacy_rollback`, `legacy_rollback_default_key` |
| D33/D34 | pass | unchanged |
| SEC-19 | pass | rollback keyfile byte-identical incl. default key |
| SEC-20 | pass | unchanged |
| SEC-21 | pass | unrecorded binary never deleted (probe2, `foreign_legacy_name_only`); kept snapshot on failed rollback |
| SEC-22 | pass | unchanged |
| SEC-23 | pass | no `rm` whose failure aborts after commit; quoted, `:?`-guarded targets. shellcheck n-o (not installed) |
| SEC-24 (threat model: no remote code) | pass | unchanged |
| SEC-24 (brief: never delete non-ours) | pass | as SEC-21 |
| BASE-3 | pass | red copies in qa-artifacts/FR-13/pre/out; green 40/0 |
