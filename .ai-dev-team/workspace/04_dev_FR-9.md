# FR-9 install.sh: leave Vietnamese (Telex) selected in the running shell

## Progress
- start: read brief, FR-7 notes, install.sh, common.sh, tests
- read: install.sh, common.sh, tests/install/run.sh, stubs/systemctl, e2e install_scenario.sh, GNOME 46 keyboard.js/ibusManager.js
- red: tests/install/run.sh 4 scenarios FAIL as expected (qa-artifacts/FR-9/red-install.log); e2e checks added (shell current source + rerun replay); red e2e on master (qa-artifacts/FR-9/red-e2e.log)
- green: install.sh order select_source->start_daemon (always restart), reselect_source; tests/install 28/28 PASS (qa-artifacts/FR-9/green-install.log)
- BASE-48 (coordinator): install.sh no longer prints 'selected'; e2e reads shell state + records gsettings current (deprecated/ignored in GNOME 46)
- green e2e (qa-artifacts/FR-9/green-e2e.log): AC-5 PASS, shell current [ibus:vr-talex|VI] after fresh install and after the re-run that started with the shell on [xkb:us|en]; AC-6 PASS; no sandbox process left after the runs

- Quick pass 1 (05_review_FR-9.md): minor 1 fixed — reselect_source no longer rewrites installed.gs (when only vr-talex's place changed, the new mru equals what the first install recorded; when the user changed it, uninstall takes the keep-user-edits path); new scenario reselect_keeps_user_edits red first (qa-artifacts/FR-9/qp1-red-install.log: "installed.gs not rewritten" FAIL, "mru-sources keep the user's layout first" FAIL, shortcut checks FAIL), then green. Minor 2 fixed — new switch_shortcut prints the user's own `switch-input-source` binding (first entry, printable chars only), neutral wording when unreadable; checked with '<Control>space' in the scenario. `bash tests/install/run.sh` -> `--- 29 scenarios, 0 failed` (qp1-green-install.log); e2e install scenario exit 0: AC-5 PASS (shell current [ibus:vr-talex|VI] after fresh install and after the re-run that started on [xkb:us|en]), AC-6 PASS, AC-2:term-1 PASS, SEC-1 PASS (qp1-green-e2e.log); install message in the sandbox: "... (the shortcut <Super>space switches sources)" = the sandbox's own binding. Nothing left running (e2e cleanup stopped its 23 tagged processes; my one kept failed-run temp dir removed).

## Root cause and evaluation
- GNOME 46 keyboard.js: `_updateMruSources` reads `mru-sources` from GSettings only while the in-memory `_mruSources` is empty, i.e. only after `_ibusReadyCallback` (IBus readiness changes). On master install.sh wrote mru/sources AFTER the daemon was healthy, so the shell was often already connected (ready) and kept 'us' current. A re-run with the source already present wrote nothing and did not restart the daemon (unless the binary changed).
- Option A (chosen): write sources + mru BEFORE starting the daemon, and restart a running daemon on every run. The shell's connect (ready true) then re-reads mru with vr-talex at the head. Deterministic, uses the shell's own readiness path, no Eval, no key presses.
- Option B (rejected): write after health, then restart the daemon again: two starts on a fresh install, and the moment of selection is the same as in A (the shell selects on connect, which happens during the health check in both).
- Option C (rejected): a staged series of `sources` writes that reshapes the in-memory MRU list: needs the shell already ready (racy), relies on dconf not merging fast writes, flashes layouts.
- `current` key: GNOME 46 schema says "DEPRECATED: This key is deprecated and ignored"; keyboard.js has 0 references. The e2e shows `current=uint32 0` (the index of 'us') while the shell's current source is vr-talex, so it is recorded, not judged.
- SEC-19 argument: keyboard.js `_inputSourcesChanged` drops an IBus source unless a ready bus lists its engine, so vr-talex cannot become current while the daemon is not answering; a failed health check rolls both keys back exactly (tests broken_daemon, reselect_rerun_failure, rerun_failure). The literal SEC-19 text in 02_threat-model.md ("switches sources only after healthy") should be reworded by the leader: the write now comes before the start; the selection still depends on the daemon answering.

## Files changed
- install.sh: select_source runs before start_daemon; new reselect_source (source already present -> vr-talex moved to the head of mru-sources, the installed.gs mru line replaced so uninstall/rollback put the saved value back exactly); start_daemon always restarts a running unit (CHANGED_BIN dropped); messages no longer say "selected" (BASE-48); header and health_check comments updated.
- tests/install/stubs/systemctl: logs `started <unit> mru-sources=<value>` at each start.
- tests/install/run.sh: helper started_with_vr_head; fresh_fcitx5 (start found vr-talex first; re-run restarts with vr-talex first; noibus snapshots because the restart rewrites the address file), broken_daemon (rollback had sources to undo; keyfile byte-identical); new scenarios reselect_on_rerun, reselect_rerun_failure; check that install never prints "selected".
- tests/e2e/install_scenario.sh: cur_src / wait_vr_selected read the running shell's input source manager (type:id|label, vi compared case-insensitively); live replay before the 2nd install (shell on us, mru setting head vr-talex); footprint skips ~/.config/ibus/bus (rewritten by each daemon start); records gsettings current; fails on "selected" in install output.
- packaging/common.sh: no change needed (restore_all already puts both keys back, mru first).

## Commands (trimmed)
- red: `bash tests/install/run.sh fresh_fcitx5 broken_daemon reselect_on_rerun reselect_rerun_failure` -> 4 failed: "started vr-talex.service mru-sources=@a(ss) []", "second install restarted the daemon" FAIL, "mru-sources has vr-talex first again" FAIL, keyfile not back byte for byte
- red e2e (master install.sh): `RESULT AC-5 FAIL ... shell current source after install [xkb:us|en] expected [ibus:vr-talex|vi] ... second install with the shell on [xkb:us|en] -> current [xkb:us|en]` (the AC-2 FAIL in that run was the injection rate, 18.1 ms/key under load, not mine)
- green: `bash tests/install/run.sh` -> `--- 28 scenarios, 0 failed`
- green e2e (`$TEAM_BIN/run-heavy.sh bash tests/e2e/run.sh --ime daemon --scenarios install --apps term --runs 1 --words 10 --allow-incomplete`): `RESULT AC-5 PASS install rc=0; engine connected to the shell [vr-talex|VI] 0.4 s after install returned; shell current source after install [ibus:vr-talex|VI]; gsettings current=uint32 0 (deprecated, not written by the shell); ... second install changed files: no; second install with the shell on [xkb:us|en] -> current [ibus:vr-talex|VI]`; AC-6 PASS; AC-2:term-1 PASS; SEC-1 PASS; e2e exit 0
- shellcheck -x on changed scripts vs HEAD: no new finding except one more SC2119 note of the same kind as the 10 existing ones (run_install without args)

## Deviations
- A re-run now always restarts a running daemon (before: only when the binary or unit changed). Needed for D33: the shell's state cannot be read without Eval. T8's check "second install did not restart the daemon" is replaced by "restarted with vr-talex first"; still no file change, no daemon-reload, no fcitx5 call.
- SEC-19 wording (see above): for the leader to reword in 02_threat-model.md.

## Out of scope
- R1 (fe-ibus refuses SetGlobalEngine xkb) is FR-7's: on master the terminal still converts while the shell is on 'us'.
- README.md line 28 "Running it again changes nothing": still true for files; could mention the daemon restart.

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| shell current label | tests/e2e/lib.sh CUR_LABEL_JS | reused inside CUR_SRC_JS |
| start/stop sandbox daemon | tests/install/stubs/systemctl, e2e systemctl shim | reused; stub extended with one log line |
| source list edits | packaging/common.sh without_vr, list_items | reused in reselect_source |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 | pass | only install.sh, install tests, e2e install_scenario.sh; no crates/, no FR-7 e2e files |
| BASE-3 | pass | red then green: qa-artifacts/FR-9/red-install.log, red-e2e.log, green-install.log, green-e2e.log |
| BASE-7/24 | pass | main tree, no commit |
| BASE-19 | pass | this file, a progress line per step |
| BASE-37 | pass | user's state replayed in the e2e (fresh install with the shell connected first; re-run with the shell on us and mru head vr-talex): FAIL before, PASS after |
| BASE-48 | pass | claim from the running shell's state (CUR_SRC_JS via sandbox Eval) read after install; gsettings current recorded (uint32 0, deprecated); install.sh prints no "selected" (reselect_on_rerun check, e2e grep) |
| SEC-19 | pass | broken_daemon, reselect_rerun_failure, rerun_failure: rollback, keyfile byte-identical; vr-talex cannot be current without a ready bus (keyboard.js _inputSourcesChanged) |
| SEC-21 | pass | installed.gs updated on re-selection, so uninstall restores exactly (reselect_on_rerun keyfile byte-identical) |
| SEC-22 | pass | user-level only; gsettings and systemctl --user; backup record written tmp+mv inside the 0700 backup dir |
| SEC-23 | pass | daemon restarted through systemctl --user only; e2e "refused kill-by-name calls: 0" |
| SEC-29/D2 | pass | install.sh/uninstall.sh run only in tests/install sandboxes (env -i, private bus) and the e2e nested sandbox |
| COST-1..20 | pass | e2e through run-heavy.sh in the background; edits with Edit; logs in qa-artifacts/FR-9; no pkill; nothing left running |
