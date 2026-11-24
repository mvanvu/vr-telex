# Review T9 — E2E stress harness

Verdict: CHANGES_REQUESTED (2 major, 4 minor). Tools available: Read, Bash, Write, Skill, SendMessage, SubagentHandback. Harness not run; `bash -n` and `py_compile` pass.

## Findings
[major] tests/e2e/run.sh:313-317 and :331 — AC-10 is never measured in the sign-off run
Scenario: default `--ime daemon` → `result AC-10 SKIP`; the exit status counts SKIP as success, so the 5,000-word, 3-run sign-off returns 0 with the "p99 < 5 ms in the daemon (measured in the stress test)" criterion unmeasured. With `--ime stub` the figure measures the stub, not the product.
Fix: for `daemon` make AC-10 FAIL (or exit non-zero, e.g. 3 "incomplete") until a timing source exists; have the leader decide the interface (open question 4 in the notes). Print a loud "INCOMPLETE" line in the summary whenever a SKIP is present.

[major] tests/e2e/e2e.py:259-266 + run.sh:200-203 — omnibox readback cannot hold a full corpus (uncertain)
Scenario: results are read from `Page.getNavigationHistory` of one tab; Chrome caps session history at 50 entries per tab. A 5,000-word corpus is ~500 lines, one search each, so ≥450 entries are dropped → AC-2 omnibox FAILs at spec size (false FAIL, not a silent pass). Only 40 words (~4 lines) were validated.
Fix: run the omnibox target in chunks of ≤40 lines (`inject --lines A:B`, a new tab per chunk, concatenate the history output), or read the URL after each line. Run one 500-line omnibox pass before sign-off.

[minor] tests/e2e/e2e.py:370-388 — `shell_eval` returns None on Eval failure, `now != before` then counts as a toggle
Scenario: Eval fails after a valid `before` → "toggle PASS" in 0 ms. In the combos loop, None==None is a pass.
Fix: raise/FAIL when `before`, `now` or `after` is None.

[minor] tests/e2e/e2e.py:294-345 — SEC-1 journal scan passes silently when the system journal is unreadable
Scenario: user not in `systemd-journal` → `journalctl` returns empty/denied, counted as 0 lines, 0 hits.
Fix: report "system journal unreadable" in the RESULT detail (or SKIP that part visibly) when the output is empty and the return code is non-zero.

[minor] tests/e2e/install_scenario.sh — AC-5 covers terminal only and AC-6 checks only sources + fcitx5 owner
Scenario: spec AC-5 names Chrome too; typing in Chrome after install is never tried. The 5 s bound is the 20×0.25 s poll after install returns, not measured from install start (the elapsed time is printed, not asserted). If install.sh finds no cargo binary (`$BIN` absent) the build writes to the live `~/.cargo` via `CARGO_HOME` (read/write, outside the sandbox).
Fix: type once in Chrome's textarea after install; set `CARGO_HOME` to a sandbox copy or require `VR_TALEX_BIN` for this scenario.

[minor] tests/e2e/run.sh:56 and lib.sh `guard` — injection rate and abstract-socket buses
Scenario: notes show 20.5 ms/key at `--delay 0.015` (D-Bus call cost added), softer than "15 ms per key"; the achieved rate is printed but never asserted. The guard's bus check only matches `$LIVE_RUNTIME/bus`, not an abstract `unix:abstract=` live address (only reachable if DBUS_SESSION_BUS_ADDRESS were re-exported after iso_env, which it is not).
Fix: subtract elapsed call time from the sleep (absolute schedule), or fail when the mean exceeds 16 ms; also reject an address that does not contain `$E2E_RUNTIME`.

## Verified OK
- SEC-29/D2: the inner shell calls `guard` before any launch; HOME, XDG_*, runtime dir are sandbox paths; cleanup matches `/proc/*/environ` on the run's `VRT_E2E_TAG` only (no name-based kill; outer bash is not matched because `export` does not change `/proc/<pid>/environ`); Chrome has `--proxy-server=127.0.0.1:9` and `MAP * ~NOTFOUND`. VS Code is not network-blocked, but telemetry and update checks are off and the typed text goes only to the editor.
- Oracle: expected text comes from the golden TSV, not the engine; diff is char-exact (SequenceMatcher); missing file/empty readback/diff crash → FAIL. Defaults 5000 words, 15 ms, 3 runs, five targets.
- SEC-1 scan: stub/daemon logs, shell log, unit logs, sandbox HOME, runtime dir, own /tmp files, user and system journal; canaries NFC+NFD.
- Install scenario uses `VR_TALEX_BIN` and a `systemctl` stand-in earlier on PATH; kill-by-name stand-ins refuse.
- Python stdlib only; dbuslite raises on malformed data, no eval/exec/pickle.

## Files read
run.sh, lib.sh, install_scenario.sh, e2e.py, dbuslite.py (lines 1-200 plus grep for eval/imports), stub_ime.py (grep of logging, bind/umask only), fake_systemd.py, README.md, .gitignore — read. dbuslite.py 200-370 and stub_ime.py bodies: skipped — wire server and test stub, covered by the developer's offline checks.

## Rule check T9
| Rule | Result | Note |
|---|---|---|
| BASE-1 | pass | spec criteria mapped to checks; gaps above filed |
| BASE-5 | fail | silent SKIP/None-as-pass paths (findings 1, 3, 4) |
| BASE-6 | pass | notes carry real output |
| BASE-15 | pass | tag-based cleanup, no pkill/killall |
| BASE-19 | pass | stdlib only, no new dependency |

## Re-check fix round 1
Verdict: APPROVE. Read run.sh, lib.sh (guard, bus_id, summarize), the e2e.py hunks (judge_toggle/judge_combo, journal-unreadable path, pacing), install_scenario.sh head. `bash -n` and `py_compile` pass; harness not run.
- 1 AC-10: fixed per D24. Daemon/none report INCOMPLETE; `summarize` exits 1 on any SKIP/INCOMPLETE unless `--allow-incomplete`, a FAIL is never masked. The stub timing is now labelled `AC-10:stub`.
- 2 omnibox: fixed. A new tab per 40 lines, history read per chunk, short chunk reported; 135 lines / 4 tabs 8374/8374 in the notes.
- 3 None-as-pass: fixed (`judge_toggle`/`judge_combo` need readable values).
- 4 unreadable journal: fixed (exit 2 -> `SEC-1 INCOMPLETE`).
- 5 install scenario: fixed (needs a built daemon, sandbox CARGO_HOME/RUSTUP_HOME, never builds). Still not run end to end; reported INCOMPLETE until the frontends exist.
- 6 rate and guard: fixed (fixed-schedule pacing, mean asserted, exit 3 when too slow; live bus refused by recorded address and by server id).
- New: live-bus contact (SEC-29). The only contact is run.sh:65, `bus_id` = `gdbus call --session ... org.freedesktop.DBus.GetId`, run once in the outer shell before `iso_env`, and only when the caller already has DBUS_SESSION_BUS_ADDRESS (otherwise no call; the later `bus_id` calls in `guard` run on the sandbox bus, 5 s timeout). GetId is a bus-daemon method with no side effects and no service activation; it returns the bus's server id. No other gdbus/dbus-send/busctl call reaches the live bus (grep of run.sh, install_scenario.sh; the remaining `gdbus wait --session` calls run inside the sandbox). Harmless.
- [minor, optional] `E2E_LIVE_BUS` (live address) and `E2E_LIVE_BUS_ID` stay exported into the sandbox env, so the sandboxed apps and install.sh inherit a pointer to the live bus. No tool honours these names, so no reachable impact; unsetting them after the last guard-needed use is not possible (guard needs them), so leave as is or keep them in shell variables instead of exports.
