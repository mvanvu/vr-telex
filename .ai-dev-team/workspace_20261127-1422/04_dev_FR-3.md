# FR-3 VS Code integrated terminal: no lost letters at 15 ms/key

Mode: bug (reproduce first). Worktree: vr-talex-wt-FR3 (branch fr3-codeterm).

## Progress
- start: notes created; reading T5/T9 notes, QC report, decisions, e2e README.
- 1. read T5/T9 notes, QC report, D19-D28, e2e README, fe-ibus session.rs, ime-core rules.
- 2. release build of the worktree (base binary kept as qa-artifacts/FR-3/bin/vr-talex-base).
- 3. shipped xterm.js read from VS Code 1.145.2: `node_modules.asar` -> `@xterm/xterm` 6.1.0-beta.304, original `CompositionHelper.ts` and `CoreBrowserTerminal.ts` taken from the shipped source map (qa-artifacts/FR-3/xterm/, tools asar_get.py + map_get.py).
- 4. probe: qa-artifacts/FR-3/bin/code (wrapper first on PATH: `--remote-debugging-port=0` on the throwaway profile) + probe.py (CDP, records keydown/keypress/keyup/composition*/input on `.xterm-helper-textarea` plus a zero-delay timer per composition event) -> `logs/xterm-events.jsonl` per run.
- 5. REPRODUCED with the committed harness, base binary: run-20261125-000058 code-term lost 25/921; run-20261125-000511 (wire-trace build) lost 38/921.
- 6. ROOT CAUSE PROVEN (replay.py replays CompositionHelper over the recorded events): predicted output == actual output in both runs (19 stale-end finalizations = 25 chars; 20 = 38 chars). See "Root cause".
- 7. experiments with a temporary pacing build (bin/vr-talex-exp, source restored): running.

## Root cause (measured, not from memory)
What the terminal's textarea receives for one word typed through gnome-shell text-input-v3 (run-20261125-000058/logs/xterm-events.jsonl):
- a handled letter: `compositionupdate` + `input` only (no keydown; the key-up is forwarded);
- the word-ending key (CommitText, then the unhandled key): `compositionupdate(same text)`, `compositionend`, and the real `keydown` of the boundary key 0.2-1 ms later — in the same batch, 72 of 72 words; the zero-delay timers queued by those events have never run in between.
xterm.js 6.1 `CompositionHelper.keydown` then calls `_finalizeComposition(false)`, which cancels the timer path and sends `textarea.value.substring(start, _compositionPosition.end)`. `_compositionPosition.end` is only ever written by a `setTimeout(0)` queued in `compositionupdate`. In VS Code those timers lag behind input: measured lag p50 12 ms, p90 49 ms, max 142-153 ms at 15 ms/key (lag.py). Whenever the timer of the last letter has not run when the boundary key arrives, `end` is stale and the letters typed since the last timer run are never sent (whole word when no timer ran since `compositionstart`). Nothing is duplicated or replaced — exactly the reported symptom. The engine's wire order is correct; the defect is xterm.js reading a timer-maintained offset in a synchronous path.
Ruled out by measurement: SetCursorLocation as an acknowledgement (it arrives ~1 ms after a width-changing preedit while that update's timer is still pending, and not at all for a tone key), hide-before-commit (duplicates, T9), commit of word+boundary as text (expA: Enter and EN-mode keys still take the keydown path and cancel pending timer sends).
- 8. pacing experiments (temporary builds, exp.sh, 2 runs x 100 words each, code-term): hold until last-preedit+10 ms FAIL 25/25; +20 ms FAIL (9, 36 and 0, 7); +30/+60/+120 ms PASS 6/6; commit then hold the reply 20 ms / 50 ms PASS 4/4 (all words then go through xterm's timer path: replay finalize_timer 144/144).
- 9. implemented `Pacing {recent 100 ms, settle 40 ms}` in fe-ibus (tests/pacing.rs written first, red -> green); related tests + fmt + clippy green.
- 10. e2e with that build: code-term 3 runs PASS (proof-codeterm-plain.out), then 3 sessions where runs 1-2 PASS and run 3 FAILS (lost 17/extra 13, lost 26/extra 5, lost 22/extra 8) and gnome-terminal 1 run FAIL lost 1/extra 1 = a REORDER ("kháp de " typed, space after "kháp" arrived after "de"). Another agent's headless e2e session ran on the machine at the same time (load 2-6).
- 11. cause of the reorder: keys queued behind a held reply are answered at once when the hold ends, so the CommitText of the next short word follows the "not handled" reply within microseconds; gnome-shell forwards an unhandled key later than it applies IM signals, so the commit overtakes the key. Running: experiment with a 20 ms quiet gap after a held reply (bin/vr-talex-exp2, proof3.sh).
- 12. gap experiment (hold 40 ms + 20 ms quiet after the held reply): code-term 3 runs: FAIL lost 9/extra 2, FAIL lost 45/extra 11/replaced 6, PASS (machine load 7-9); second session PASS 3/3 (load ~3); term/chrome/omnibox/code PASS; term 3 runs: 2 PASS, 1 "injection too slow" (load).
- 13. DECISION: pacing is NOT kept. It is a timing mitigation of a client defect: lossless only on a quiet machine, and when it fails it produces extra/replaced/reordered text, which the base never does, in apps that are lossless today. Prototype saved as qa-artifacts/FR-3/pacing-prototype.patch (+ pacing-prototype-tests.rs); the tree is back to the base for session.rs / server.rs / tests. Result for the main goal: BLOCKED (needs-user-decision), see "Outcome".
- 14. ride-alongs done test-first on the branch: lock file opened with O_NOFOLLOW (address.rs); review finding 3 (lib.rs: no display under systemd -> Err after 7 s instead of "not needed").
- 15. final tree: `cargo test -p fe-ibus -p ime-core --locked` green, fmt + clippy green, release build, sanity e2e (term, chrome 30 words, AC-3) PASS. Nothing left running; run sandboxes and temporary binaries removed from qa-artifacts/FR-3.

## Outcome: BLOCKED FR-3 needs-user-decision (VS Code terminal at 15 ms/key)
The loss is inside xterm.js (proven by replay, see Root cause) and no engine-side remedy keeps the anti-goals:
- the protocol (IBus -> gnome-shell -> text-input-v3) gives the engine no acknowledgement that the client finished the composition, and the unhandled boundary key is always delivered right behind the commit;
- pacing in the daemon (the only lever left) was built and measured: totals with `recent 100 / settle 40`: code-term 9 of 12 runs lossless; with the extra 20 ms gap 4 of 6; base 0 of 4. Its failures add extra/replaced characters and it produced one reordered space in gnome-terminal; it also needs the AC-10 round-trip test to exclude the pause (p99 < 5 ms no longer holds for word-ending keys typed fast).
Options: (A, proposed) accept as a client limitation, report upstream (xterm.js `CompositionHelper._finalizeComposition(false)` should read `textarea.selectionEnd` itself instead of the timer-maintained `_compositionPosition.end`), AC-2 for code-term stated at >= 30 ms/key (QC: 0 lost at 30 and 40 ms); human typing (80-120 ms/key) is far from the threshold, only a last letter and the boundary key pressed within ~15-30 ms of each other can lose that letter. (B) ship the pacing prototype knowing the above. (C) word + boundary character as one commit (D26c, changes key semantics, Enter still lossy). (D) hold mode for this client (needs a user switch; the engine cannot tell the terminal from the editor).

## Files changed (final tree)
- crates/fe-ibus/src/address.rs — `open_lock` with O_NOFOLLOW + test `the_lock_is_never_opened_through_a_link`
- crates/fe-ibus/src/lib.rs — `without_display` (+ `NO_DISPLAY_WAIT`), tests `outside_systemd_a_start_without_a_display_means_not_needed`, `under_systemd_a_start_without_a_display_fails_after_a_wait`
- crates/fe-ibus/Cargo.toml — rustix feature `fs` (Cargo.lock unchanged)

## Commands (trimmed)
```
$ run.sh --ime daemon --apps code-term --runs 1 --words 100 (base)   -> FAIL lost 25/921 ; second run FAIL lost 38/921
$ python3 replay.py <xterm-events.jsonl> <code-term-1.txt>
events 3794 {'finalize_now': 72, 'finalize_timer': 0, 'commits': 72, 'keydown_while_sending': 72}
stale-end finalizations: 19 chars lost by them: 25      (predicted text == actual text, apart from the final Ctrl+D letter)
$ python3 lag.py  -> timers 608 p50 12.8 p90 49.0 p99 97.8 max 141.7
$ cargo test -p fe-ibus -p ime-core --locked   -> 25 + 12 + 1 + 13 + 15 (fe-ibus), 1 + 13 + 6 + 4 + 8 + 11 (ime-core) passed, 0 failed
$ cargo fmt --check -> ok ; cargo clippy --workspace --all-targets --locked -- -D warnings -> Finished
$ run.sh --apps "term chrome" --words 30 --scenarios focus (final tree) -> term PASS 555/555, chrome PASS 555/555, AC-3 PASS, SEC-1 0 hits
red first: the_lock_is_never_opened_through_a_link FAILED before O_NOFOLLOW; under_systemd_a_start_without_a_display_fails_after_a_wait FAILED before the change
```

## Deviations / out of scope
- Main goal not met (BLOCKED above); no fe-ibus/ime-core behaviour change for typing was kept.
- Review finding 3: the fix returns Err after a 7 s wait under systemd (NOTIFY_SOCKET set). The 7 s is tied to the unit's current RestartSec=1 / StartLimitBurst=10 in 60 s / TimeoutStartSec=10; if FR-5 changes those, `NO_DISPLAY_WAIT` should be re-checked. While it waits the daemon has not sent READY and fe-fcitx already serves; on failure the whole daemon restarts (D22). Not proven under a real systemd user manager (unit tests only).
- e2e noise: another agent's headless session ran in parallel during several runs (load up to 9 on 8 cores); one smoke run delivered 0 characters to every target with gnome-terminal failing to start ("Error creating terminal") — environment, not reproduced.

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| CDP client for VS Code | tests/e2e/e2e.py | reused `cdp_targets`, `WebSocket` in the throwaway probe |
| e2e runs | tests/e2e/run.sh | reused unchanged (wrapper `code` first on PATH for the probe) |
| O_NOFOLLOW constant | rustix (workspace dependency) | `rustix::fs::OFlags::NOFOLLOW`, feature `fs` |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 scope | pass | final diff: fe-ibus only (address.rs, lib.rs, Cargo.toml); ride-alongs named by the leader |
| BASE-3 contracts | pass | ime-core untouched; `run` contract text updated for the systemd case |
| BASE-7/24 no commit | pass | `git status --short`: 3 modified files, nothing staged |
| BASE-14 background | pass | long e2e runs as background tasks, no polling |
| BASE-15 stop own only | pass | no kill by name; harness tagged cleanup only |
| BASE-16 reuse | pass | table above |
| BASE-17 no installs | pass | nothing installed |
| BASE-18 no sub-agents | pass | none started |
| BASE-19 notes | pass | this file from the first step |
| BASE-25 guard | pass | fmt + clippy output above |
| BASE-37 reporter's steps | pass | committed harness before (lost 25, 38) and with the prototype (numbers above) |
| BASE-38 formatters | pass | rustfmt only on changed files |
| other BASE rules | n-a | no UI, no removal, no data, no external service |
| COST-1..20 | pass | heavy commands through run-heavy.sh; related tests only; scripts in qa-artifacts/FR-3; sandboxes and temp binaries deleted; nothing left running |
| SEC-1/2 | pass | no logging added; error text static; probe logs hold synthetic corpus only, under qa-artifacts |
| SEC-4 | pass | no new buffers of typed text |
| SEC-8/15/16 | pass | session.rs/server.rs/socket.rs unchanged; security.rs 15 passed |
| SEC-7 (lock) | pass | `the_lock_is_never_opened_through_a_link` |
| AC-2 code-term | fail -> BLOCKED | see Outcome |
