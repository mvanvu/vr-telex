# FR-11 Bug (live, user): address bar — type, Tab to accept the suggestion, Enter -> letters lost
Worktree /home/rainy/DEV/vr-talex-wt-FR11 (branch fr11-tab-enter from master 37faefa). Mode: bug. Side: be.

## Progress
- 1. notes created; read 04_dev_FR-8.md, 04_dev_FR-10.md, tests/e2e/README.md, crates/fe-ibus/src/session.rs (emit, ADDRESS_COMMIT_GAP), run.sh `suggest`.
- 2. harness: suggest cases accept a "+" key list (`git:Tab+Return`, `quick+` = no wait for the suggestion, `SLEEP:x`), history reseeded after each such case; release built in the worktree, copied to qa-artifacts/FR-11/vr-talex-before (= master 37faefa).
- 3. before-1 (run-20261125-062944-3239159, WAYLAND_DEBUG, unfixed daemon): EN git/you/loc/tinh:Tab+Return -> about:blank (NOT the suggestion), and afterwards EN git:Return -> search:git: in plain Chrome (EN, no engine involvement) Tab moves the focus to the row's "remove suggestion" X button (FR-8 screenshot run-052836 suggest-EN-git-Tab-2tab.png shows the X focused) and Enter presses it = the page is removed from the suggestions, the bar falls back to "git". History polluted for the later cases -> run repeated with a reseed per case (before-2).
- 4. before-2 (run-20261125-063400-3253956, WAYLAND_DEBUG, unfixed daemon, history reseeded per case): EN and VI IDENTICAL for git/you/loc/tinh:Tab+Return, git:Tab+SLEEP:1.5+Return, git:quick+Tab+Return -> about:blank in both; control git:Return -> http://github.test/ in both. chrome.log: EN 23:34:44.304 Tab, 44.386 Enter, 44.787 -> set_surrounding_text("git", 3, 3); VI 23:36:37.086 commit_string("git"), 37.110 Tab, 37.157 Enter, 37.548 -> set_surrounding_text("git", 3, 3). Same end state: bar back to the typed letters, page not loaded, suggestion removed (Chrome's own Tab -> X button -> Enter). VI-only: dduw:Tab+SLEEP:1.5+Return -> about:blank (same pattern), dduw:Tab+Return (80 ms) -> http://xn--ng-pma05d708i.test/ (Enter beat Chrome's move to the X button; no EN oracle for a Vietnamese word).
- 5. before-3 (run-20261125-063950-3276035): hub/tube/test/host Tab cases — one-row lists, EN = VI modulo Telex (test -> tét is Telex, not Tab); nothing new.
- 6. conclusion: no VI-specific loss reproduced; the reported loss is Chrome's behaviour, identical with the engine passing every key through (EN). No product change. Tests added as characterization: protocol `in_an_address_field_tab_ends_the_word_and_the_enter_after_it_is_the_clients_alone` (green on master), e2e suggest default cases + Tab+Return / quick / Tab+Tab lists (VI must end where EN ends).
- 7. final e2e (no WAYLAND_DEBUG, unchanged master binary, default cases) run-20261125-064805-3316097: `RESULT FR-8 PASS address bar purpose/hints 5/0; 18 cases, VI = EN / expected`; `RESULT SEC-1 PASS ... 0 hits`; cleanup: stopped 23 tagged processes. Guards: fmt rc 0; clippy --workspace --all-targets -D warnings clean; cargo test -p fe-ibus 25/12/1/protocol 22/15 passed. README: `suggest` paragraph.

# Result
Root cause: NOT in vr-talex. Reproduced in the sandbox with the user's steps (type, Tab, Enter): the completed address falls back to the typed letters and nothing loads — in EN mode (engine passes every key through) exactly as in VI mode. Chrome 157's own key handling: Tab moves the selection to the first row's "remove suggestion" (X) button (screenshot run-063400 out/suggest-EN-git-Tab+SLEEP:1.5+Return-2tab.png: X focused, bar "github.test"), Enter presses it: the page is removed from the suggestions and the bar shows "git" again (trace lines in step 4). The user sees it only now because before FR-8 Tab accepted nothing in VI mode.
Engine sequence (protocol test): Tab in a URL field -> hide, 5 ms, CommitText(word), key not handled; Enter after it -> no signal, not handled. D35 holds (no DeleteSurroundingText). No product change; installed binary = master, so nothing to deploy.

- Files changed: crates/fe-ibus/tests/protocol.rs (+1 test), crates/fe-ibus/tests/common/mod.rs (KEY_TAB), tests/e2e/run.sh (suggest: key-list cases, seed_history, 6 new default cases, EN-oracle check for key lists), tests/e2e/README.md. crates/*/src unchanged.
- Tests added: protocol `in_an_address_field_tab_ends_the_word_and_the_enter_after_it_is_the_clients_alone`; e2e suggest cases git/you/loc/tinh:Tab+Return, git:quick+Tab+Return, git:Tab+Tab+Return.
- Deviations: brief expected "Tab then Enter goes to the suggested address as in EN mode"; EN mode does not go there (Chrome), so the tests assert VI = EN. No red/green pair: nothing to fix; the new tests are characterization (green on master). AC-2/AC-3/AC-4 e2e not rerun: product binary unchanged (FR-8 merged run 053640 stands).
- Not reproduced / open: (a) the live profile may show other rows (search suggestions, bookmarks) — the engine is out of the picture after the Tab commit either way; (b) dduw:Tab+Return at 80 ms in VI went to the suggestion while 1.5 s later it removed it — Chrome timing after the commit, in the user's favour; (c) user check on the live desktop: Ctrl+Shift to EN, type, Tab, Enter — expected the same loss. If EN works there and VI does not, a live trace is needed (needs the user's consent, D2).
- Out of scope noticed: /tmp/vrt-e2e.Ds4jY8 (05:06) and /tmp/vrt-e2e.JCL2VU (00:38) predate this task (also listed in FR-10 notes); left alone.

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| address-bar scenario, EN oracle, cdp url | tests/e2e/run.sh `suggest` (FR-8) | reused, extended with key lists and reseed |
| protocol helpers | crates/fe-ibus/tests/common | reused shell_context, type_letters, key, hidden, preedit; added KEY_TAB |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 scope | pass | git diff --stat: 2 test files, run.sh, README; no src |
| BASE-3 test first | pass (repro first) | before-1..3 runs before any conclusion; no product change to drive |
| BASE-7/24 | pass | no shared-tree bypass; edits by Edit / perl one-liner in the worktree only |
| BASE-19 notes | pass | this file, steps 1-7 |
| BASE-37 replay reporter's steps | pass | type, Tab, Enter on the real Chrome 157 in the sandbox, EN and VI (run-063400, run-064805) |
| BASE-48 quoted read-back | pass | `cdp url` lines, RESULT lines and chrome.log lines quoted above |
| COST-1..20 | pass | e2e via run-heavy.sh as background tasks (b7ljuf5q7, b11rfiity, b2p9xisq3, b3d6n6cb3, all exited); related tests only (fe-ibus); scratch in qa-artifacts/FR-11; nothing left running |
| SEC-1 | pass | no logging added; RESULT SEC-1 PASS 0 hits; WAYLAND_DEBUG traces only in sandbox chrome.log (test words) |
| SEC-12 | n-a | password path untouched, no product change |
| D2 / SEC-29 | pass | all runs in the tests/e2e sandbox (guard); live desktop untouched |
| D35 | pass | protocol test gnome_shell_never_gets_a_delete_surrounding_text passes; no src change |
