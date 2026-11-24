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
