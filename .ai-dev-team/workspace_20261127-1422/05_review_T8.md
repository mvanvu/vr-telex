# Review T8: install.sh / uninstall.sh / packaging / tests/install

Verdict: **CHANGES_REQUESTED** (2 blocker, 4 major, 3 minor)

Tools available to the reviewer: Read, Bash (read-only use), Write (this report only), Skill, SendMessage, SubagentHandback.

## Files read
| File | Status |
|---|---|
| install.sh | read |
| uninstall.sh | read |
| packaging/common.sh | read |
| packaging/vr-talex.service | read |
| packaging/90-vr-talex.conf | read |
| packaging/org.fcitx.Fcitx5.service | read |
| packaging/org.fcitx.Fcitx5.desktop | read |
| packaging/xinputrc | read |
| tests/install/run.sh | read |
| tests/install/stubs/* | skipped (test doubles; their behavior is checked through the run.sh assertions) |
| 04_dev_T8.md, qa-artifacts/T8/run.log | read |

`bash -n` passes for install.sh, uninstall.sh, packaging/common.sh and tests/install/run.sh. Greps: no sudo, pkexec, curl or wget, and no stop-by-name. The only `/etc/` hit is a read-only os-release default. Every `rm` was traced (the list is below).

## Findings

### [blocker] packaging/common.sh:266-268 + :311: a failed restore still deletes the only backup
Scenario: uninstall (or install rollback) → `rm -f ~/.xinputrc` (266) → `cp -a backup/files/.xinputrc ~/.xinputrc` fails (ENOSPC, EACCES, or a backup file that is missing or unreadable) → only a `warn` → line 311 runs `rm -rf …/backup`. The user's original ~/.xinputrc, environment file or IBus address file is gone and the script exits 0. The header's "best effort" (234-236) makes this worse: one failed step does not stop the backup from being deleted.
Fix: restore into `mktemp "$dir/.vr-talex-tmp.XXXXXX"` and then `mv -f` onto dst, with no `rm` first. Count failures in restore_all (gs_restore, cp, mkdir). If any step failed, keep the backup, print its path and exit non-zero. Add a test: make one backup file unreadable, then assert that uninstall exits non-zero and the backup is still there.

### [blocker] packaging/common.sh:252-269: uninstall deletes or overwrites files the user changed after install
Scenario A: no ~/.xinputrc before install (manifest `absent`) → install writes `run_im none` → the user later runs `im-config -n fcitx5` or edits the file → uninstall runs `rm -f ~/.xinputrc` (257) and the user's file is lost. Scenario B: ~/.xinputrc existed before → the user edits it after install → uninstall replaces it with the old backup (266-268) and the edits are lost with no message. The same applies to 90-vr-talex.conf and the autostart override.
Fix: when installing, store a copy of what install wrote (`backup/installed/<rel>`). On uninstall, a dst whose content differs from that copy is user-modified: move it to `<dst>.vr-talex-saved-<date>` (or leave it in place and skip the restore), then warn and name the path. Add a test for each of the absent and present cases.

### [major] install.sh:90 + :254: re-install after the backup dir was removed records vr-talex's own files as the "original"
Scenario: install → the user deletes ~/.local/share/vr-talex (the case the dev's `uninstall_without_backup` test models) → `./install.sh` again → `backup_state` snapshots the installed state: `.xinputrc` = `run_im none`, autostart `Hidden=true`, 90-vr-talex.conf, bin and unit are all recorded `present`, and fcitx5 is recorded as `none` because vr-talex owns the name. Uninstall then "restores" all of them. fcitx5 stays hidden from login and is never restarted, the binary and unit stay on disk, and the script prints "previous input method setup is restored".
Fix: in backup_state, refuse when BIN_DST or UNIT_DST exists, or when a managed file equals its packaging template, with this message: "vr-talex is installed without a backup; run ./uninstall.sh first". The alternative is to record those files as `absent`.

### [major, uncertain] packaging/common.sh:243 with install.sh:111-112: input sources restored in the reverse of the order install relies on
install.sh:237-240 sets `mru-sources` before `sources` because gnome-shell activates the MRU head when `sources` changes. The manifest stores `sources` first, so restore sets `sources` while the MRU head is still the removed vr-talex entry. The shell then picks a source itself and saves its own MRU, which races the script's `mru-sources` write. The previous selection may not be re-selected live, and the persisted MRU may be the shell's. The keyfile test cannot show this (no shell runs).
Fix: in restore_all, restore `mru-sources` first, then `sources`. Confirm in T9.

### [major] packaging/common.sh:160-169: uninstall drops input sources the user added after install
Scenario: install → the user adds `('xkb','fr')` in Settings → uninstall resets `sources` to the pre-install list and `fr` silently disappears. This is the gsettings form of the second blocker.
Fix: if the current value equals what install set, restore the saved value. Otherwise remove only `('ibus', 'vr-talex')` from the current list. Either result meets AC-6.

### [major] tests/install/run.sh: data-safety paths not tested
Not covered: a file edited after install, a failed restore, ~/.xinputrc or ~/.config as a symlink, fcitx5 as a systemd unit (the `unit` branch of hand_over_fcitx5 and restore_all never runs), fcitx5 not quitting within the timeout (rollback while fcitx5 is still alive), and re-install with the backup dir removed. My static trace of the symlink cases is fine: `cp -a` keeps the link, the `mv` replaces the link without writing through to its target, and restore re-creates the link. That trace is still unproven.
Fix: one scenario each (the fcitx5 and systemctl stubs already exist).

### [minor] install.sh:157, uninstall.sh:25: `${svc//@BIN@/$BIN_DST}` under bash 5.2 patsub_replacement
A HOME that contains `&` gives `Exec=/home/a@BIN@b/...` (verified on this bash 5.2.21). Fix: `${svc//@BIN@/"$BIN_DST"}`.

### [minor] packaging/common.sh:36-38: tab and newline are checked only in HOME
XDG_CONFIG_HOME, XDG_DATA_HOME and XDG_STATE_HOME can contain a tab or a newline, which corrupts the tab-separated manifest. Fix: apply the same `case` check to CONFIG_HOME, DATA_HOME and STATE_HOME in init_paths.

### [minor] install.sh:254-261: a failed re-run removes a working install
A re-run (manifest present, ROLLBACK=1) that fails transiently, for example a slow daemon start that passes TIMEOUT, rolls back everything. This is safe under SEC-19, but the message should say that the earlier install was removed and that `./install.sh` can be run again.

## rm audit
Every `rm` target is built from a validated HOME or XDG path, is quoted, and uses `--`. Both `rm -rf` targets are `"${DATA_HOME:?}/vr-talex/backup"`. backup_state refuses a symlinked STATE_DIR or BACKUP_DIR. The deletions that lose data are the two in the blocker findings (common.sh:257 and :266 followed by :311).

## What the tests prove, and what is still open
They prove, at the file and keyfile level in the sandbox: the source is added once and is first in the MRU; a second run is byte-identical; uninstall gives the same snapshot and keyfile as before install when nothing changed in between; a broken daemon is rolled back; root and a missing cargo are refused; the activation shadow works. Still open for T9 and the user's run (O1): typing within 5 s in a real terminal and in Chrome, gnome-shell's live reaction to the source order, the unit hardening under the real user manager (IPAddressDeny, SystemCallFilter), the READY=1 timing against `enable --now`, and stock Ubuntu with ibus (D23).

## Rule check T8
| Rule | Status | Evidence |
|---|---|---|
| AC-5 | pass (file/keyfile) | fresh_fcitx5 checks a single entry, the MRU head and a byte-identical second run; live typing n-o (T9/O1) |
| AC-6 | pass (unchanged state only) | fresh_* snapshots; with user changes after install it fails (second blocker, gsettings finding) |
| D1 | pass | user-level script, `cargo build --release --locked` |
| D9 | n-a | superseded by D19 |
| D11 | pass | footprint matches the D11 list; quit request only |
| D19 | pass | health check needs the address file with the MainPID |
| D20 | pass | packaging/90-vr-talex.conf, xinputrc `run_im none` |
| D22 | pass | vr-talex.service:13-22 Type=notify, NotifyAccess=main, Restart=always, RestartSec=1, WatchdogSec=10, LimitCORE=0 |
| D23 | pass | install.sh:57-59 refuses when ibus is running; backup in ~/.local/share |
| SEC-3 | pass (unit side) | LimitCORE=0 |
| SEC-17 | pass | Restart=always, RestartSec=1, StartLimit 60 s/10 |
| SEC-19 | pass | sources set only after health_check; broken_daemon test; recovery printed |
| SEC-20 | pass | require_user; grep clean |
| SEC-21 | **fail** | backup deleted after a failed restore (first blocker); stale or "installed" backup (re-install finding) |
| SEC-22 | pass | single entry, dedicated env file, Hidden=true override + D-Bus shadow |
| SEC-23 | pass (shellcheck n-o) | set -euo pipefail, quoting, `${:?}` rm targets, no stop-by-name |
| SEC-24 | pass | no network; no_cargo test |
| SEC-28 | pass (static) | all required directives present; live enforcement n-o (T9) |
| Spike Q6.2 | pass (installer side) | health_check verifies the address file holds the MainPID; writing is T4 |
| Spike Q6.4 | pass | quit request → `timeout tail --pid` → no owner → start; never killed |
| Spike Q6.5 | pass | ~/.local/share/dbus-1/services shadow + ReloadConfig before quit; activation_shadow test; this machine starts fcitx5 through im-launch (no /etc/xdg/autostart fcitx5 entry), which the xinputrc covers |

---

# Re-check fix round 1

Verdict: **APPROVED** (all 9 findings fixed; 1 new minor)

Read: packaging/common.sh, install.sh, uninstall.sh, packaging/vr-talex.service (ExecStart), tests/install/run.sh (new scenarios), 04_dev_T8.md "Fix round 1", qa-artifacts/T8/run1.log (20/20 PASS). `bash -n` passes on all four scripts. No bare `return` is left in common.sh, install.sh or uninstall.sh.

| # | Finding | Status | Evidence |
|---|---|---|---|
| 1 | a failed restore deletes the backup | fixed | common.sh:293-305 `replace_with` copies into a `mktemp -d` dir next to dst, then `mv -fT`; dst is never removed first. common.sh:439-443 keeps the backup and returns 1 on any failure; uninstall.sh:55-57 exits non-zero. A re-run is idempotent (`same_entry dst bak` skips entries already restored). Test: failed_restore |
| 2 | user edits after install are lost | fixed | install_managed/record_installed (install.sh:154-165) store what install wrote. restore_entry (common.sh:337-370) moves a differing dst aside to `<file>.vr-talex-saved-<date>` before restoring, and never deletes a file it did not write. Saved names are not read by environment.d, autostart or the dbus services dir. Test: edited_after_install, edited_then_reinstall |
| 3 | re-install without a backup | fixed | install.sh:274-290 refuses before any change. Test: reinstall_backup_deleted |
| 4 | sources/mru restore order | fixed (live effect T9) | common.sh:383 restores mru-sources, then sources |
| 5 | added sources dropped | fixed | gs_restore + installed.gs (common.sh:188-202, install.sh:266): equal to what install wrote → restore the saved value; otherwise remove only the vr-talex entry. I traced without_vr for the head, tail and only-entry cases: correct |
| 6 | data-safety tests missing | fixed | 10 new scenarios, including symlinked_config, fcitx5_unit and fcitx5_stuck |
| 7 | `&` in HOME / Exec quoting | fixed | common.sh:208-212 uses a quoted replacement and writes `Exec="<path>"`; common.sh:68-70 refuses a HOME containing `"` or `\` in init_paths, before any write; the unit has `ExecStart="%h/..."`. Test: special_home, bad_xdg |
| 8 | tab/newline in XDG dirs | fixed | common.sh:52-55 |
| 9 | silent removal on a failed re-run | fixed | install.sh:33-35 |
| trap `return` | the developer's bug | fixed | explicit `return $?` in gs_restore and same_entry; grep finds no bare `return` |

Symlinks traced again: ~/.xinputrc as a symlink → put_file replaces the link and does not write through it. `inst` is a regular file, so on uninstall dst equals inst and `replace_with` puts the saved symlink back. ~/.config as a symlink → all writes go through the link, and the rmdir loop cannot remove the link.

## New finding

### [minor] install.sh:160-162 + common.sh:357-358: a file written by install but not yet recorded is left after rollback
Scenario: put_file writes ~/.xinputrc (`run_im none`, absent before install) → record_installed fails (for example ENOSPC in the backup dir) → die → rollback → restore_entry finds no `installed/` copy → "was not written by vr-talex; left in place". fcitx5 does not start at the next login. This is recoverable: the next install refuses with "installed without a backup", and uninstall's no-backup path removes the file because it equals the template. The warning is still wrong. Fix: record the source template before put_file (`record_installed` from `$src`), or, in the absent case with no `inst`, also compare dst with the packaging template.

## Rule check T8 (changes from round 0)
| Rule | Status | Evidence |
|---|---|---|
| SEC-21 | pass | backup kept when a restore fails (failed_restore); re-install without a backup refused (reinstall_backup_deleted) |
| SEC-22 | pass | edited_after_install: only the vr-talex entry is removed from changed sources |
| AC-6 | pass (file/keyfile) | fresh_*, edited_after_install, symlinked_config, fcitx5_unit, special_home; live behaviour is T9/O1 |
| SEC-23 | pass (shellcheck n-o) | no new `rm -rf`; the new rm targets are `$tmp/entry` (a mktemp dir) and dst only when it equals the installed copy |
The other rows are unchanged from round 0.

---

# Re-check quick pass 1

Verdict: **APPROVED**

Read: `git diff -- install.sh packaging/common.sh tests/install/run.sh` (against 6a1905e), the "Quick pass 1" note in 04_dev_T8.md, qa-artifacts/T8/red2.log (record_write_fails failed 3 checks before the fix) and run2.log (21/21 PASS). `bash -n` passes on install.sh and packaging/common.sh.

The round-1 minor is fixed. install_managed (install.sh:160-165) now records the content it is about to write, with its mode, before put_file runs. record_installed (common.sh:322-332) writes a temp file in backup/installed/, then chmods it and renames it into place; on failure it removes the temp file and returns 1. Traced:
- The record fails → install dies before dst is written → rollback finds dst unchanged (absent, or equal to the backup) → nothing is left behind and no wrong warning is printed. Test: record_write_fails.
- The record succeeds and the write fails → dst is still the original → `same_entry dst bak` (present) or `exists dst` false (absent) → nothing is touched.
- Normal path → put_file writes the same bytes and mode → `same_entry dst inst` holds → uninstall removes or restores as before. A re-run with an unchanged template does not record again.

Note, no finding: an upgrade re-run whose new template is recorded but then fails to write leaves dst holding the old vr-talex content, which no longer matches the record. The rollback or uninstall then moves that file aside as `.vr-talex-saved-*` with a warning. This only produces an extra copy and loses no data, and it needs a write failure right after a successful record.

No new findings. The rule-check rows are unchanged from fix round 1.
