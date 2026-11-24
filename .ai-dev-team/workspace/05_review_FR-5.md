# Review FR-5 (code + security), round 1+2

Verdict: **APPROVED** (no blocker/major, no critical/high/medium). 2 minor/low findings, both optional.

## Files read
- install.sh — read (ibus_daemon_running, preflight)
- uninstall.sh — read (remove_without_backup)
- packaging/common.sh — read (restore_all reorder; restore_entry, owner_pid, reload_bus, render_dbus_svc followed)
- packaging/vr-talex.service — read
- packaging/org.fcitx.Fcitx5.service — read (unchanged; SystemdService= followed for the gap)
- README.md — read whole
- tests/install/run.sh — read (5 new scenarios, write_gapstub, no_vr_talex_alive)
- tests/install/stubs/fake-ime — read
- qa-artifacts/FR-5/red2, red3, full3.out — read (red fails for the right reasons; full3: 26 scenarios, 0 failed)

## Findings

[minor] README.md:94-95 — restart delay description is true only early in the session
Scenario: systemd's auto-restart counter is reset only by a manual start/restart, not by a long healthy run (as the unit comment at packaging/vr-talex.service:19-21 says). After the 4th crash of a session every later crash leaves keys raw for 15 s, while the README says "after 1 s first". A user who sees 15 s of raw keys late in the day has no hint why or how to reset it.
Fix: "The delay grows with each crash in the session, from 1 s up to 15 s; `systemctl --user restart vr-talex.service` resets it." Also note the leader-level point: D22(b) says "restarts within 1 s"; with RestartSteps that holds only for the first restarts. SEC-17 was already reworded to name the back-off; D22 should get the same one-line amendment so the two agree.

[low] install.sh:73-78 — CWE-693 ibus-daemon beside fcitx5 is accepted when fcitx5 got the portal name first (uncertain)
Data path: owner of org.freedesktop.portal.IBus → ibus_daemon_running → preflight.
Exploit/scenario: ibus-daemon started outside the GNOME unit (im-config/im-launch), fcitx5 also running and owning org.freedesktop.portal.IBus first (ibus-portal is D-Bus-activated and not running, or lost the name). The new check sees portal owner == fcitx5 owner and accepts; ibus-daemon keeps rewriting the IBus address file (spike O2). Before FR-5 any portal owner refused, so this one combination is newly accepted. Ubuntu GNOME starts ibus-daemon through the GNOME unit (still caught), and the plain ibus-daemon-without-portal case was already missed before FR-5, so reachability depends on a setup not seen here.
Fix (optional): also refuse when the IBus address file for this display holds an `IBUS_DAEMON_PID` that is alive and differs from the fcitx5 owner pid (read-only; no pgrep/pkill needed), or record it as a known limit in README "Supported environment".

## Checks done (no finding)
- Data safety (T8 history): the shadow entry goes through the same `restore_entry` (absent → removed only if it equals the recorded installed copy, else moved aside; present → backup put back, user edits kept aside), failures still append to RESTORE_FAILED and keep the backup; the later loops skip exactly that one entry, so nothing is restored twice or skipped. remove_without_backup removes the shadow only when `cmp` equals `render_dbus_svc` (unchanged condition, just moved up).
- Gap: with SystemdService=vr-talex.service, an activation after `disable --now` would restart the unit (unit file still present) — the reorder closes this for both paths; the README recovery sequence (`disable --now` then `./uninstall.sh`) is therefore safe: a re-activated unit is still active and restore_all stops it after the shadow is gone.
- ibus_daemon_running: GNOME unit active → refuse; portal owned, fcitx5 name unowned → refuse; portal pid != fcitx5 pid → refuse; same pid → accept (user's live state, pid 6881). Races (fcitx5 quitting/restarting between the two queries) fall to refuse with nothing changed — safe direction. Pids, not unique names, are compared, so separate connections in one fcitx5 process still pass.
- Unit: StartLimitIntervalSec=0 in [Unit], RestartSteps/RestartMaxDelaySec in [Service] (systemd ≥254; 255 here); systemd-analyze verify clean, with a negative control proving misplaced keys are reported. Back-off 1→15 s, never start-limit-hit, no tight loop.
- README: no XIM text; residual risks (same-user keystrokes, session-bus text, Flatpak portal reach per D29, unwiped buffers, crash loses word) listed; D17 limits match D28 (D18 reverted); Qt note matches D25/D27; LimitCORE=0 backs "disables core dumps"; rust-version 1.100 matches Cargo.toml.
- Tests: red2/red3 fail on the old code for the stated reasons; ibus_beside_fcitx5_refused passes on old and new code by design (regression guard); gapstub really sends an auto-starting call right after the stop. No pkill/killall (stubs ended by recorded pid).
- bash -n clean on install.sh, uninstall.sh, packaging/common.sh, tests/install/run.sh.

## Rule check FR-5
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 scope | pass | diff limited to install.sh, uninstall.sh, packaging/{common.sh,vr-talex.service}, README.md, tests/install (scope extended by leader in round 2) |
| BASE-3 tests first | pass | qa-artifacts/FR-5/red, red2, red3 |
| BASE-7 contracts kept | pass | CLI, file layout and messages unchanged; 21 old scenarios pass (full3.out) |
| BASE-15 stop only own | pass | no name-based kill anywhere in the diff |
| BASE-16 reuse | pass | restore_entry, in_list, reload_bus, owner_pid reused; gapstub helpers shared |
| BASE-24 real output | pass | full3.out: 26 scenarios, 0 failed |
| BASE-25 bash -n | pass | rerun by reviewer, all ok |
| COST-13 throwaway location | pass | qa-artifacts/FR-5/* |
| AC-5 | pass | fcitx5_owns_ibus_portal: install succeeds on the user's real fcitx5 state |
| AC-6 | pass | uninstall_activation_gap(_no_backup): fcitx5 back, no vr-talex left |
| SEC-14 | pass | README residual-risk section; XIM text removed (moot per D19) |
| SEC-17 | pass | unit values + systemd-analyze verify; see minor on README/D22 wording |
| SEC-19 | pass | ibus_refused, ibus_beside_fcitx5_refused refuse with nothing changed; recovery commands in README correct (low finding on one undetected combination) |
| SEC-21 | pass | shadow restored via restore_entry, failure keeps backup |
| SEC-22 | pass | fresh_fcitx5 second-install snapshot identical |
| SEC-23 | pass | all new expansions quoted, no pkill/killall, `${XDG_DATA_HOME:?}` in test rm -rf |
