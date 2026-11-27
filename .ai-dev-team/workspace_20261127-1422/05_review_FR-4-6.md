# Review FR-4 + FR-6 (tests/e2e): APPROVE (2 minor)
Files read: tests/e2e/{install_scenario.sh,lib.sh,run.sh,e2e.py,README.md} diffs plus the surrounding guard/cleanup/shim code. Not run (per brief).

## Findings
[minor] FR-6 notes (a), evidence — the "00:19:17.332 stale keyfile rewrite" is not in qa-artifacts/FR-6/. probe-out/ holds only a later run (kfwatch.log: 1 entry at 00:21:47, "<missing>"); a search for "00:19:17" in the folder finds nothing. The writer was never identified (kfwatch sees content, not pid). Root cause = keyfile lost update is plausible and the dconf switch is the right fix (10/10 cycles in probe3, after.log AC-6 PASS), but it is inferred.
Fix: copy the cycle-4 kfwatch.log + gs.log excerpt into qa-artifacts/FR-6/, or word the note as "most likely".

[minor] install_scenario.sh stop(): signals the pid from the state file, then SIGKILL after 5 s. A stale pid file (process died, pid reused) could signal an unrelated same-user process, the live desktop's included. The window is tiny and the old code had the same exposure.
Fix: before signalling, check /proc/$p/environ for VRT_E2E_TAG (as cleanup does).

## SEC-29/D2: pass
- GSETTINGS_BACKEND=dconf is exported in iso_env, after which dbus-run-session starts its own dbus-daemon, which activates dconf-service (ca.desrt.dconf.service: plain Exec) with the sandbox HOME/XDG_CONFIG_HOME/XDG_RUNTIME_DIR. The db is <run>/sandbox/home/.config/dconf/user. It inherits VRT_E2E_TAG, so cleanup() stops it with the other tagged processes. It cannot reach the live bus or pid 7089.
- run.sh's `gsettings set` runs after guard(), inside the private session. If activation failed it errors (exit 1, fail closed), it does not fall back to live dconf. Live ~/.config/dconf/user mtime unchanged (live-dconf-before.txt, notes).
- cleanup() kills only processes whose environ carries the tag. The name-based kill shims still refuse.

## eval "argv=($cmd)"
Acceptable for a test tool. $cmd comes from the ExecStart line of the unit install.sh wrote in the sandbox (repo-controlled paths plus the sandbox HOME); no untrusted input reaches it.

## Oracle honesty: pass
- CUR_LABEL_JS reads the current source's label only. A missing current source gives "", a wrong source gives "en"/"EN", never "VI". A failed toggle still fails AC-4/AC-5.
- probe1 shows labels and current index agreeing ("1=VI*" at cur=1).
- AC-6 compares against the pre-install sources() value (after.log: "before install: [('xkb','us')]").
- FR-6 (b), joined "en,VI": supported by probe1.log lines 12-13 (ensure_vi toggled VI to EN before Chrome).

## Rule check FR-4/FR-6
| Rule | Result | Note |
|---|---|---|
| BASE-1 | pass | only tests/e2e changed; no product code |
| BASE-6 | pass | red/green evidence for both fixes; the missing excerpt is the minor above |
| BASE-15 | pass | no name-based kills; tag-based cleanup only; shims refuse |
| SEC-29 | pass | see above |
