# T8 install.sh / uninstall.sh + systemd user unit + environment.d + fcitx5 hand-over + gsettings + backups

- Task: T8 (be, security, high-risk). Files: `install.sh`, `uninstall.sh`, `packaging/**`, `tests/install/**`.
- Tools available to this agent: Bash, Read, Write, Edit, Skill, ToolSearch, Artifact, Agent (not used, BASE-18), SubagentHandback. System: bash, dbus-run-session, dbus-daemon, gdbus, gsettings (keyfile backend), systemd-analyze, python3+gi. Not installed: shellcheck, inotifywait.

## Progress
- read: task row, spec B7/B8/AC-5/AC-6, plan, spike Q5/Q6, threat model SEC-3/17/18/19..24/28, decisions D1/D2/D11/D19/D20, rule packs BASE/COST, capabilities, profile.
- red: wrote tests/install/run.sh (9 sandbox scenarios) + stubs (systemctl, fcitx5, fcitx5-remote, fake-ime, broken-vr-talex); run before the scripts exist → `bash: .../install.sh: No such file or directory`, FAIL fresh_fcitx5 (24 checks), FAIL root_refused (3) — log qa-artifacts/T8/red/.
- code: packaging/ (unit, env conf, xinputrc, autostart override, D-Bus shadow service, common.sh), install.sh, uninstall.sh.
- green: 9/9 scenarios pass; added scenario uninstall_without_backup (second uninstall entry path, BASE-23); final run 10/10 pass.
- guard: bash -n on every script + python parse of fake-ime (shellcheck not installed); SEC greps; systemd-analyze --user security --offline=true.
- live check: the user's fcitx5 (pid 6881, up 2 days) still running after all runs (`ps -C fcitx5`); no stub process left.
- leader message D22 (unit: Type=notify, NotifyAccess=main, Restart=always, RestartSec<=1, WatchdogSec set, LimitCORE=0): checked, packaging/vr-talex.service lines 13-22 already match (Type=notify, NotifyAccess=main, Restart=always, RestartSec=1, WatchdogSec=10, LimitCORE=0); no change needed.

## Files changed
- `install.sh`, `uninstall.sh` (new, repo root)
- `packaging/common.sh` (shared helpers, sourced), `packaging/vr-talex.service`, `packaging/90-vr-talex.conf`, `packaging/xinputrc`, `packaging/org.fcitx.Fcitx5.desktop`, `packaging/org.fcitx.Fcitx5.service` (templates)
- `tests/install/run.sh` (runner, 10 scenarios), `tests/install/stubs/{systemctl,fcitx5,fcitx5-remote,fake-ime,broken-vr-talex}`
- `.ai-dev-team/capabilities.md` (2 lines appended)

## Design
install.sh: refuse root → paths (XDG dirs must be inside HOME) → preflight (gdbus/gsettings/systemctl present, schema present, session bus reachable, Ubuntu >= 24.04 and GNOME warn-only, refuse when ibus-daemon is active) → build (`cargo build --release --locked -p vr-talex`, or `VR_TALEX_BIN`) → first run only: backup to `~/.local/share/vr-talex/backup/` (0700) with a tab-separated manifest (dirs that did not exist, each managed file present/absent + `cp -a` copy, pre-existing IBus address files, gsettings `sources`/`mru-sources`, fcitx5 mode none/remote/unit + enabled), written tmp+mv → from here any failure rolls back (EXIT trap → `restore_all`, prints recovery) → files written atomically only when content/mode differ → D-Bus shadow service + `ReloadConfig` → daemon-reload only when the unit changed → fcitx5 hand-over (`systemctl --user stop`/`disable` when fcitx5.service is active, else `fcitx5-remote -e`; wait on the recorded pid with `timeout tail --pid`; then the name must have no owner; never kill) → `enable --now` (restart only when binary/unit changed) → health check (`gdbus wait --timeout` on org.fcitx.Fcitx5; owner pid = unit MainPID; a `<machine-id>-unix-*` address file holds `IBUS_DAEMON_PID=<MainPID>`) → only then add `('ibus', 'vr-talex')` once (mru-sources set first with it at the head = select, then appended to sources) → print recovery path.
uninstall.sh: no manifest → "not installed" (or, when vr-talex files exist without a backup, remove only files that are surely ours and warn); else `restore_all`: gsettings restore (a saved value equal to the schema default, read with `GSETTINGS_BACKEND=memory`, is restored by `reset`) → `disable --now` → files absent before removed, present before restored with `cp -a` → IBus address files vr-talex published (pid or socket-path match) removed → daemon `mode` file removed → daemon-reload + bus ReloadConfig → fcitx5 started again (`fcitx5 -d`, or the unit) when it ran before, `gdbus wait` for it → backup deleted → created dirs removed deepest first (rmdir; non-empty kept).

## Tests added: `bash tests/install/run.sh`
Per scenario: `env -i` with HOME/XDG_*/XDG_RUNTIME_DIR under the test dir; `dbus-run-session --config-file` whose only service dir is the sandbox's `~/.local/share/dbus-1/services` (the system fcitx5 activation file can never fire); `GSETTINGS_BACKEND=keyfile`; stubs first on PATH; no WAYLAND_DISPLAY/DISPLAY. An in-sandbox guard exits 99 if HOME, the bus, systemctl or fcitx5-remote is not the sandbox one.
| Scenario | Proves |
|---|---|
| fresh_fcitx5 | AC-5 on the stub: fcitx5 asked to quit (not killed), unit active/enabled, name owned by MainPID, address-file pid, every file = template, keyfile exact, source once + selected; 2nd run: snapshot + keyfile byte-identical, no restart/reload/fcitx5-remote. AC-6: snapshot = pre (address-file content excluded since fcitx5 rewrites it with its new pid — checked separately), keyfile byte-identical, fcitx5 owns the name again, no vr-talex string left |
| fresh_no_fcitx5 | install → uninstall restores everything byte for byte incl. keyfile and IBus dir; fcitx5 not started |
| empty_sources | never-set keys go back to unset, pre-existing ~/.local/bin kept, created dirs removed |
| broken_daemon | SEC-19: daemon dies → exit != 0, "rolled back", recovery printed, files + keyfile identical, fcitx5 running again |
| root_refused | SEC-20: `id -u`=0 → both scripts exit 1, nothing changed, no systemctl call |
| no_cargo | SEC-24: no cargo → clear message, nothing changed |
| ibus_refused | running ibus-daemon → refuse, nothing changed |
| activation_shadow | spike point 5: with vr-talex stopped, an activation request for org.fcitx.Fcitx5 starts `~/.local/bin/vr-talex`, not fcitx5 |
| uninstall_without_backup | second uninstall path: only our files removed |
| uninstall_not_installed | exit 0, "not installed", nothing changed |

## Commands run + result (trimmed)
Red (before the scripts existed), `qa-artifacts/T8/red/`:
```
bash: /home/rainy/DEV/vr-talex/install.sh: No such file or directory
== fresh_fcitx5: 24 failed check(s)
== root_refused: 3 failed check(s)
--- 2 scenarios, 2 failed
```
Green, final code: `VR_TALEX_TEST_DIR=$TEAM_WS/qa-artifacts/T8/run bash tests/install/run.sh` → `qa-artifacts/T8/run.log` (+ per-scenario logs):
```
PASS fresh_fcitx5
PASS fresh_no_fcitx5
PASS empty_sources
PASS broken_daemon
PASS root_refused
PASS no_cargo
PASS ibus_refused
PASS activation_shadow
PASS uninstall_without_backup
PASS uninstall_not_installed
--- 10 scenarios, 0 failed
```
Guard, `qa-artifacts/T8/guard.log` (shellcheck not installed → `bash -n` per the brief's BASE-25):
```
bash -n ok install.sh / uninstall.sh / packaging/common.sh / tests/install/run.sh / stubs/systemctl / stubs/fcitx5 / stubs/fcitx5-remote / stubs/broken-vr-talex
python parse ok tests/install/stubs/fake-ime
```
SEC greps over install.sh, uninstall.sh, packaging/common.sh:
```
'sudo|pkexec|/etc/|/usr/'  → shebangs (#!/usr/bin/env), the root-refusal message, install.sh:35 read-only default VR_TALEX_OS_RELEASE:-/etc/os-release (read with sed, never sourced). No write outside HOME.
'curl|wget|\| *(ba)?sh'    → none
process stop by name         → none; only `kill -0 "$main"` (liveness probe of the unit MainPID)
rm                           → all `rm -f -- "<path built from HOME>"`; the two `rm -rf` are `"${DATA_HOME:?}/vr-talex/backup"`
```
`systemd-analyze --user security --offline=true packaging/vr-talex.service` → `qa-artifacts/T8/systemd-analyze-security.log`: `Overall exposure level for vr-talex.service: 5.9 MEDIUM`. Passing: NoNewPrivileges, RestrictAddressFamilies (INET/INET6/NETLINK/PACKET/exotic denied), IPAddressDeny, MemoryDenyWriteExecute, LockPersonality, RestrictNamespaces (all), RestrictRealtime, SystemCallArchitectures, SystemCallFilter=@system-service. Remaining items are capability / Protect* / Private*: offline mode scores it as a root system unit; a user manager has no capabilities to drop, and Protect*/Private* need unprivileged user namespaces, which Ubuntu 24.04 restricts (the unit would fail to start).

## Deviations / notes for the leader
1. Watchdog: unit has `Type=notify`, `NotifyAccess=main`, `WatchdogSec=10`, `TimeoutStartSec=10` (D22). The daemon must send READY=1 only after it owns org.fcitx.Fcitx5 / portal.Fcitx and has written the address file; otherwise the real `enable --now` returns before the address file exists and the health check fails → rollback. The T4 interval is free: only `packaging/vr-talex.service` changes.
2. Backup location `~/.local/share/vr-talex/backup/` per brief + D11; SEC-21 text says `~/.local/state/...` (doc conflict; followed the brief).
3. `current` (deprecated key) is not changed, so not backed up.
4. A running ibus-daemon (stock Ubuntu, spike O2) → install refuses with no change. Supporting it needs O2's measurement (leader/user decision if stock Ubuntu must be covered).
5. No `systemctl --user set-environment`: shell-launched apps inherit gnome-shell's env, not the manager's; next-login env comes from environment.d + ~/.xinputrc (D20).
6. "Select" = vr-talex at the head of `mru-sources` set before `sources` changes (gnome-shell activates the MRU head on a sources change). Proven only on the keyfile; the live switch is T9 / user run O1.
7. Waiting for fcitx5 to quit uses `timeout tail --pid` on the recorded owner pid (gdbus has no "wait for name to vanish"); waiting for vr-talex uses `gdbus wait --timeout`. No sleep loops.
8. Uninstall restarts fcitx5 with `fcitx5 -d` (as im-launch does), or `systemctl --user start fcitx5.service` when it was a unit.

## Out-of-scope issues noticed
- shellcheck is not installed: SEC-23's "shellcheck clean" is unproven; leader may install it (BASE-17) and run it on install.sh, uninstall.sh, packaging/common.sh, tests/install/run.sh, tests/install/stubs/{systemctl,fcitx5,fcitx5-remote}.
- The unit was never started by a real systemd user manager (HARD RULE, D2); IPAddressDeny / SystemCallFilter under the user manager must be confirmed in the T9 nested session.

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| sandbox session / fake systemd | capabilities.md, spike Q6 pt 8 (`lib.sh`, `fake_systemd.py`) | spike helpers target the nested GNOME session (T9); built a small bash systemctl stub + python fake daemon, indexed in capabilities.md |
| shell helpers | capabilities.md, repo `*.sh` | none existed; new packaging/common.sh |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 | pass | only install.sh, uninstall.sh, packaging/**, tests/install/** (+ capabilities.md index lines) |
| BASE-2 | pass | ExecStart=%h/.local/bin/vr-talex, names org.fcitx.Fcitx5/portal.Fcitx, source `('ibus','vr-talex')`, address-file path per plan; unit per D22 |
| BASE-3 | pass | red run before scripts existed (qa-artifacts/T8/red/), then green |
| BASE-4 | pass | run.log, guard.log, systemd-analyze-security.log, trimmed above |
| BASE-5 | pass | light run (10 sandbox scenarios, foreground with timeout); no build; no process left |
| BASE-6 | pass | English; comments explain why |
| BASE-7 | pass | no commit |
| BASE-9 | pass | root refused, XDG paths validated inside HOME, manifest entries validated (check_rel), no secrets |
| BASE-10 | pass | only tests/install/run.sh + guards on my files |
| BASE-11 | pass | no tree-changing git command; crates/** untouched |
| BASE-12 | pass | nothing written outside the repo |
| BASE-13 | pass | every install/uninstall/gsettings/systemctl/fcitx5-remote call ran in the env -i sandbox on a private bus; live fcitx5 pid 6881 still up |
| BASE-14 | pass | foreground with timeout; no sleep/poll loops |
| BASE-15 | pass | tests stop only stub pids they recorded; scripts never stop processes by name |
| BASE-16 | pass | ## Reuse; capabilities.md updated |
| BASE-17 | pass | shellcheck missing → reported, not installed |
| BASE-18 | pass | no agents started |
| BASE-19 | pass | notes first, progress per step |
| BASE-21 | pass | no secrets in output |
| BASE-22 | pass | seams VR_TALEX_* follow VR_TALEX_BIN from the brief |
| BASE-23 | pass | first install, re-install, failed install rollback, uninstall with / without backup / not installed — one scenario each |
| BASE-24 | pass | no index/history change |
| BASE-25 | pass | `bash -n` (shellcheck not installed, per brief) + tests on final code — guard.log, run.log |
| BASE-32 | pass | D1, D2, D11, D19, D20, D22 kept (see Design, deviation 1) |
| BASE-46 | pass | run.log produced after the last code change |
| COST-1 | pass | no heavy command (stub binary, no cargo build) |
| COST-2 | pass | only my tests |
| COST-3 | pass | `gdbus wait`, `timeout tail --pid`; no sleep/pgrep |
| COST-5 | pass | stub daemons exit with their bus + recorded-pid cleanup; ps shows none |
| COST-8 | pass | files written whole; tests after groups of changes |
| COST-9 | pass | nothing left running |
| COST-10 | pass | related set = tests/install/run.sh (only test that references these files) |
| COST-13 | pass | scratch under $TEAM_WS/qa-artifacts/T8/ |
| COST-16 | pass | full output in qa-artifacts/T8/*.log |
| AC-5 | pass | fresh_fcitx5 (stub daemon): source once + selected, 2nd run byte-identical; real typing is T9/O1 |
| AC-6 | pass | fresh_fcitx5, fresh_no_fcitx5: files + keyfile restored, fcitx5 owns its name again |
| D1 | pass | ./install.sh from the checkout, user-level |
| D11 | pass | footprint checked in expect_installed |
| SEC-3 | pass | `LimitCORE=0` in packaging/vr-talex.service (prctl side is T4) |
| SEC-17 | pass | Restart=always, RestartSec=1, StartLimitIntervalSec=60, StartLimitBurst=10 |
| SEC-19 | pass | broken_daemon; sources set only after health_check (install.sh main) |
| SEC-20 | pass | root_refused; grep above |
| SEC-21 | pass | backup once (2nd-run snapshot identical incl. backup), exact restore in fresh_* and empty_sources |
| SEC-22 | pass | source added once; dedicated env file; Hidden=true override + D-Bus shadow; no vr-talex string left |
| SEC-23 | pass | set -euo pipefail, quoted expansions, rm targets `${VAR:?}`-guarded under HOME, no stop-by-name (grep above); shellcheck itself not run (not installed) — bash -n per brief |
| SEC-24 | pass | no_cargo; grep empty |
| SEC-28 | pass | hardening options present; offline analysis 5.9 MEDIUM with all network/namespace/MDWE items passing; binary 0755 checked |
n-a: BASE-8 (no dependency added; python3+gi/dbus tools used only by tests are system packages) · BASE-20 (nothing removed) · BASE-26..31, BASE-33, BASE-35..45, BASE-47 (no rewrite, shared app/db/browser/container/schema/user rules/UI/computed values) · BASE-34 (no blocked step) · D9 (not needed, D19) · SEC-18 daemon side (T4; unit side: WatchdogSec=10, Type=notify) · COST-4, COST-6, COST-7, COST-11, COST-12, COST-14, COST-15, COST-17..20 (no full suite, UI, audit, e2e, CI, goldens, browser)

## Fix round 1
- read: 05_review_T8.md (2 blocker, 4 major, 3 minor), 05_qc_report.md ## QC T8 (notes b, c); writing failing tests first.
- red: added 9 scenarios + `fcitx5-stuck` role in fake-ime; run before the fixes → `qa-artifacts/T8/red1.log`: 9 of 10 FAIL (fcitx5_stuck passed: the old code already rolled back without killing; it is coverage the review asked for). Two red failures were test bugs, fixed in the test: `saved_copy` under pipefail, and the `noibus` filter did not match `dotfiles/config/ibus/bus` (symlinked_config).
- fixed: common.sh, install.sh, uninstall.sh, vr-talex.service (quoted ExecStart), stubs/systemctl (quoted ExecStart, `&`-safe %h).
- debug 1: rerun_failure rollback reported both gsettings keys as failed although the keyfile was right. Cause: a bare `return` inside the EXIT trap returns the trap's entry status (1). Probe in a throwaway keyfile HOME showed `trapreset=1` against `reset=0`. Fix: `return $?` in gs_restore and same_entry; other bare returns made explicit.
- debug 2: a single-quoted Exec with `'\''` (and a backslash escape) makes dbus-daemon 1.14 reject the whole service file (ServiceUnknown). A double-quoted path with a space, `&` or `'` starts. Probed on a private dbus-run-session bus under qa-artifacts (probe dir deleted afterwards). Fix: Exec="<path>"; HOME with `"` or `\` refused before any change.
- green: added edited_then_reinstall for a state this round introduced (re-run keeps a user-edited file); final run 20/20 PASS.

### Findings
| # | Finding | Reply | Change | Test (red → green) |
|---|---|---|---|---|
| 1 | blocker: a failed restore deletes the file and the backup, exit 0 | fixed | `replace_with` copies into a `mktemp -d` dir next to dst, then `mv -fT`; dst is never removed first. Every failure goes to `RESTORE_FAILED`: the backup is kept, each path is printed as `not restored: <path>`, restore_all returns 1, uninstall exits 1 (`common.sh` restore_entry/replace_with/restore_all, `uninstall.sh` main) | failed_restore: unreadable backup file → exit≠0, ~/.xinputrc still there, backup + manifest kept, file named; second uninstall restores the exact pre-install snapshot |
| 2 | blocker: uninstall loses a managed file the user changed (QC b) | fixed | install records what it wrote in `backup/installed/<rel>`. Uninstall: dst equal to that copy → remove (absent before) or restore. dst different → move it to `<file>.vr-talex-saved-<YYYYmmdd-HHMMSS>` (a name environment.d, autostart and im-config do not read), warn with the path, then restore the original. The no-backup path removes only files equal to their template. IBus address files are excluded (the daemons rewrite them) | edited_after_install (present-before ~/.xinputrc and absent-before 90-vr-talex.conf) |
| 3 | major: re-install with the backup deleted takes vr-talex's files as the original | fixed | `installed_without_backup` (bin, unit, env conf or D-Bus shadow exists, or xinputrc/autostart equal to the template) → "vr-talex is installed without a backup; run ./uninstall.sh first, then ./install.sh", before any change. A re-run with a valid backup is still a no-op (fresh_fcitx5 second run unchanged) | reinstall_backup_deleted |
| 4 | major: restore order sources before mru-sources | fixed | restore_all restores `mru-sources` first, then `sources`. Live effect still for T9 | covered by fresh_* (keyfile byte-identical with the new order) and edited_after_install |
| 5 | major: uninstall drops sources the user added | fixed | install writes `backup/installed.gs`. Per key: current = saved → nothing; current = what install set → restore saved; otherwise remove only `('ibus', 'vr-talex')` from the current list and say so | edited_after_install: `[us, vr, fr]` → `[us, fr]`, mru `[fr, vr, us]` → `[fr, us]` |
| 6 | major: data-safety paths untested | fixed | scenarios edited_after_install, failed_restore, symlinked_config (~/.config and ~/.xinputrc as symlinks), fcitx5_unit (stop+disable via systemctl, enable+start back, wants link restored), fcitx5_stuck (Exit ignored → rollback, fcitx5 still alive and owning its name), reinstall_backup_deleted | the six scenarios |
| 7 | minor: `&` in HOME breaks Exec; unquoted Exec (QC c) | fixed | `render_dbus_svc` (one place, used by install and the no-backup uninstall) uses a quoted replacement and writes `Exec="<path>"`. HOME with `"` or `\` is refused (dbus-daemon rejects them, debug 2). The unit's ExecStart is also quoted | special_home (HOME `h o&m'e`): install, health check, real bus activation through the shadow file starts exactly `$HOME/.local/bin/vr-talex`, exact restore; bad_xdg: HOME with `"` refused, nothing written |
| 8 | minor: tab/newline checked only in HOME | fixed | `inside_home` checks each XDG_CONFIG/DATA/STATE_HOME | bad_xdg: tab and newline in each of the 3 vars, install and uninstall refuse, nothing changed |
| 9 | minor: a failed re-run removes a working install without saying so | fixed | install sets RERUN=1 when the manifest existed; the rollback then prints "the earlier install was removed too; fix the cause, then run ./install.sh again". An incomplete rollback says so | rerun_failure |

### New states (round 1)
- **Backup holds `installed/` and `installed.gs`** (what install wrote). Error halfway: if recording fails, install dies and the rollback runs; without an installed copy a changed file is treated as the user's and kept aside, never deleted. Second request: a re-run refreshes the copy only when the file changed. Concurrent writer: none of ours; a user edit between install and uninstall is case 2.
- **Uninstall can now end incomplete (backup kept, exit 1).** A second uninstall is idempotent: entries equal to the backup are skipped, sources equal to the saved value are skipped, absent files are already gone, fcitx5 is not started twice (owner check). Tested: failed_restore second run gives the exact pre-install snapshot.
- **A re-run moves a user-edited managed file aside before rewriting it.** Tested: edited_then_reinstall. This scenario was written after the code, so it was not seen failing first (stated, not hidden).
- **Kept copies `<file>.vr-talex-saved-*`** are left after uninstall on purpose (the user's data). A name clash adds `-<pid>`.
- A call that never returns: unchanged from round 0. Every wait is bounded by `timeout` (`gdbus wait --timeout`, `timeout tail --pid`).

### Commands + output (final code)
`VR_TALEX_TEST_DIR=$TEAM_WS/qa-artifacts/T8/run1 bash tests/install/run.sh` → `qa-artifacts/T8/run1.log`:
```
PASS fresh_fcitx5 / fresh_no_fcitx5 / empty_sources / broken_daemon / root_refused / no_cargo / ibus_refused / activation_shadow / uninstall_without_backup / uninstall_not_installed
PASS edited_after_install / failed_restore / symlinked_config / fcitx5_unit / fcitx5_stuck / reinstall_backup_deleted / special_home / rerun_failure / bad_xdg / edited_then_reinstall
--- 20 scenarios, 0 failed
```
Guard → `qa-artifacts/T8/guard1.log`: `bash -n ok` for install.sh, uninstall.sh, packaging/common.sh, tests/install/run.sh, stubs/systemctl, stubs/fcitx5, stubs/fcitx5-remote, stubs/broken-vr-talex; `python parse ok tests/install/stubs/fake-ime`. shellcheck is still not installed.
After the run: no stub process left (`ps` count 0); the live fcitx5 (pid 6881, up 2 days) is still running. Nothing touched the real HOME or session.

### Rule compliance changes (round 1)
| Rule | Status | Evidence |
|---|---|---|
| BASE-3 | pass | red1.log before the fixes; the exception (edited_then_reinstall) is stated above |
| BASE-4 | pass | run1.log, guard1.log |
| BASE-23 | pass | added paths: re-install after an edit, re-install without a backup, a failed re-run, an incomplete uninstall followed by a second uninstall |
| SEC-19 | pass | fcitx5_stuck, rerun_failure, broken_daemon |
| SEC-21 | pass | failed_restore (backup kept on failure), reinstall_backup_deleted, edited_after_install |
| SEC-22 | pass | edited_after_install: only the vr-talex entry is removed from sources the user changed |
| SEC-23 | pass | still `bash -n` only (shellcheck not installed); new rm targets: `rm -f -- "$tmp/entry"` + `rmdir` (no new `rm -rf`) |
| AC-6 | pass | fresh_*, edited_after_install, symlinked_config, fcitx5_unit, special_home |
| COST-9 | pass | nothing left running |
