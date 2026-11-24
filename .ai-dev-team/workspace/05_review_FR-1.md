# Review FR-1 — APPROVED
Files read: packaging/90-vr-talex.conf (read), tests/install/run.sh (read), packaging/common.sh restore_entry/record_installed (followed), dbus-monitor.log counts re-checked.

Findings: none blocking.
- minor (note) tests/install: no scenario installs with the old ibus template and uninstalls with the new one. Logic is correct by reading (restore_entry compares dst with $BACKUP_DIR/installed/<rel>, the copy record_installed made at install time, never the repo template), so an older install's QT_IM_MODULE=ibus file equals its record and is restored/removed. Optional test only.

Checks: D27/D20 met (QT_IM_MODULE=fcitx, XMODIFIERS=@im=ibus and GTK unset unchanged, only a comment line added). New check is `grep -qx` on the installed file, so it fails on the old template (notes p3: both fresh scenarios red). user-edit sample now differs from the template, so the edited-after-install scenario still tests a real difference. Qt 5 evidence: dbus log ProcessKeyEventBatch 0, ProcessKeyEvent 82, FocusIn 93 (matches notes); screenshots listed for composed text and single commit on click.

## Rule check FR-1
| Rule | Status |
|---|---|
| BASE-1 | pass |
| BASE-3 | pass |
| BASE-15 | pass |
| BASE-19 | pass |
| COST-13 | pass |
