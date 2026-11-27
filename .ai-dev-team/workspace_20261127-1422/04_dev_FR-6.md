# FR-6 Bug: AC-6 sources not restored after install x2 + uninstall; Chrome types raw after install (AC-5)

## Progress
- started: read FR-4 notes/run8 logs, install.sh, uninstall.sh, packaging/common.sh, tests/e2e/** (no repo edits until "FR-5 committed")
- FR-5 committed (4c2df59); edits allowed. BASE-37 before-replay (FR-4 exact command) -> qa-artifacts/FR-6/before.log: AC-5 FAIL (Chrome [vieetj ]), AC-6 PASS (intermittent)
- probe1 (instrumented copy of the harness in qa-artifacts/FR-6/probe/): (b) root cause confirmed - indicator() joins all panel labels ("en,VI"), ensure_vi always toggles; the Chrome step toggled VI->EN. (a) backup NOT overwritten (install-2.log has no "saved the current setup"); AC-6 passed again
- probe2 (keyfile watcher kfwatch.py + 6 install/install/uninstall cycles): caught a non-installer process rewriting the whole keyfile with the stale pre-uninstall input sources 90 ms after uninstall's last gsettings write (cycle 4)
- fix: harness only (tests/e2e/lib.sh, run.sh, e2e.py, README.md); no product change
- probe3 (fixed harness, 10 extra cycles): AC-5 PASS, AC-6 PASS, 10/10 cycles restored [('xkb', 'us')]
- after-replay (exact FR-4 command) AC-5 PASS, AC-6 PASS; toggle scenario AC-4 PASS; tests/install fresh_fcitx5 PASS

## Root causes
### (a) AC-6: sources left with vr-talex after uninstall — not the installer
- The brief's hypothesis (re-run rewrites the backup) is not what happens: `install.sh:299-306` calls `backup_state` only when the manifest is absent, and run8's `install-2.log` has no "saved the current setup" line (only "input source already present"). The T8 suite `fresh_fcitx5` already asserts install, install, uninstall -> files and keyfile byte-identical to pre-install (`tests/install/run.sh:239-247`) and passes; it did not "miss" anything — the installer is correct.
- Real cause: the e2e sandbox used `GSETTINGS_BACKEND=keyfile`. That backend rewrites the WHOLE keyfile from each process' in-memory copy on any write. With gnome-shell, gnome-terminal, Chrome, fcitx5 all running, a process whose copy was not yet reloaded writes the stale pre-uninstall `sources` back over uninstall's restore (lost update). The real desktop uses dconf (per-key writes through one dconf-service), where this cannot happen.
- Evidence (qa-artifacts/FR-6/probe-out of probe2, `logs/gs.log` = every gsettings call of install/uninstall via a PATH shim, `logs/kfwatch.log` = every keyfile content change):
  - 00:19:17.187 uninstall `set mru-sources [('xkb','us')]`, 00:19:17.231 `set sources [('xkb','us')]` (last installer write; keyfile shows `sources=[('xkb', 'us')]` at 17.241)
  - 00:19:17.332 keyfile rewritten by another process: `sources=[('xkb', 'us'), ('ibus', 'vr-talex')]`, `mru-sources=[('ibus', 'vr-talex'), ('xkb', 'us')]` — the full pre-uninstall state; no gsettings call by the installer in the shim log at that time
  - 17.466 / 17.468 two more foreign rewrites happened to restore it in that cycle; in FR-4 run8 the stale write stuck -> AC-6 FAIL
- 34 keyfile changes vs 28 installer/harness set calls in that run: 6 writes by other processes.

### (b) AC-5: new Chrome typed raw "vieetj " — harness
- `tests/e2e/lib.sh` `indicator()` (and `e2e.py` INDICATOR_JS, `IME_STATE`) joined the labels of ALL input sources. After install the sources are [xkb us, vr-talex], so it read "en,VI" (run8: `[vr-talex|en,VI]`) and never equals "VI"; `ensure_vi` therefore sent a Ctrl+Shift toggle every time. Before the terminal no client was focused so the toggle was a no-op; before Chrome the page had focus, so it switched VI->EN and Chrome got raw keys.
- Evidence probe1 (`qa-artifacts/FR-6/probe1.log`): `PROBE before-ensure_vi-chrome: cur=1:vr-talex labels=["0=en","1=VI*"] indicator=[en,VI]` -> `after-ensure_vi-chrome: labels=["0=en","1=EN*"] indicator=[en,EN]`.
- T5's QC never had a second source (sources seeded as [('ibus','vr-talex')]), so the joined string was just "VI".
- Chrome is a Wayland client in this run (chrome.log: `ui/events/platform/wayland/...`); env/IM path is unchanged by install and is not the cause.

## Fix
- `tests/e2e/lib.sh`: `GSETTINGS_BACKEND=dconf` (dconf-service activated on the private dbus-run-session bus, database in the sandbox XDG_CONFIG_HOME); `CUR_LABEL_JS` = label of the current source only, used by `IME_STATE` and `indicator()`.
- `tests/e2e/run.sh`: the initial sources are seeded with `gsettings set` inside the isolated session (the keyfile pre-write is gone).
- `tests/e2e/e2e.py`: `INDICATOR_JS` (AC-4 toggle check) reads the current source's label too.
- `tests/e2e/README.md`: isolation paragraph names the sandbox dconf.
- FR-4's uncommitted change to `tests/e2e/install_scenario.sh` kept as is (not touched by FR-6).

## Files changed
- tests/e2e/lib.sh, tests/e2e/run.sh, tests/e2e/e2e.py, tests/e2e/README.md
- Not changed: install.sh, packaging/common.sh, tests/install/run.sh (no installer defect; see (a)). No crates/ change.

## Tests / red-green
- Red (b): `qa-artifacts/FR-6/before.log` — `RESULT AC-5 FAIL ... new Chrome typed [vieetj ] expected [việt ]`; probe1 shows the wrong toggle.
- Red (a): FR-4 `qa-artifacts/FR-4/run8.log` AC-6 FAIL; probe2 kfwatch catches the stale rewrite (AC-6 is intermittent: before-replay, probe1, probe2 passed).
- Green (after, exact FR-4 command, `qa-artifacts/FR-6/after.log`):
```
RESULT AC-2:term-1 PASS  expected 461 chars, got 461; lost 0, extra 0, replaced 0; mean 15.2 ms/key
RESULT AC-5 PASS install rc=0; engine connected to the shell [vr-talex|VI] 0.3 s after install returned (limit 5 s); sources [('xkb', 'us')] -> [('xkb', 'us'), ('ibus', 'vr-talex')] (1 x vr-talex); new terminal typed [việt] expected [việt]; new Chrome typed [việt ] expected [việt ]; second install changed files: no
RESULT AC-6 PASS uninstall rc=0; sources back to [('xkb', 'us')] (before install: [('xkb', 'us')]); fcitx5 owns org.fcitx.Fcitx5 again; refused kill-by-name calls: 0
RESULT SEC-1 PASS SEC-1 leak scan: 30 tokens, 174 files, 64 journal lines since the run started, 0 hits
RESULT AC-10 INCOMPLETE measured in unit tests (D24 ...)   (expected, exit 1 without --allow-incomplete)
```
- Stress (probe3, fixed harness): 10 extra cycles install, install, uninstall: every `cycle-N-after-uninstall+2s` sources=[('xkb', 'us')] mru=[('xkb', 'us')].
- Related: `run.sh --scenarios toggle --apps term` (INDICATOR_JS change): `RESULT AC-4 PASS toggle PASS: VI->EN 1 ms, EN->VI 1 ms; combos PASS`. `bash tests/install/run.sh fresh_fcitx5`: `PASS fresh_fcitx5 --- 1 scenarios, 0 failed`. `bash -n` lib.sh/run.sh, `py_compile e2e.py` ok. shellcheck not installed (not-run).
- No new tests/install sandbox test: the requested "fails first" test cannot fail — the installer keeps the first manifest; the property (install x2 then uninstall restores byte-for-byte, keyfile included) is already asserted by `fresh_fcitx5`.

## Safety (D2/SEC-29)
- Live fcitx5 pid 6881 still running after all runs; live `~/.config/dconf/user` mtime unchanged (2026-11-24 21:55:34, before and after); the only dconf-service left is the live one (pid 7089, started Nov 22, no VRT_E2E_TAG); the sandbox dconf db is `<run>/sandbox/home/.config/dconf/user`.

## Out-of-scope noticed
- `tests/install/run.sh` also uses the keyfile backend; safe there (one writer at a time, no shell), left as is.

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| e2e install replay | tests/e2e/run.sh, install_scenario.sh | reused unchanged command; probes in a scratch copy (qa-artifacts/FR-6/probe/) |
| keyfile change log | capabilities.md, tests/e2e | none; throwaway qa-artifacts/FR-6/kfwatch.py |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 | pass | one file set per root cause: (a) lib.sh backend + run.sh seed + README; (b) lib.sh CUR_LABEL_JS + e2e.py; no crates/ |
| BASE-3 | pass | scope: harness only; installer untouched since it is correct (evidence above) |
| BASE-7 | pass | root causes traced with probes (probe1.log, probe-out kfwatch.log/gs.log) before fixing |
| BASE-14 | pass | runs foreground within limit via run-heavy.sh; no wait loops |
| BASE-15 | pass | no pkill/killall; sandbox processes stopped by the harness' tag cleanup |
| BASE-16 | pass | Reuse table |
| BASE-17 | pass | nothing installed (dconf-service already on the system) |
| BASE-18 | pass | no agents started |
| BASE-19 | pass | this notes file, progress lines |
| BASE-24 | pass | red evidence before.log/probe1/probe2, green after.log/probe3 |
| BASE-37 | pass | FR-4's exact command replayed before (before.log) and after (after.log) |
| SEC-21 | pass | backup manifest is first-install only (install.sh:299-306); restore verified by after.log AC-6 and 10 cycles |
| SEC-22 | pass | no data-handling change in the installer; uninstall restores exactly (AC-6, fresh_fcitx5) |
| SEC-29 / D2 | pass | sandbox only; live fcitx5 6881 alive; live dconf db untouched; guard unchanged |
| COST-1..7 | pass | only the install/toggle scenarios with 10 words, one run each; no full suite |
| COST-8 | pass | edits with Edit tool |
| COST-9 | pass | nothing left running (only live dconf-service 7089 and fcitx5 6881, both pre-existing) |
| COST-10 | pass | related: toggle scenario for e2e.py, fresh_fcitx5 for installer flow |
| COST-11..12 | pass | heavy runs through run-heavy.sh |
| COST-13 | pass | throwaway scripts in qa-artifacts/FR-6/ |
| COST-14..20 | n-a | no browser UI sweep, no builds needed (binary already built after last crates commit) |
