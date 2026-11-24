# FR-4 e2e install scenario fixes
- Read script. Before: old extraction gives `"…/vr-talex": No such file or directory` rc=127 (reproduced on a temp unit).
- Edited tests/e2e/install_scenario.sh: shell-parse ExecStart (eval into argv); stop waits up to 5 s then KILL.
- run1 (fixes 1-2 applied): AC-5 FAIL install rc=1 "ibus-daemon is running" (sandbox gnome-shell ibus-daemon); AC-6 PASS. Added tag-verified sandbox ibus stop in harness.
- runs 2-7: probes showed org.freedesktop.portal.IBus is owned by fcitx5 itself (pid == org.fcitx.Fcitx5 owner, cmd `fcitx5`, its IBus frontend). packaging/common.sh check_platform (install.sh:64) treats that as a running ibus-daemon -> install refuses. PRODUCT bug, not harness. Harness probes/ibus-stop reverted. Final diff: shim ExecStart shell-parse + waiting stop only.
- Evidence: .ai-dev-team/workspace/qa-artifacts/FR-4/run{1..7}.log
## Run 8 (after FR-5's install.sh fix), same command, no --skip-install
- AC-5 FAIL: install rc=0; engine connected [vr-talex|en,VI] 0.3 s after install; sources [('xkb','us')] -> [('xkb','us'),('ibus','vr-talex')] (1 x vr-talex); new terminal typed [việt] OK; new Chrome typed [vieetj ] expected [việt ] FAIL; second install changed files: no.
- AC-6 FAIL: uninstall rc=0; sources stayed [('xkb','us'),('ibus','vr-talex')] (before install: [('xkb','us')]); fcitx5 owns org.fcitx.Fcitx5 again (OK).
- Analysis (not fixed, product): install-2.log says "input source already present"; but install.sh:109 `rm -rf backup` + new manifest records gs sources AFTER the first install (already with vr-talex), so uninstall's gs_restore sees cur == saved and restores nothing. Second run overwrites the first install's backup.
- Chrome raw typing: unresolved cause (terminal works through the same engine); needs investigation (harness Chrome env/focus vs product).
- Logs: qa-artifacts/FR-4/run8.log, out8/.
