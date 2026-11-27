# Review FR-9 (code + security)

Verdict: **APPROVED** (2 minor findings, none blocking)

## Files read
- install.sh: read (whole file; the diff plus backup_state, install_managed and the paths it calls)
- packaging/common.sh: read (unchanged; gs_restore, installed_gs, without_vr and restore_all are what the new installed.gs record feeds)
- tests/install/run.sh: read (diff)
- tests/install/stubs/systemctl: read (diff)
- tests/e2e/install_scenario.sh: read (diff)
- README.md: read (diff)
- qa-artifacts/FR-7/gs/keyboard.js, ibusManager.js: read (_ibusReadyCallback, _updateMruSources, _inputSourcesChanged, _updateMruSettings, activateInputSource, getEngineDesc)
- qa-artifacts/FR-9/red-install.log, green-install.log: read; red-e2e.log, green-e2e.log: result lines taken from the notes

## How the checks came out
- **Order and restart.** select_source runs before start_daemon, and a running unit is restarted on every run. keyboard.js backs this up: `_ibusReadyCallback` clears `_mruSources` and `_updateMruSources` then reads `mru-sources` again. `_updateMruSettings` writes the MRU list back only when the switch is `interactive` and the bus is ready, so the shell cannot overwrite the value install wrote while no daemon is running. Nothing else used CHANGED_BIN.
- **Restore after N runs.** reselect_source replaces only the mru line of installed.gs, through a tmp file and mv. For N runs with plain switches between them: at uninstall or rollback, `cur == installed` for both keys, so gs_put puts the pre-install value back. That value is reset when it equals the default, which is the FR-5 behaviour. The red log shows the old code left a different keyfile after a switch followed by uninstall (reselect_on_rerun, reselect_rerun_failure). The new code returns it byte for byte.
- **Failure paths.** broken_daemon and reselect_rerun_failure both roll back to a byte-identical keyfile. An `('ibus','vr-talex')` source can only become current when a ready bus lists its engine: `getEngineDesc` returns null when `!_ready` or the engine is unknown, and `_inputSourcesChanged` then drops the source. So SEC-19 as reworded holds.
- **Re-run while typing.** The restart goes through `systemctl --user restart`, and the daemon handles SIGTERM (main.rs:201-254). D34 accepts this.
- **BASE-48.** No output line says "selected". The unit test and the e2e grep both check this. The e2e AC-5 reads `_inputSourceManager.currentSource`, and `current` is only recorded.
- **Data safety.** backup_state is untouched (backup taken once). install_managed, the move-aside of user edits and the symlink guards are unchanged. installed.gs.tmp sits inside the 0700 backup dir, which is refused if it is a symlink.

## Findings

[minor] install.sh:316-321: a re-run records the user's later mru edits as "what install wrote"
Scenario: before install, sources=[us] and mru is unset. Install writes sources [us,vr] and mru [vr,us]. The user then adds `de`, uses it, and the shell writes mru=[de,vr,us]. A re-run writes mru=[vr,de,us] and also stores that value in installed.gs. At uninstall `cur == installed`, so mru goes back to the pre-install value and `de` drops out of the MRU list. GNOME then makes `us` current, not `de`. Without the re-run, gs_restore would have kept [de,us] (the FR-5 rule "keep user edits, remove only vr"). sources is still handled correctly, so no source is lost, only the MRU order and the current source after uninstall.
Fix: in reselect_source, rewrite the installed.gs mru line only when `without_vr "$cur"` equals `without_vr "$(installed_gs mru-sources)"` (only vr's position changed). Otherwise leave the line alone, so uninstall takes the "user changed it" path. Also skip the rewrite when the value is the same, so the file is not reordered and README's "changes no file" stays literally true. Add a run.sh scenario: add a layout between the runs, run uninstall, then check mru.

[minor] install.sh:360: the message names Super+Space, but D33 and the user say Ctrl+Space
Scenario: a user whose `org.gnome.desktop.wm.keybindings switch-input-source` is Ctrl+Space (the shortcut D33 describes) is told to press Super+Space, which does nothing for them.
Fix: read the binding with `gsettings get org.gnome.desktop.wm.keybindings switch-input-source` and print it, or write "the input-source switch shortcut (Super+Space by default)".

Not a finding: the e2e only exercises the "already first" re-run path, because the replay sets mru with vr at the head. The mru-rewrite path is covered by reselect_on_rerun in run.sh.

## Rule check FR-9
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 | pass | diff limited to install.sh, tests/install, tests/e2e/install_scenario.sh, README (leader) |
| BASE-3 | pass | red-install.log 4/4 FAIL on old code; green 28/28; e2e red AC-5 FAIL -> green PASS |
| BASE-15 / SEC-23 | pass | restart through `systemctl --user` only; no pkill/killall in the diff; variables quoted |
| BASE-37 | pass | e2e replays the shell on xkb:us with vr at the mru head; FAIL before, PASS after |
| BASE-48 | pass | no "selected" in output (run.sh check + e2e grep); AC-5 reads shell currentSource |
| SEC-19 | pass | keyboard.js getEngineDesc/_inputSourcesChanged; broken_daemon, reselect_rerun_failure keyfile byte-identical |
| SEC-21 | pass | backup once (unchanged); reselect_on_rerun keyfile byte-identical after uninstall; see minor 1 for the user-edit case |
| SEC-22 | pass | source added once; re-run edits mru-sources only; installed.gs via tmp+mv in 0700 dir |

## Re-check quick pass 1

Verdict: **APPROVED**. Both minor findings are fixed, and the fix introduces no new issue.

Files read (this round): install.sh (reselect_source, switch_shortcut, main message), tests/install/run.sh (t_reselect_keeps_user_edits), qa-artifacts/FR-9/qp1-red-install.log, qp1-green-install.log, qp1-green-e2e.log (AC-5 lines).

- **Minor 1, fixed.** install.sh:306-321: reselect_source now writes only mru-sources. installed.gs keeps the value the first install recorded.
  - User changed nothing (only switched sources): every re-run computes `[vr, <current mru without vr>]`. For the installed one-layout case that is exactly the recorded `[vr, us]`. At uninstall or rollback `cur == installed`, so the pre-install value comes back. This holds after any number of re-runs, because each run rebuilds the value from the current mru, not from the previous run. reselect_on_rerun and reselect_rerun_failure still compare the keyfile byte for byte and pass (qp1-green-install.log, 29/29).
  - User changed the list: the re-run gives `[vr, de, us]`, which is not the recorded value, so uninstall takes the without_vr path and keeps `[de, us]`. New scenario reselect_keeps_user_edits: red in qp1-red-install.log, green now.
  - Observation, not a regression: with two or more other layouts, switching between them without any edit also reorders mru. Uninstall then keeps that order (without vr) rather than the pre-install value. This is the FR-5 gs_restore rule and also happens with no re-run.
- **Minor 2, fixed.** install.sh:325-334: switch_shortcut prints the user's first `switch-input-source` binding and falls back to neutral wording when the binding is empty or unreadable.
  - `tr -cd '[:print:]'` strips control characters, so a crafted binding cannot inject escape sequences into the terminal.
  - A gsettings failure is caught by `|| v=''`, so `set -e` is safe.
  - The scenario checks with `<Control>space`.
- README's "changes no file" is now literally true: the re-run no longer rewrites installed.gs.
- e2e (qp1-green-e2e.log): AC-5 PASS after the fresh install and after the re-run that started on xkb:us.
