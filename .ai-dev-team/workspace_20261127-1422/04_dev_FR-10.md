# FR-10 Bug: a word in progress in gnome-terminal (GTK3 im-wayland via gnome-shell) is lost on FocusOut
Worktree /home/rainy/DEV/vr-talex-wt-FR10 (branch fr10-focusout from master 397d988). Mode: bug. Side: be.

## Progress
- 1. notes created; read 04_dev_FR-7.md (Problem found), 04_dev_T5.md (AC-3 design, fix round 1).
- 2. read sources: gnome-shell 46 inputMethod.js (qa-artifacts/FR-7/gs/), mutter 46.2 meta-wayland-text-input.c, clutter-input-focus.c, clutter-input-method.c and GTK 3.24.41 modules/input/imwayland.c downloaded to qa-artifacts/FR-10/src/ (public sources, read only).
- 3. source reading (hypothesis, to be proven): mutter commits a COMMIT-mode preedit itself in clutter_input_focus_reset (clutter-input-focus.c:103-122), called (a) on a text-input focus change (meta-wayland-text-input.c:401, before `leave`), (b) when the client disables text-input (text_input_commit_state, :671), (c) on a click in the focused surface (:930). In (b) the client has already left: GTK3 imwayland focus_out -> disable() clears its own preedit and sets global->current = NULL (imwayland.c:632-650, 838-849), and text_input_done returns early when current is NULL (:295) -> a commit_string arriving after the client's own focus-out is dropped by GTK3, whoever sends it (mutter's reset commit, or a CommitText from the engine relayed by the shell). Probe FR-7 probe7: every lost word coincides with the end of an `e2e.py inject` (RemoteDesktop Stop removes the only keyboard of the headless seat).
- 4. probe written: qa-artifacts/FR-10/{gtk3probe.py,make_probe.py,run_probe.sh} (GTK3 TextView with WAYLAND_DEBUG=client + gnome-terminal; c1 end of injection, c2 Ctrl+Space with keyboard kept, c3 window switch with keyboard kept). Baseline release build running.
- 5. probe with the master binary (qa-artifacts/FR-10/probe-base.log, wire in out-base/*/out/gtk3-wl.log): gnome-terminal got [1 viêt2 đường3 ], GTK3 TextView got [1 viêt2 đường3 ] (expected viêt1 viêt2 đường3) -> ONLY c1 (word left in preedit when the injection ends) loses; c2 Ctrl+Space and c3 window switch with the keyboard kept keep the word in both clients. Wire of c1 (gtk3-wl.log:3897-3918): wl_keyboard.leave, wl_seat.capabilities(0) (the RemoteDesktop session's virtual keyboard was the seat's only keyboard), client -> disable()+commit(), THEN Mutter's reset sends commit_string("viêt") + done(9): GTK3 has already set current=NULL and dropped its preedit -> word lost inside the client. c2 (:4179-4192): commit_string("viêt") before wl_keyboard.leave/text_input.leave -> kept. c3 (:4687-4700): wl_keyboard.leave, commit_string("đường"), text_input.leave -> kept (GDK queues the focus event; text-input events are handled first).
- 6. ROOT CAUSE: not fe-ibus. The loss is the harness's injection teardown (headless seat loses its only keyboard; GTK3 im-wayland disables and drops what the compositor commits afterwards). Mutter does commit the COMMIT-mode preedit (the T5 design works). No engine-side change can recover it: the commit Mutter sent reached the client and was dropped; an engine CommitText would come later through the same shell->Mutter path, after the Clutter focus is gone.
- 7. harness: e2e.py inject key spec `EVAL:js` (shell JS inside the session, keyboard kept); run.sh scenario `focus-kept` (AC-3:chrome-kept, AC-3:term: window switch, click on another window, Ctrl+Space mid-word), added to the default scenario list. Run with the unchanged master daemon (qa-artifacts/FR-10/focus-1.out): AC-3, AC-3:chrome-kept, AC-3:term PASS.
- 8. experiment binary (temporary local edit session.rs:807-808 to `Reset => false, FocusOut => false`, i.e. the engine also sends CommitText to ClientCommitPreedit clients; built, copied, edit reverted with the Edit tool, release rebuilt and `cmp` equal to the master build): focus + focus-kept all PASS (focus-expcommit.out: the shell drops that late commit, no double), probe c1 STILL lost in both clients (probe-expcommit.log: terminal [1 viêt2 đường3 ], gtk3 [1 viêt2 đường3 ]; out-expcommit gtk3-wl.log:2807-2825 disable() then commit_string("viêt") ignored). => no engine-side behaviour recovers the c1 loss; the experiment would also bring back the Qt 5 Reset double (T5 fix round 1). Decision: keep the FocusOut/Reset rule unchanged.
- 9. protocol test `gnome_shells_focus_out_in_a_terminal_leaves_the_word_to_the_compositor` (the exact inputMethod.js focus-out sequence with purpose TERMINAL): green on master; FAILS against the rejected alternative (test-vs-expcommit.txt: left [Commit("viêt"), hide] right [hide]).
- 10. README: focus-kept and the end-of-injection keyboard loss documented. Final runs below. Experiment binaries and sandbox homes removed.

# Result
Root cause: not in fe-ibus and not reachable on a desktop with a keyboard. The FR-7 losses all happen when an `e2e.py inject` ends with a word in preedit: RemoteDesktop Stop removes the headless seat's only keyboard (wl_seat.capabilities(0)), GTK3 im-wayland disables text input and drops its preedit (imwayland.c disable(), :632-650; text_input_done returns while current==NULL, :295), and the commit_string that Mutter's clutter_input_focus_reset sends right after is ignored. With the keyboard kept, window switch, click on another window and Ctrl+Space keep the word in gnome-terminal and a GTK3 TextView with the unchanged master daemon.
Fix: no product change. Harness: `EVAL:js` key spec + `focus-kept` scenario (AC-3:term, AC-3:chrome-kept), in the default list; README note. Characterization protocol test added.

- Files changed: crates/fe-ibus/tests/protocol.rs (+37, new test), tests/e2e/e2e.py (EVAL spec), tests/e2e/run.sh (focus-kept scenario, default list, usage), tests/e2e/README.md. crates/fe-ibus/src/** unchanged (`git diff --stat`).
- Tests added: protocol.rs `gnome_shells_focus_out_in_a_terminal_leaves_the_word_to_the_compositor`; e2e scenario `focus-kept`.
- Deviations: the brief asked for a test first for the chosen FocusOut behaviour; the evidence chose the current behaviour, so the new test is green on master and its red is shown against the rejected alternative (test-vs-expcommit.txt). Qt5 replay not run: Reset unchanged.
- Out-of-scope: (1) the existing `focus` scenario's Chrome "window switch" step switches after the injection ended, so it checks the keyboard-loss path, not a window switch (Chrome survives it); kept as is, focus-kept adds the real window switch. (2) A desktop that loses its last keyboard (unplug) mid-word would lose the word in GTK3 apps: GTK3 client limitation, same with ibus-daemon. (3) /tmp/vrt-e2e.Ds4jY8 (05:06) and /tmp/vrt-e2e.JCL2VU (00:38) are not from this task (first FR-10 run started 05:15); left alone.

## Commands (trimmed)
```
$ cargo fmt --check -p fe-ibus                                  -> rc 0
$ run-heavy.sh cargo clippy -p fe-ibus --all-targets --locked -- -D warnings -> Finished, rc 0
$ run-heavy.sh cargo test -p fe-ibus --locked (fe-ibus-tests.txt)
  unit 25 ok; address 12 ok; latency 1 ok; protocol 19 ok; security 15 ok
$ cargo test -p fe-ibus --test protocol gnome_shells   (rejected alternative in place, reverted after)
  FAILED left: [Commit("viêt"), Preedit { text: "", cursor: 0, visible: false, mode: Some(0) }] right: [Preedit { ... }]
$ run_probe.sh <master binary> (probe-base.log)
  PROBE terminal got [1 viêt2 đường3 ] (expected [viêt1 viêt2 đường3 ])
  PROBE gtk3 got [1 viêt2 đường3 ] (expected [viêt1 viêt2 đường3 ])
$ run.sh --ime daemon --apps "term chrome" --runs 1 --words 300 --scenarios "focus focus-kept" --skip-install --allow-incomplete (final.out, rc 0; release binary cmp-equal to the master build)
RESULT AC-2:chrome-1 PASS  expected 1906 chars, got 1906; lost 0, extra 0, replaced 0; mean 15.1 ms/key
RESULT AC-2:term-1 PASS  expected 1906 chars, got 1906; lost 0, extra 0, replaced 0; mean 15.1 ms/key
RESULT AC-3 PASS window switch: [việt] expected [việt]; click elsewhere (focus moved to #o): [đường] expected [đường]
RESULT AC-3:chrome-kept PASS chrome window switch: [việt] expected [việt]
RESULT AC-3:term PASS terminal (switch, click on another window, Ctrl+Space): [việt đường việtaa ] expected [việt đường việtaa ]; chrome field meanwhile [] expected []; source after Ctrl+Space back [vr-talex|VI] expected [vr-talex|VI]
RESULT AC-10 INCOMPLETE measured in unit tests (D24)
RESULT SEC-1 PASS SEC-1 leak scan: 60 tokens, 217 files, 107 journal lines since the run started, 0 hits
```

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| isolated GNOME session, injection | tests/e2e (T9) | reused run.sh/lib.sh/e2e.py; extended inject with EVAL |
| shell JS from inside the injection | e2e.py `shell_eval` | reused |
| probe structure | qa-artifacts/FR-7/probe/make_probe3.py | same pattern (copy of run.sh + probe case) |
| protocol test helpers | crates/fe-ibus/tests/common | reused shell_context, type_letters, set, preedit, hidden |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 scope | pass | diff: one fe-ibus test + tests/e2e only; src unchanged |
| BASE-3 test first | pass (bug repro) | probe c1 red before any change (probe-base.log); new protocol test shown able to fail (test-vs-expcommit.txt); no product change |
| BASE-7/24 no bypass of shared tree | pass | experiment reverted with Edit; release rebuilt, `cmp` equal to master build |
| BASE-19 notes | pass | this file, progress 1-10 |
| BASE-37 replay reporter's steps | pass | FR-7 probe3 steps replayed on the master binary (probe-base.log) |
| BASE-14 long commands in background | pass | builds and e2e via run-heavy.sh; final run as background task |
| BASE-15 stop only own | pass | harness tagged cleanup only |
| COST-1..20 | pass | related tests only (fe-ibus), 1 run x 300 words per app; throwaway scripts in qa-artifacts/FR-10/; edits with Edit; sandbox homes and binaries removed |
| COST-9 nothing running | pass | no FR-10 process; the two /tmp/vrt-e2e.* predate this task |
| COST-13 throwaway scripts | pass | qa-artifacts/FR-10/{make_probe.py,run_probe.sh,gtk3probe.py} |
| SEC-1 no typed text in logs | pass | SEC-1 PASS 0 hits; no logging added |
| SEC-13 transitions | pass | the content-type clear in the focus-out sequence sends no commit (new test) |
| SEC-29 / D2 isolation | pass | only dbus-run-session sandboxes via lib.sh guard; live desktop untouched |
| AC-3 | pass | AC-3, AC-3:chrome-kept, AC-3:term PASS |
| B3 word never dropped by the engine | pass | engine ends the word on Reset; Mutter commits it (gtk3-wl.log 4179-4192, 4687-4700) |
