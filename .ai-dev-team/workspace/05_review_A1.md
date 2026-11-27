# Review A1 (code + security): verify the rename and migration at HEAD e14cbc2. Verdict: CHANGES_REQUESTED

Tools available: Read, Bash (read-only git/grep), Write (this file only), Skill, SendMessage, SubagentHandback.
SEC-19..24 source: `.ai-dev-team/workspace_20261127-1422/02_threat-model.md` lines 77-82. They are not in `01_spec.md`. That threat model already uses the vr-telex names; its SEC-24 is "no remote code at install".
Prior review of the same code: `workspace_20261127-1730-local/05_review_FR-13.md` (APPROVED after round 1). Its fixes are present at HEAD (`KEEP_SNAP`, binary never taken as ours without a record, guarded `rm` in `legacy_cleanup`, `gs_put` on rollback).

## AC-1 / leftovers
- `git grep -n -i -E 'vr.talex|VR_TALEX' -- ':!.ai-dev-team'` finds hits only in install.sh, uninstall.sh and packaging/common.sh (all of them legacy/migration code or its comments), in tests/install/run.sh (legacy scenarios and helpers), in tests/install/stubs/fake-ime (the `vr-talex` role) and in tests/install/legacy/** (byte-identical to `git show de15649:` for all 7 files, checked with cmp). README.md:38-47 is the "Upgrading from vr-talex" note that AC-7 requires.
- No old name in crates/ or tools/. The EN-DETECT and undo commits after abac0f3 (311dbe0..5508196) brought back no old names (`git grep -i talex` outside the migration files returns nothing).
- No stray tracked files: no `__pycache__`, `.pyc`, `target/`, logs, `.deb`, backups or submodules. `.gitignore` has `/target` and `__pycache__/`.

## Findings

[major] install.sh:543-545 → install.sh:298-347 (`select_source` → `reselect_source` runs after `migrate_live`). AC-2 "keeping the current selection" is not met.
Scenario: the vr-talex install has sources `[('xkb','us'), ('ibus','vr-talex')]` and the user's current source is English (mru-sources `[('xkb','us'), ('ibus','vr-talex')]`). `legacy_rename_sources` keeps the order. Then `reselect_source` sees that mru-sources does not start with vr-telex and moves vr-telex to the head. After the upgrade the active source has switched to Vietnamese (Telex), although the user had English selected. The user's real machine had vr-talex at the head, so it is not affected.
Fix: in `migrate_live`, record whether the legacy source was the head of mru-sources before the rename. When MIGRATING and it was not, skip `select_source`/`reselect_source`; D33/D34 only needs vr-telex at the head when vr-talex was the current source. Alternatively, the leader amends AC-2 if putting vr-telex first on every install should win.

[major] tests/install/run.sh:951-1008, 1063-1094: "same position" and "keeping the selection" are not proven.
Scenario: every migration scenario has vr-talex as the last entry of `sources` and the head of `mru-sources`. That is exactly what a fresh `select_source` produces, so a broken implementation that dropped vr-talex and appended vr-telex would pass all checks.
Fix: add `t_legacy_source_order`: legacy install, then set sources `[('ibus','vr-talex'), ('xkb','us'), ('xkb','fr')]` and mru `[('xkb','us'), ('ibus','vr-talex'), ('xkb','fr')]`. After install, expect sources `[('ibus','vr-telex'), ('xkb','us'), ('xkb','fr')]` with the mru head still `('xkb','us')` (this also covers the first finding). Uninstall then restores the keyfile byte for byte.

[major] packaging/common.sh:731-741 (runtime dir and IBus address-file cleanup) is never exercised by a test (AC-2 "Proven by tests/install scenarios").
Scenario: tests/install/stubs/fake-ime:62-91 never creates `$XDG_RUNTIME_DIR/vr-talex`. It removes its own address file on SIGTERM, and it uses the same file name (`<mid>-unix-wayland-0`) as the new daemon, which overwrites that file. Neither the `grep -qF "IBUS_ADDRESS=unix:path=$LEGACY_RUNTIME_DIR/"` branch nor the `ibus.lock`/`ibus`/rmdir branch ever runs. A regression there would leave a stale address file for another display (for example an X11 `-unix-:0` file after a crash) pointing IBus clients at a dead socket, and no test would fail.
Fix: add a scenario that plants `~/.config/ibus/bus/<mid>-unix-:1` holding `IBUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/vr-talex/ibus`, plus `$XDG_RUNTIME_DIR/vr-talex/{ibus.lock,ibus}` and one foreign file in that dir. After install, assert that the address file and the two entries are gone, the foreign file and the dir are kept, and an address file of another daemon is untouched. Repeat through the `uninstall_legacy` path.

[major] tests/install/run.sh: "no overwrite of newer data" is unproven for the mode file (install.sh:504 `! exists "$DAEMON_STATE_DIR/mode"`).
Scenario: no scenario has `~/.local/state/vr-telex/mode` present before the migration. The guard looks correct, but nothing would catch its removal, and then the vr-talex EN would silently replace a newer vr-telex VI.
Fix: in a variant of `t_legacy_both_dirs`, write `vr-telex/mode=VI` and `vr-talex/mode=EN` before install. Expect VI afterwards, and the vr-talex mode file removed.

Not filed: the packaged `vr-telex-setup` does not exist yet, so AC-2 "packaged setup alike" is for A2/A3, which must call the same `plan_migration`/`migrate_live`/`migrate_commit` path and run the legacy scenarios against it. The `vr-telex:` prefix comes from the single `say`/`warn`/`die` helpers (common.sh:23-27). Tests match the message text, not the prefix.

## Rule check A1
| Rule | Result | Evidence |
|---|---|---|
| AC-1 | pass | grep hits only in migration code, its legacy fixture and tests, and the README migration note (AC-7); crate `crates/vr-telex`, unit/env/source/`VR_TELEX_*`/APP_DIR all new; no stray tracked files |
| AC-2 stop+disable vr-talex.service | pass | common.sh:575 `disable --now`; `legacy_migrate` checks the stub call log and the old pid exit |
| AC-2 remove unit, binary, env file | pass | `legacy_retire_file` (ours only); `legacy_files_gone`, `legacy_foreign_file`, `foreign_legacy_name_only` |
| AC-2 remove runtime address files / runtime dir | fail (unproven) | code common.sh:731-741 correct by reading; no test reaches it (finding 3) |
| AC-2 move backup, no overwrite of newer | pass | copy + rewrite + `mv -T`; `legacy_both_dirs` keeps both, sha256 identical |
| AC-2 move mode, no overwrite of newer | fail (unproven) | install.sh:504 guard; the carry-over is tested, the newer-wins case is not (finding 4) |
| AC-2 source replaced at same position | fail (unproven) | in-place rename common.sh:585-601; tests cannot tell it from append (finding 2) |
| AC-2 keeping the current selection | fail | `reselect_source` after migration moves vr-telex to the mru head (finding 1) |
| AC-2 idempotent | pass | `legacy_migrate` second run: snapshot and keyfile identical, no vr-talex calls; `legacy_both_dirs` |
| AC-2 uninstall restores pre-first-install | pass | `legacy_migrate`, `legacy_rollback`, `uninstall_legacy`: snapshot and keyfile identical to before vr-talex |
| AC-2 old backup never deleted before moved | pass | deleted only in `migrate_commit` after the health check and only with the `from-vr-talex` marker; `legacy_rollback` |
| AC-2 logged `vr-telex:` messages | pass | single `say`/`warn`/`die` helpers, common.sh:23-27 |
| AC-2 packaged setup | n-o | `vr-telex-setup` not in tree yet (A2/A3) |
| SEC-19 | pass | sources renamed in `migrate_live` before `start_daemon`; rollback restores sources first (install.sh:420-424); `legacy_rollback` |
| SEC-20 | pass | `require_user` refuses root; no sudo/pkexec; `systemctl --user` only |
| SEC-21 | pass | backup copied once and never overwritten; exact restore proven by the scenarios above |
| SEC-22 | pass | idempotent re-run after migration; source renamed, never duplicated |
| SEC-23 | pass | `set -euo pipefail`; every `rm -rf` target is `${DATA_HOME:?}`/`${MIG_SNAP:?}`/`${tmp:?}`; no pkill/killall; shellcheck n-o |
| SEC-24 | pass | no curl/wget/rustup; `cargo build --release --locked` from the local checkout |

## Files read
| File | Status |
|---|---|
| install.sh | read (migration section 370-560, select/reselect) |
| uninstall.sh | read (main) |
| packaging/common.sh | read (paths 80-105, legacy section 516-757) |
| tests/install/run.sh | read (run_all, snap, helpers, legacy scenarios 920-1290) |
| tests/install/stubs/fake-ime | read |
| tests/install/legacy/** | skipped — cmp-identical to de15649 |
| crates/fe-ibus/src/address.rs | read (APP_DIR, address format) |
| README.md | read (38-47) |

REVIEW_FAIL

## Re-check round 1 — APPROVED

Read: `git diff -- install.sh packaging/common.sh tests/install/run.sh` (working tree vs e14cbc2) and `04_dev_A1.md` round 1. The developer reports 44 install scenarios with 0 failed, the red run for finding 1 on the old code, and red runs for findings 3 and 4 on a mutated copy. I did not rerun them.

| # | Finding | Status | Evidence |
|---|---|---|---|
| 1 | selection not kept | fixed | common.sh `legacy_was_current` is read in `migrate_live` before the rename. `MIG_KEEP_SELECTION=1` only when vr-telex ends up listed and vr-talex was not current, and then `main` skips `select_source`. `legacy_source_order` checks that mru-sources stays `[us, vr-telex, fr]` |
| 2 | same position unproven | fixed | `legacy_source_order`: vr-talex at index 0 of 3 → `[('ibus','vr-telex'), us, fr]`. `legacy_migrate` still covers the last position |
| 3 | runtime/address cleanup unexercised | fixed | `legacy_runtime_cleanup` covers a stale `-unix-:1` file, lock and socket, a foreign file and dir kept, and another daemon's address file kept. `uninstall_legacy_runtime_cleanup` covers the same through uninstall. On the uninstall path, `restore_all` also removes the address file, so only the lock and socket checks tell the cases apart there (the developer said so) |
| 4 | newer mode unproven | fixed | `legacy_newer_mode`: VI kept and the vr-talex mode file removed |

Points the leader asked me to judge:
- (a) `legacy_was_current` is correct for AC-2. The current source is the head of mru-sources. When mru-sources is empty (`[]` or `@a(ss) []`), gnome-shell activates the head of sources, and the function checks that instead.
  - vr-talex not listed: the flag stays 0, so `select_source` adds vr-telex the way a fresh install does. Nothing is replaced, so AC-2's "replace at the same position" does not apply.
  - vr-telex already listed and current: it counts as current, so the D33/D34 reselect path runs unchanged.
  - mru-sources holds no vr-talex but sources does: correctly "not current".
  - Upper-case ids: not reachable. Engine ids are case-sensitive, and gsettings prints the fixed `('ibus', 'vr-talex')` form that the rest of common.sh already matches.
  - A read failure returns "not current", and the next `gs_get` in `legacy_rename_sources` then dies into the rollback.
  - The flag changes no key, so the rollback needs nothing extra.
  - Skipping `select_source` loses no record: `reselect_source` never writes `installed.gs`.
- (b) Acceptable. pre_state_fcitx5 starts at `[('xkb','us')]`. The test then adds `('xkb','fr')` and reorders both lists, which is a user edit made after the vr-talex install. Keeping the user's lists minus vr-telex is the existing `gs_restore` design (FR-9, `reselect_keeps_user_edits`; SEC-21 "removes only what install created"). The byte-identical restore for the case with no user edits is still proven by `legacy_migrate`, `legacy_rollback` and `uninstall_legacy`.
- (c) Outside AC-2. AC-2 describes what the migrating install does, and a later rerun of `./install.sh` is the FR-9/D33 rerun rule (`reselect_on_rerun`). It conflicts only if the leader reads "keeping the current selection" as covering every later run. That is the user's call; it is not a defect in this task.

New, minor (not blocking): install.sh:504-506 reads `legacy_was_current` after `legacy_stop_unit`.
- Scenario: the shell rewrites mru-sources between the stop and the read, so vr-talex looks not current and vr-telex is not put first. The user who had Vietnamese selected then finds another source current.
- This is unlikely: gnome-shell's `_updateMruSettings` does not write while IBus is not ready, and that is the state once vr-talex stops. I could not confirm this against the installed shell (uncertain).
- Fix: swap the two lines, so the read comes before the stop.

## Rule check A1 (round 1)
| Rule | Result | Evidence |
|---|---|---|
| AC-1 | pass | diff adds old names only in legacy tests and migration code |
| AC-2 stop/disable, remove unit/bin/env | pass | unchanged; `legacy_runtime_cleanup` and `legacy_newer_mode` also call `legacy_files_gone` |
| AC-2 runtime address files / dir | pass | `legacy_runtime_cleanup`, `uninstall_legacy_runtime_cleanup` (mutation red reported) |
| AC-2 backup moved, no overwrite | pass | unchanged (`legacy_both_dirs`) |
| AC-2 mode moved, no overwrite of newer | pass | `legacy_newer_mode` (mutation red reported) |
| AC-2 same position | pass | `legacy_source_order` (index 0), `legacy_migrate` (last) |
| AC-2 keeping the current selection | pass | `legacy_was_current` + `MIG_KEEP_SELECTION`; `legacy_source_order` red→green; selected-vr-talex path unchanged (`legacy_migrate` `started_with_vr_head`) |
| AC-2 idempotent | pass | unchanged (`legacy_migrate` second run) |
| AC-2 uninstall restores pre-first-install | pass | unchanged byte-identical scenarios; user edits kept by design (point b) |
| AC-2 old backup not deleted before moved | pass | unchanged |
| AC-2 `vr-telex:` messages | pass | new message goes through `say` |
| AC-2 packaged setup | n-o | A2/A3 must use `migrate_live` (with `legacy_was_current`) |
| SEC-19 | pass | sources still renamed before `start_daemon`; rollback order unchanged |
| SEC-20 | pass | no privilege change |
| SEC-21 | pass | foreign runtime file and another daemon's address file kept |
| SEC-22 | pass | flag set only while migrating; rerun path unchanged |
| SEC-23 | pass | no new `rm` in the scripts; quoted expansions |
| SEC-24 | pass | no remote code |

REVIEW_PASS
