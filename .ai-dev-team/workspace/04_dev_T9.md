# T9 E2E stress harness

## Progress
- 1. Started: notes created; reading spike T1, spec §6, decisions, threat model.
- 2. Read: spec §6, spike T1 (whole), D2/D12/D19/D20, SEC-1/SEC-29, T1 lib.sh/rd.py/fake_systemd.py/fake_ibus.py/q3-q5. No daemon binary yet (target/release/vr-talex absent; frontends are stubs). install.sh/uninstall.sh absent (T8 in progress).
- 3. Design: stdlib-only D-Bus wire module (client + p2p server) replaces PyGObject of the spike; stub IBus engine (golden-list lookup Telex, Ctrl+Shift toggle, password passthrough, commit on focus-out) for --smoke; Chrome readback via CDP (stdlib WebSocket); systemctl/kill-by-name shims for the install scenario.
- 4. Wrote tests/e2e/dbuslite.py, stub_ime.py, fake_systemd.py, e2e.py (corpus, inject, cdp, diff, leakscan, latency). Next: lib.sh + run.sh, then smoke.
- 5. Wrote lib.sh, run.sh, install_scenario.sh. Offline check qa-artifacts/T9/unit_check.py: wire round trip, corpus, stub engine (commit, toggle, Ctrl+Shift+T no toggle, password passthrough, FocusOut commit, IC ownership, no text in log) all pass. Next: first smoke run (background).
- 6. Smoke 1: shell aborted, Wayland socket path > 108 bytes (runtime dir under the run dir); moved XDG_RUNTIME_DIR to mktemp /tmp/vrt-e2e.XXXXXX (0700, removed at end). The abort left /var/crash/_usr_bin_gnome-shell.1000.crash (20:23) — not removed (outside scope), reported to the leader.
- 7. Smoke 2: Eval called before /org/gnome/Shell existed -> early teardown aborted the shell. Fix: retry Eval until (true, …) for 30 s; cleanup stops the shell first.
- 8. Smoke 3: harness end to end works (term 734/734, chrome 734/734, AC-7, AC-4, SEC-1 pass); AC-3 click-away LOST the word with the stub's preedit mode CLEAR + engine commit on FocusOut (window switch kept it). Trying preedit mode COMMIT (client commits on focus loss) in the stub; finding for T5.
- 9. Smoke 4 (stub preedit mode COMMIT): all 7 checks PASS, rc=0. Next: short run of omnibox/code/code-term; guard and diff negative checks.
- 10. Short run omnibox/code/code-term (stub): omnibox PASS 639/639, code PASS 639/639, code-term FAIL lost 3 (duệch->duệ, đoẽn->đoẽ: letters after the vowel lost by xterm.js composition). Rechecking code-term with --ime none (harness alone) and stub again.
- 11. code-term recheck: `--ime none` 2/2 PASS 679/679 (harness lossless into xterm.js); `--ime stub` 2/2 FAIL (lost 1/extra 4, lost 3/extra 3: letters after the vowel dropped, a whole word duplicated). Engine-strategy finding, not a harness defect (see Findings).
- 12. T8's install.sh/uninstall.sh appeared (20:24–20:26). Read them: they find processes through the sandbox bus and `systemctl --user show -p MainPID`; the systemctl stand-in now answers `show -p MainPID --value`, and the VR_TALEX_BIN seam is used. Stand-ins checked offline (qa-artifacts/T9/shim_check.sh). The install scenario itself was not run: the daemon's frontends are stubs, so install's health check (vr-talex owns org.fcitx.Fcitx5) cannot pass yet.
- 13. Guards: bash -n on 3 scripts, py_compile on 4 modules — ok. Throwaway sandbox homes of the runs removed (qa-artifacts/T9 = 620K). Nothing left running: 0 /tmp/vrt-e2e.* dirs, the stand-in test process is gone.

# Result
- Files changed (all new): tests/e2e/run.sh, tests/e2e/lib.sh, tests/e2e/install_scenario.sh, tests/e2e/e2e.py, tests/e2e/dbuslite.py, tests/e2e/stub_ime.py, tests/e2e/fake_systemd.py, tests/e2e/README.md, tests/e2e/.gitignore
- Throwaway (not repo): qa-artifacts/T9/unit_check.py, qa-artifacts/T9/shim_check.sh, run dirs qa-artifacts/T9/run-*/ (logs + out), smoke-*.out, apps-1.out, codeterm.out
- Tests added: the harness itself (`tests/e2e/run.sh --smoke`); offline checks above.

## Design
- Stdlib only. `dbuslite.py` is a small D-Bus wire implementation (EXTERNAL auth on both sides, all types, calls and signals), so the spike's PyGObject use is gone. `e2e.py` subcommands: corpus, inject (RemoteDesktop keysyms, Ctrl+Shift tap, click by relative pointer motion), cdp (stdlib WebSocket: eval, new/close/activate tabs, navigation history), diff (char-exact, first mismatches with line/col/context, lost/extra/replaced counts), leakscan, toggle-check, latency.
- Sandbox: `dbus-run-session`, HOME/XDG_* under `<run>/sandbox`, XDG_RUNTIME_DIR = `mktemp -d /tmp/vrt-e2e.XXXXXX` (the Wayland socket path must be < 108 bytes; removed at the end), keyfile GSettings. `guard` before every launch (exit 97). Teardown stops the shell first, then exactly the processes carrying the run's `VRT_E2E_TAG`.
- Engines: `--ime daemon` (target/release/vr-talex or VR_TALEX_BIN, RUST_LOG=trace, stderr captured), `--ime stub` (stub_ime.py: one-service IBus pseudo bus on a private 0600 socket, golden-lookup Telex, toggle + indicator, password passthrough, unicast signals, IC ownership check), `--ime none`.
- Targets: term (gnome-terminal `cat > file`), chrome (textarea via CDP), omnibox (one search per line, read from the tab's navigation history; proxy = closed local port and every host unresolvable, so nothing leaves the machine), code (auto-saved file), code-term (VS Code terminal profile runs `cat > file`, opened with F9).
- Scenarios: AC-7 password input; AC-4 (toggle timing by Shell.Eval polling; Ctrl+Shift+P/C/V seen by the page, Ctrl+Shift+T proven by Chrome reopening a closed tab; mode unchanged); AC-3 (window switch, and a real pointer click on another element); AC-5/AC-6 install scenario (systemctl stand-in runs ExecStart; kill-by-name stand-ins refuse); AC-10 latency; SEC-1 leak scan (20 per-run canaries + 20 distinctive VI words composed and raw, NFC+NFD, over the sandbox HOME, the runtime dir, own /tmp files since start, engine/shell/unit logs, `journalctl --user` and the system journal since start; app profiles excluded).
- Corpus: seeded sample of the golden list (VI words typed in VI mode; the English section in EN mode with a Ctrl+Shift tap before and after); only the generator is stored.

## Commands run + result (trimmed real output)
```
$ AI_DEV_TEAM_TIMEOUT=900 $TEAM_BIN/run-heavy.sh bash tests/e2e/run.sh --smoke --out $TEAM_WS/qa-artifacts/T9   (smoke 4, rc=0)
shell up: GNOME Shell 46.0
ime (stub) connected after ~0 s: vr-talex|VI
corpus: 60 words in 7 lines, 40 typed in EN mode, 20 canaries, 20 scan words, seed 20261124
RESULT AC-2:term-1 PASS  expected 734 chars, got 734; lost 0, extra 0, replaced 0
RESULT AC-2:chrome-1 PASS  expected 734 chars, got 734; lost 0, extra 0, replaced 0
RESULT AC-7 PASS password field got matkhau1s raw
RESULT AC-4 PASS toggle PASS: VI->EN 2 ms, EN->VI 3 ms;combos PASS: Ctrl+Shift+P/C/V/T left the mode at VI; page saw Ctrl+Shift+[P,C,V]; pages 1 -> 2 after Ctrl+Shift+T
RESULT AC-3 PASS window switch: [việt] expected [việt]; click elsewhere (focus moved to #o): [đường] expected [đường]
RESULT AC-10 PASS (stub-ime): 3541 keys, p50 103.4 us, p99 1986.6 us, max 13348.2 us -> PASS (AC-10: p99 < 5000 us)
RESULT SEC-1 PASS SEC-1 leak scan: 60 tokens, 247 files, 119 journal lines since the run started, 0 hits
cleanup: stopped 21 tagged processes
e2e: exit 0
```
Injection rate: `inject: 816 keys in 16754 ms (20.5 ms/key)` at --delay 0.015.
```
$ run.sh --ime stub --apps "omnibox code code-term" --runs 1 --words 40 --scenarios ""
RESULT AC-2:omnibox-1 PASS  expected 639 chars, got 639; lost 0, extra 0, replaced 0
RESULT AC-2:code-1 PASS  expected 639 chars, got 639; lost 0, extra 0, replaced 0
RESULT AC-2:code-term-1 FAIL  expected 639 chars, got 636; lost 3, extra 0, replaced 0
  line 3 col 22 delete: after [onitor vpn Reply duệ] expected [ch] got []
$ run.sh --ime none --apps code-term --runs 2 --words 40 --scenarios ""   -> code-term-1 PASS 679/679, code-term-2 PASS 679/679
$ run.sh --ime stub --apps code-term --runs 2 --words 40 --scenarios ""   -> FAIL (lost 1, extra 4) / FAIL (lost 3, extra 3)
  line 1 col 32 delete: after [ẩu choằn hẩn ngấm đẹ] expected [p] got []
  line 1 col 66 insert: after [FY Build thãng hiệm ] expected [] got [phẵm]
```
Negative checks: `e2e.py diff` on a changed file -> `FAIL neg: expected 18 chars, got 19; lost 0, extra 1, replaced 1`, rc 1; `guard` with the live HOME/runtime/bus -> `GUARD: live desktop values in use (HOME XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS ...), abort`, rc 97.
Offline: unit_check.py -> `1 wire round trip ok`, `2 corpus ok`, `3 stub engine ok` (commit, toggle, Ctrl+Shift+T no toggle, password passthrough, FocusOut commit in clear mode, foreign IC -> AccessDenied, no text in log). shim_check.sh -> enable --now starts the unit, `show -p MainPID` gives its pid, stop -> MainPID 0, system manager call rc 1, kill-by-name stand-in rc 1.
Guard: `bash -n` ok on run.sh, lib.sh, install_scenario.sh; `python3 -m py_compile` ok on dbuslite.py, e2e.py, fake_systemd.py, stub_ime.py.

## Findings for the leader (input to T5/T6, not fixed here)
1. AC-3 click-away: with preedit mode CLEAR (0) and the engine committing on FocusOut, Chrome LOST the word on a pointer click (smoke 3: `click elsewhere: [] expected [đường]`); a window switch kept it. With mode COMMIT (1) — the client commits its own preedit on focus loss and the engine only drops its buffer — both pass (smoke 4). fe-ibus should send UpdatePreeditTextWithMode with mode 1 (gnome-shell sets ClientCommitPreedit) and must not send CommitText again on FocusOut/Reset.
2. VS Code integrated terminal (xterm.js) loses and duplicates characters with preedit + commit at 15 ms/key (letters after the composed vowel dropped, a word repeated) while raw keys pass 2/2. This is the spec's "nuốt chữ" case on one AC-2 target; T5 needs a strategy for it. Evidence: qa-artifacts/T9/codeterm.out, run-20261124-203148-347872/out/diff-code-term-*.txt.
3. /var/crash/_usr_bin_gnome-shell.1000.crash (20:23) was written by apport when smoke 1's headless shell aborted (socket path too long). Left in place (outside scope); it may raise an Ubuntu problem-report prompt on the live desktop.
4. AC-10 with the real daemon: no per-key timing output exists. Question: will T4/T5 expose one (counts and a latency histogram, no text)? Until then `--ime daemon` reports AC-10 SKIP.
5. Install scenario (AC-5/6) not run: needs a daemon whose frontend owns org.fcitx.Fcitx5 (install.sh health check).
6. capabilities.md is not my file — proposed lines: "E2E harness: isolated headless GNOME + RemoteDesktop injection + per-app readback/diff — tests/e2e/run.sh (T9)"; "stdlib D-Bus wire client/server — tests/e2e/dbuslite.py (T9)"; "stub IBus engine (golden lookup) — tests/e2e/stub_ime.py (T9)".

## Deviations
- D12 Chrome via CDP: used (stdlib WebSocket) for the textarea, password field and page key log; the address bar is read from the tab's navigation history.
- Smoke includes the AC-3/4/7 scenarios (cheap once Chrome is up); the install scenario is off in smoke.
- Stub preedit default = COMMIT (`E2E_STUB_PREEDIT=clear` gives the other behaviour).

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| sandbox env, guard, tagged cleanup, wait_win | qa-artifacts/T1/lib.sh | ported to tests/e2e/lib.sh (runtime dir in /tmp, stricter guard, Eval retry) |
| RemoteDesktop injector + warm-up | qa-artifacts/T1/rd.py | ported to e2e.py Injector on stdlib dbuslite (no PyGObject) |
| systemd stand-in | qa-artifacts/T1/fake_systemd.py | ported to stdlib tests/e2e/fake_systemd.py |
| fake IBus engine | qa-artifacts/T1/fake_ibus.py (libibus/gi) | rewritten stdlib as stub_ime.py with golden-lookup Telex |
| app flags, test page, VS Code settings | 03_spike.md Q1/Q4, q4.sh | reused |
| corpus source | crates/telex-core/tests/golden/telex_golden.tsv | reused |
| capabilities index | .ai-dev-team/capabilities.md | nothing e2e-related existed |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 scope | pass | only tests/e2e/** created; team files in $TEAM_WS |
| BASE-5 heavy via run-heavy, nothing left running | pass | every run through run-heavy.sh; `cleanup: stopped 21 tagged processes`; 0 /tmp/vrt-e2e.* left |
| BASE-7/24 no git add/commit | pass | no git write commands |
| BASE-10 related tests + guards only | pass | smoke + short app runs + bash -n/py_compile; no cargo suite |
| BASE-11 shared tree | pass | crates/**, install.sh, uninstall.sh, packaging/** read only |
| BASE-14 no waiting loops | pass | runs as background tasks; harness loops are bounded readiness waits inside a run |
| BASE-15 stop only own processes | pass | tag/pid cleanup; kill-by-name tools replaced by refusing stand-ins in the install sandbox |
| BASE-16 reuse | pass | Reuse table |
| BASE-17 install nothing | pass | stdlib + installed tools only |
| BASE-18 no sub-agents | pass | none started |
| BASE-19 notes from the start | pass | progress lines 1–13 |
| BASE-21 redact secrets | pass | no secrets; typed text is a synthetic corpus |
| BASE-22 naming | pass | snake_case modules; run.sh/lib.sh as in the spike |
| BASE-23 test per entry path | pass | one check per target and per scenario |
| BASE-34 / DESIGN-23 endpoints, User-Agent | pass | only local CDP; Chrome proxy to a closed port, hosts unresolvable; no UA change |
| other BASE rules | n-a | no UI, API, data model, migrations or dependencies |
| COST-8 edits | pass | files written whole; edits by Edit / perl -pi |
| COST-9 nothing left running | pass | see BASE-5 |
| COST-10 related set | pass | the task's own command only |
| COST-13 throwaway scripts | pass | qa-artifacts/T9/unit_check.py, shim_check.sh |
| other COST rules | n-a | no builds; browsers only inside harness runs |
| SEC-29 / D2 isolation | pass | guard (rc 97 negative check), dbus-run-session, sandbox HOME/XDG/runtime; the live bus was never used |
| SEC-1 leak scan | pass | `SEC-1 leak scan: 60 tokens, 247 files, 119 journal lines ..., 0 hits`; stub log carries method names and counts only (unit_check asserts) |
| D12 RemoteDesktop injection | pass | `inject: 816 keys in 16754 ms (20.5 ms/key)` |
| AC-2 harness | pass (stub) | term/chrome/omnibox/code PASS; code-term FAIL is an engine finding (`--ime none` PASS) |
| AC-3 / AC-4 / AC-7 checks | pass (stub) | smoke 4 RESULT lines |
| AC-5 / AC-6 scenario | n-a (not-run) | daemon frontends not built; skips cleanly with --skip-install or while scripts are absent |
| AC-10 | pass (stub) / n-a (daemon) | stub p99 1986.6 us; daemon has no timing output (finding 4) |

# Fix round 1 (review 05_review_T9.md, CHANGES_REQUESTED; leader decision D24)
Red first: qa-artifacts/T9/fix1_check.py and fix1_check.sh, run before the change:
```
FAIL 3a judge_toggle exists
FAIL 3f judge_combo exists
FAIL 4a unreadable journal -> exit 2 (rc=0)
FAIL 4b detail says unreadable (SEC-1 leak scan: 1 tokens, 0 files, 0 journal lines since the run started, 0 hits)
AttributeError: 'Injector' object has no attribute 'reset_pacing'
FAIL guard abstract live bus (rc=0: passed)
FAIL summarize() missing
```
After the change, all green:
```
ok   3a..3i (None before/after fails toggle and combo; VI->EN 2 ms passes; 150 ms fails)
ok   4a unreadable journal -> exit 2 (rc=2)
ok   4b detail says unreadable (... 0 hits; user journal unreadable; system journal unreadable)
ok   6a mean ms/key within 15 +- 1 with 3 ms per call (14.99 ms)
ok   6b too slow is detected (20.40 ms)
ok   guard refuses the live bus in abstract form
ok   incomplete run fails by default / --allow-incomplete passes it / a FAIL still fails with --allow-incomplete
```
| # | Finding | Reply | Change |
|---|---|---|---|
| 1 | SKIP counted as success; AC-10 SKIP for daemon | fixed | lib.sh `summarize`: any SKIP/INCOMPLETE prints `INCOMPLETE: <checks>` and exits 1 unless `--allow-incomplete` (a FAIL always exits 1). run.sh: daemon -> `AC-10 INCOMPLETE measured in unit tests (D24 ...)`, none -> INCOMPLETE; the stub's own timing is now `AC-10:stub` |
| 2 | omnibox history cap | fixed | run.sh omnibox: a new tab per `--omnibox-chunk` lines (default 40), history read per chunk, short chunks reported. Proof: 135 lines in 4 tabs -> `RESULT AC-2:omnibox-1 PASS expected 8374 chars, got 8374; lost 0, extra 0, replaced 0` (qa-artifacts/T9/omnibox-fix1.out, 360 s). No red run at >50 lines in one tab (would cost ~6 more minutes); the fix does not depend on the exact cap |
| 3 | None from shell_eval passes | fixed | e2e.py `judge_toggle` / `judge_combo` require readable VI/EN values; `shell_eval` returns None on D-Bus errors |
| 4 | unreadable journal = clean scan | fixed | leakscan: non-zero journalctl exit or an exception -> "<user/system> journal unreadable" in the detail, exit 2; run.sh maps exit 2 to `SEC-1 INCOMPLETE` |
| 5 | install scenario: Chrome, 5 s, live ~/.cargo | fixed | requires a built daemon (else `AC-5/AC-6 INCOMPLETE`), passes VR_TALEX_BIN, CARGO_HOME/RUSTUP_HOME in the sandbox, never builds; asserts install rc 0 and engine connected <= 5.0 s after install returns; types `vieetj ` in a newly started Chrome (restarts the harness' Chrome) expecting `việt `. Still not run end to end (daemon frontends not built) |
| 6 | 20.5 ms/key, unasserted; abstract live bus | fixed | Injector paces on a fixed schedule (call cost absorbed), reports `mean X ms/key ... RATE OK/TOO SLOW`, exits 3 when mean > delay + 1 ms; check() fails the AC-2 result on a slow injection and shows the mean. Guard: refuses the recorded live address string and, by server id (read-only GetId taken before sandboxing), the live bus in any address form |

## New states (round 1)
- INCOMPLETE result state: produced by AC-10 (daemon/none), SEC-1 (journal unreadable), install scenario without binary; tested by fix1_check.sh summarize cases (incomplete fails by default, allowed with the flag, FAIL never masked).
- Pacing schedule: a gap (toggle, pause, slow call) restarts the schedule from now, so a stall never causes a burst of keys to catch up; tested by fix1_check.py 6a/6b.
- Omnibox chunk tabs: each chunk tab is closed after its history is read; a chunk that reads back fewer searches is printed and the diff fails.

## Commands (fix round 1, trimmed)
```
$ run-heavy.sh bash tests/e2e/run.sh --ime stub --apps omnibox --runs 1 --words 1500 --scenarios "" ...   rc=0
corpus: 1500 words in 135 lines, 482 typed in EN mode, 20 canaries, 20 scan words, seed 20261124
RESULT AC-2:omnibox-1 PASS  expected 8374 chars, got 8374; lost 0, extra 0, replaced 0; mean 15.0 ms/key (x4 chunks)
$ run-heavy.sh bash tests/e2e/run.sh --smoke --out $TEAM_WS/qa-artifacts/T9   rc=0
inject: 816 keys in 13910 ms; mean 15.0 ms/key over 790 taps (target 15.0) RATE OK
RESULT AC-2:term-1 PASS  expected 734 chars, got 734; lost 0, extra 0, replaced 0; mean 15.0 ms/key
RESULT AC-2:chrome-1 PASS  expected 734 chars, got 734; lost 0, extra 0, replaced 0; mean 15.6 ms/key
RESULT AC-7 PASS password field got matkhau1s raw
RESULT AC-4 PASS toggle PASS: VI->EN 5 ms, EN->VI 1 ms;combos PASS: Ctrl+Shift+P/C/V/T left the mode at VI; page saw Ctrl+Shift+[P,C,V]; pages 1 -> 2 after Ctrl+Shift+T
RESULT AC-3 PASS window switch: [việt] expected [việt]; click elsewhere (focus moved to #o): [đường] expected [đường]
RESULT AC-10:stub PASS (stub-ime): 3541 keys, p50 136.6 us, p99 786.0 us, max 3022.6 us
RESULT SEC-1 PASS SEC-1 leak scan: 60 tokens, 164 files, 101 journal lines since the run started, 0 hits
cleanup: stopped 21 tagged processes
e2e: exit 0
```
Guards: `bash -n` ok (run.sh, lib.sh, install_scenario.sh); `python3 -m py_compile` ok (4 modules). Nothing left running: 0 /tmp/vrt-e2e.* dirs; run sandboxes removed.

## Rule compliance (rows changed in round 1)
| Rule | Status | Evidence |
|---|---|---|
| BASE-5 no silent pass | pass | INCOMPLETE + non-zero exit (fix1_check.sh); None fails (fix1_check.py 3b/3c/3g); unreadable journal -> INCOMPLETE (4a/4b) |
| SEC-29 guard | pass | live bus refused by address and by server id (fix1_check.sh "guard refuses the live bus in abstract form") |
| SEC-1 | pass | smoke: 0 hits, both journals read; unreadable path tested |
| AC-2 rate (15 ms/key) | pass | smoke `mean 15.0` / `15.6 ms/key ... RATE OK`; omnibox 4x `mean 15.0 ms/key` |
| AC-2 omnibox at size | pass | 135 lines, 8374/8374 chars |
| AC-10 | n-a in e2e (INCOMPLETE by D24) | evidence lives in the ime-core latency and fe round-trip tests |
| AC-5 / AC-6 | n-a (not-run) | needs the daemon frontends; scenario now reports INCOMPLETE instead of SKIP |
| BASE-11 / BASE-17 | pass | the install scenario can no longer touch the live ~/.cargo |
