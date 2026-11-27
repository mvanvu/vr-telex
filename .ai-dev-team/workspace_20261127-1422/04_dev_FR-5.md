# FR-5 Unit restart limits, uninstall stop order, README residual risks
Mode: fix. Side: be. Findings: correctness #4 (unit start limit), #5 (restore_all stop order), security #1/#2 (README).

## Progress
- read: findings JSON, packaging/vr-talex.service, packaging/common.sh, tests/install/run.sh, stubs/systemctl, uninstall.sh, decisions D17/D19/D22/D23/D25/D27, threat model SEC-14/17 + residual risks. systemd 255 (255.4-1ubuntu8.18).
- red: added scenarios unit_restart_policy + uninstall_activation_gap to tests/install/run.sh; both FAIL for the right reasons (StartLimitIntervalSec=60, no RestartSteps/RestartMaxDelaySec; activated vr-talex owns org.fcitx.Fcitx5 after uninstall, orphan process left).
- code: packaging/vr-talex.service (StartLimitIntervalSec=0, RestartSteps=4, RestartMaxDelaySec=15); packaging/common.sh restore_all removes/restores the D-Bus shadow + reload_bus before the unit stop.
- green: both scenarios pass; negative check proves systemd-analyze flags a misplaced RestartSteps.
- README.md rewritten.
- full tests/install/run.sh running in background.
- full run: 23 scenarios, 0 failed (exit 0). bash -n clean on all scripts.

## Files changed
- packaging/vr-talex.service: StartLimitIntervalSec=0 (was 60 + Burst 10); RestartSec=1, RestartSteps=4, RestartMaxDelaySec=15 (back-off 1 s up to a 15 s cap, never stops retrying).
- packaging/common.sh: restore_all puts the D-Bus activation shadow (org.fcitx.Fcitx5.service) back to its pre-install state and calls reload_bus BEFORE `systemctl --user disable --now vr-talex.service`; the later loops skip that entry.
- tests/install/run.sh: new scenarios `unit_restart_policy`, `uninstall_activation_gap`.
- README.md: rewritten (what it is, environment, install/uninstall, hot apply per route, usage + Telex table + D17 limits, recovery, residual risks, VS Code terminal "under investigation"; XIM removed).

## Tests added
- unit_restart_policy: Restart=always, RestartSec=1, StartLimitIntervalSec=0, RestartSteps>0, 2<=RestartMaxDelaySec<=30; `systemd-analyze --user --man=no verify` of the unit in the sandbox HOME reports no line about vr-talex.service.
- uninstall_activation_gap: a sandbox-only systemctl wrapper (PATH prefix) sends an auto-starting Ping to org.fcitx.Fcitx5 right after `disable --now vr-talex.service`; checks the owner afterwards is not ~/.local/bin/vr-talex, uninstall ran `fcitx5 -d`, no vr-talex process alive, no vr-talex string left.

## Commands + output (trimmed)
Red (before the fix), `bash tests/install/run.sh unit_restart_policy uninstall_activation_gap`:
```
FAIL no start rate limit (StartLimitIntervalSec=60)
FAIL restart delay grows in steps (RestartSteps=)
FAIL restart delay is capped between 2 and 30 s (RestartMaxDelaySec=)
vr-talex: fcitx5 is running again          <- false: the re-activated vr-talex owned the name
FAIL the owner is not vr-talex
FAIL no vr-talex process left running
--- 2 scenarios, 2 failed
```
Green, full `bash tests/install/run.sh` (logs: qa-artifacts/FR-5/full/, summary qa-artifacts/FR-5/full.out):
```
PASS fresh_fcitx5 ... PASS record_write_fails   (21 existing)
PASS unit_restart_policy
PASS uninstall_activation_gap
--- 23 scenarios, 0 failed
```
systemd verify (systemd 255.4-1ubuntu8.18), sandbox HOME/XDG_RUNTIME_DIR:
```
systemd-analyze --user verify (exit 0):
/usr/lib/systemd/user/speech-dispatcher.socket:5: Failed to parse address value in '<sandbox>/run/speech-dispatcher/speechd.sock', ignoring: File name too long   <- unrelated system unit, long sandbox path
ok   systemd-analyze reports nothing about vr-talex.service
```
Negative control (qa-artifacts/FR-5/neg): RestartSteps placed in [Unit] gives
`vr-talex.service:10: Unknown key name 'RestartSteps' in section 'Unit', ignoring.` with exit 0, so the test greps the output, not only the exit code.
`bash -n` ok: install.sh, uninstall.sh, packaging/common.sh, tests/install/run.sh, tests/install/stubs/systemctl. shellcheck not installed (D23-3).

## Deviations
- RestartMaxDelaySec=15 instead of the hint's 30: systemd's restart count is not reset by a long healthy run, so the cap is also the raw-keys window after a crash late in the session; 15 s keeps it short while a permanent failure still costs at most ~4 attempts/min.
- The back-off is proven statically and by systemd's own parser only; a live check needs the real user manager (forbidden, D2/SEC-29).

## Out-of-scope issues noticed
- uninstall.sh:26-35 `remove_without_backup` (no-backup path) has the same order: `disable --now` first, shadow file removed later. Not in FR-5's file list (BASE-1); needs the same reorder (remove the shadow when it matches render_dbus_svc, reload_bus, then stop).
- 02_threat-model.md SEC-17 still names StartLimitIntervalSec=60 / Burst=10 as the example; leader to align it with the back-off.
- Real-session edge: with the shadow gone, an activation in the gap starts the real fcitx5 from /usr/share (wanted). When fcitx5 ran as fcitx5.service (manifest `unit`), the later `systemctl --user start fcitx5.service` may then fail with a warning while an fcitx5 already serves. Not reproducible in the sandbox (the bus lists only the sandbox service dir).

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| sandbox harness, PATH-prefixed wrapper stubs | tests/install/run.sh (rootstub, fullstub) | reused the same pattern (gapstub) |
| owner/process checks | run.sh owner_pid, stub-pids/, expect_no_vr_talex_left | reused |
| put one managed entry back | common.sh restore_entry, in_list, reload_bus | reused, no new helper |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 scope | pass | only packaging/vr-talex.service, packaging/common.sh, tests/install/run.sh, README.md changed by FR-5 (other dirty files belong to FR-3/FR-4/leader) |
| BASE-3 tests first | pass | red output above, taken before the packaging changes |
| BASE-7 contracts kept | pass | CLI and file layout unchanged; the 21 existing scenarios pass |
| BASE-24 real output | pass | qa-artifacts/FR-5/full.out |
| BASE-14 no waiting loops | pass | full suite as a background task |
| BASE-15 stop only own | pass | no name-based kills; sandbox processes ended by run.sh cleanup_stubs |
| BASE-16 reuse | pass | ## Reuse |
| BASE-17 / BASE-18 | pass | nothing installed, no agents started |
| BASE-19 notes | pass | this file, created before the first change |
| BASE-25 bash -n | pass | all scripts ok (above) |
| COST-8 edits | pass | Edit tool; README rewritten whole with Write |
| COST-9 nothing left running | pass | `ps` shows no fake-ime / dbus-run-session of FR-5 (two dbus-run-session belong to FR-3/FR-4) |
| COST-10 related set | pass | tests/install/run.sh (tests/e2e/install_scenario.sh is FR-4's) |
| COST-13 throwaway location | pass | qa-artifacts/FR-5/{red,green,neg,full} |
| COST-1..20 others | n-a | no builds, browsers, emulators or servers |
| SEC-14 README limits | pass | README "Security and residual risks"; XIM removed |
| SEC-17 restart forever | pass | unit_restart_policy + verify |
| SEC-21 backup/exact undo | pass | fresh_fcitx5, failed_restore, symlinked_config, special_home pass |
| SEC-22 idempotence | pass | fresh_fcitx5 second-install snapshot identical |
| SEC-23 quoting | pass | every new expansion quoted |
| D2 / SEC-29 sandbox only | pass | guard_sandbox per scenario; live fcitx5 pid 6881 still running (`ps -p 6881`) |

## Round 2 (leader: scope extended to uninstall.sh, install.sh, tests/install/stubs/fake-ime)
### Item A: activation gap on the no-backup path (uninstall.sh remove_without_backup)
- Fix: uninstall.sh `remove_without_backup` now removes the shadow file (only when it matches render_dbus_svc) and calls reload_bus BEFORE `systemctl --user disable --now`; the old remove line further down is dropped.
- Test: `uninstall_activation_gap_no_backup` (install, delete the backup, uninstall through the gapstub systemctl wrapper). The gapstub wrapper and the alive-process check became helpers (`write_gapstub`, `no_vr_talex_alive`) shared with `uninstall_activation_gap`.
- Red (qa-artifacts/FR-5/red2):
```
ok   it took the no-backup path
ok   an activation request was sent right after the unit stopped
FAIL org.fcitx.Fcitx5 is not owned by vr-talex
  alive: 1181526
FAIL no vr-talex process left running
```
### Item B: install refused when fcitx5 owns org.freedesktop.portal.IBus (FR-4 finding)
- Root cause: install.sh preflight treated any owner of org.freedesktop.portal.IBus as ibus-daemon; fcitx5's IBus frontend owns that name (live desktop: both names on pid 6881, per 04_dev_FR-4.md).
- Fix: install.sh `ibus_daemon_running`: refuse when the GNOME IBus unit is active, or when org.freedesktop.portal.IBus has an owner that is not the org.fcitx.Fcitx5 owner (or org.fcitx.Fcitx5 has none). A fcitx5 owning both names is handed over as before (fcitx5-remote -e) and releases the portal name when it quits.
- fe-ibus check: vr-talex does not own org.freedesktop.portal.IBus on the session bus (fe-ibus serves a private path socket and names `org.freedesktop.IBus` only on it, crates/fe-ibus/src/ibus.rs:13), so after the hand-over the name is free and nothing competes with fe-ibus; the scenario asserts no owner after install.
- Stub: tests/install/stubs/fake-ime has a new role `fcitx5-ibus` (fcitx5 + org.freedesktop.portal.IBus); fcitx roles are grouped in FCITX_ROLES; Exit quits every fcitx role except fcitx5-stuck. The stub releases all names on exit, like the real fcitx5.
- Tests: `fcitx5_owns_ibus_portal` (hand-over succeeds, portal name free afterwards, uninstall brings fcitx5 back) and `ibus_beside_fcitx5_refused` (ibus-daemon stub + separate fcitx5: still refused, fcitx5 not asked to quit, nothing changed). `ibus_refused` unchanged and still passing.
- Red (qa-artifacts/FR-5/red3), before the install.sh change:
```
ok   fcitx5 stub owns the IBus portal name too
FAIL install exits 0
FAIL install did not take fcitx5 for ibus-daemon
FAIL fcitx5 asked to quit, not killed
FAIL nothing owns org.freedesktop.portal.IBus after the hand-over
... (22 failed checks)
PASS ibus_beside_fcitx5_refused
PASS ibus_refused
```
### Green, full `bash tests/install/run.sh` (qa-artifacts/FR-5/full3.out, logs full3/)
```
PASS fresh_fcitx5 ... PASS record_write_fails   (21 original)
PASS unit_restart_policy
PASS uninstall_activation_gap
PASS uninstall_activation_gap_no_backup
PASS fcitx5_owns_ibus_portal
PASS ibus_beside_fcitx5_refused
--- 26 scenarios, 0 failed
exit 0
```
`bash -n` ok: install.sh, uninstall.sh, packaging/common.sh, tests/install/run.sh, tests/install/stubs/{systemctl,fcitx5,fcitx5-remote}; fake-ime parses (python ast).
- An earlier full run (full2) was stopped with TaskStop when item B arrived (install.sh was about to change under it); no process of it was left (checked by environ).
- Nothing left running: no fake-ime / vr-talex process with an FR-5 sandbox environment; live fcitx5 pid 6881 still running.
- Rule rows touched: BASE-1 pass (scope extended by the leader: uninstall.sh, install.sh, tests/install/stubs/fake-ime); BASE-3 pass (red2, red3 above); SEC-19/D23 pass (ibus_refused, ibus_beside_fcitx5_refused still refuse with no change); SEC-23 pass (new code quotes every expansion, no kill by name).
