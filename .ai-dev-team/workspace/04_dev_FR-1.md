# FR-1 notes (fix; be)

## Progress
- p1. fresh start; `git status packaging tests/install` clean at start.
- p2. tests/install/run.sh: added check "environment.d sets QT_IM_MODULE=fcitx (D27)" (fresh scenarios); the t_edited_after_install user-edit sample is now `QT_IM_MODULE=user-edit` (a real difference from the template).
- p3. red: with the old template `fresh_fcitx5` and `fresh_no_fcitx5` FAIL (1 failed check each). Green after the template change: `--- 21 scenarios, 0 failed`.
- p4. packaging/90-vr-talex.conf: `QT_IM_MODULE=fcitx` plus a comment line citing D27; XMODIFIERS unchanged.
- p5. `run-heavy.sh cargo build --release --locked` OK. Qt 5 check in an isolated session (qa-artifacts/FR-1/session.sh, copy of the T5 template; own bus/HOME/runtime; live fcitx5 pid 6881 untouched). App: `sqlitebrowser` Qt 5.15, QT_QPA_PLATFORM=wayland, QT_IM_MODULE=fcitx (libfcitx5platforminputcontextplugin).
  - `vieetj ` then `dduowngf ` into the "Filter in any column" QLineEdit -> `việt đường ` (run/s3.png).
  - `vieetj` left as preedit, click into the column-b filter -> any-column box `việt đường việt` (word committed once), b stays empty (run/s5-after-click.png). `dduowngf ` typed in b is Vietnamese (run/s6-in-b.png).
  - dbus-monitor on the sandbox bus (run/dbus-monitor.log): `ProcessKeyEvent` x82, `FocusIn` x93, `UpdateFormattedPreedit` x39, `ProcessKeyEventBatch` x0. The Qt 5 fcitx5 plugin does not call ProcessKeyEventBatch and keys are not raw, so no D25a / FR-2 issue.
- p6. cleanup: session quit ("cleanup: stopped 18 tagged processes"), dbus-monitor killed, 0 /tmp/vrt-e2e.*, no sqlitebrowser or daemon left.

## Changed files
- packaging/90-vr-talex.conf
- tests/install/run.sh
- artifacts: .ai-dev-team/workspace/qa-artifacts/FR-1/ (session.sh, t.db, run.out, run/*.png, run/dbus-monitor.log)

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 | pass | only the two files in the main tree; crates/ untouched |
| BASE-3 | pass | red (2 fresh scenarios FAIL) before the template change, then 21/0 |
| BASE-7/24 | pass | no git add/commit |
| BASE-14/15 | pass | no polling loops; no pkill/killall |
| BASE-19 | pass | this file |
| COST-9 | pass | nothing left running |
| COST-13 | pass | scripts in qa-artifacts/FR-1 |
| SEC-29/D2 | pass | sandbox only |
