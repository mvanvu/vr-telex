# FR-8 Bug: Chrome omnibox inline suggestion — Enter loses typed letters, Tab does not accept
Worktree: ../vr-talex-wt-FR8 (branch fr8-omnibox). Mode: bug. Side: be.

## Progress
- read: brief, task row, D10/D15/D30, ime-core ime.rs/action.rs, fe-ibus session.rs key/preedit path, tests/e2e/README.md
- e2e: added scenario 'suggest' (run.sh), cdp navigate/url (e2e.py), local site + host mapping in start_chrome
- before #1 (master daemon, hosts github.com/youtube.com — HSTS-preloaded, so only localhost loaded): VI loc:Return -> search "loc", EN -> http://localhost:<port>/ (suggestion lost). Address bar purpose/hints = 5/0 (IBus URL).
- before #2 (master daemon, .test hosts, screenshots qa-artifacts/FR-8/e2e/run-20261125-042141-2586926/out): EN "git" shows inline "git[hub.test]"; VI "git" shows the preedit "git" with NO inline suggestion. Tab: EN leaves "github.test" in the bar, VI leaves "git". Return in VI reached github.test in this run (race: depends on whether Chrome recomputes the completion between the commit and the Enter).
- root cause: Chrome's omnibox offers no inline completion while a composition is active; Enter/Tab arrive right after the boundary commit, before Chrome has recomputed one. Fix: URL purpose + surrounding text -> Edit::Surrounding (letters committed as typed, Vietnamese rewritten with DeleteSurroundingText).
- red: ime-core pipeline 2 FAILED (an_address_field_gets_every_letter_as_typed_without_a_preedit, a_field_turning_into_an_address_field_commits_the_preedit_first); fe-ibus protocol an_address_field_gets_each_letter_committed_as_typed FAILED (left [] right [Commit, hide])
- green: same tests pass after Caps.url + Edit::of change
- after attempt 1 (URL -> surrounding mode), run-20261125-043049-2619653: FR-8 not evaluated (set_mode EN failed — made set_mode retry with Chrome focused); AC-2:omnibox-1 FAIL extra 79 (e.g. chowis -> "chơiới": DeleteSurroundingText through Mutter to Chrome dropped at 15 ms/key); chrome/term/AC-3/AC-4/AC-7 PASS. Surrounding mode is lossy in Chrome's address bar -> attempt 1 rejected.
- diag: WAYLAND_DEBUG=client run of VI git:Tab / git:Return with master daemon to see what Chrome receives (text-input-v3)
- harness finding: each `e2e.py inject` call opens and closes a Mutter RemoteDesktop session; closing it removes the keyboard from the seat (chrome.log: `wl_seat.capabilities(0)` then `text_input_v3.disable()`), which focus-outs the field and commits the word before the next injection. The suggest scenario now runs each case in ONE injection (earlier passes/fails of separate-injection runs were this artefact).
- before (master daemon, single injection, run-20261125-043856-2677620): EN git/you/loc/tinh:Return -> the suggestion (http://github.test/ ...); VI the same cases -> search:git / search:you / search:loc / search:tinh. Wayland trace (chrome.log) for VI git:Return:
    21:40:33.133048 preedit_string("git", 3, 3)   (no set_surrounding_text with "git" while composing; EN sends ("github.test", 1, 11) right after each key = inline suggestion)
    21:40:34.712441 preedit_string(nil) / 34.712458 commit_string("git") / 34.712461 preedit_string(nil)
    21:40:34.714034 wl_keyboard.key(..., 28 = Enter, 1)    <- 1.6 ms after the commit, before Chrome computed a completion
  Screenshots: EN Tab -> bar "github.test"; VI Tab -> bar "git" (out/suggest-*-git-Tab-2tab.png).
- surrounding build, single-injection run-20261125-044332-2722928: FR-8 suggest PASS (12/12), but AC-2:omnibox-1 (60 words) extra 2. Trace of the loss ("khuwowm"):
    52.794554 -> set_surrounding_text("TROÉT khư", 11, 11)   52.794616 commit_string("o")
    52.808228 -> set_surrounding_text("TROÉT khưo", 12, 12)  52.808244 delete_surrounding_text(2, 0)  52.808262 commit_string("ơ")
    52.818569 -> set_surrounding_text("TROÉT khưoơ", 14, 14)
  GNOME Shell (Mutter) turned "delete 1 char" into bytes from the surrounding text one key behind ("ư" = 2 bytes), Chrome got 2 bytes for an "o" and dropped the request. Deletes are only safe when every character involved is one byte.
- fix v2 (Edit::Address): in an address field a word is committed key by key while its text equals its keys (plain ASCII letters: github, localhost, tinh); at its first Vietnamese change the typed letters are deleted (ASCII only) and the word goes on as preedit, committed at the boundary as before. Tests: ime-core pipeline 18 passed incl. every golden word in an address field with a check that each delete removes only ASCII letters; fe-ibus protocol 14 passed.
- v2 e2e run-20261125-045222-2759693: GNOME Shell CRASHED during the omnibox target (logs/shell.log):
    libmutter:ERROR:../src/wayland/meta-wayland-text-input.c:258:meta_wayland_text_input_focus_delete_surrounding: assertion failed: (before >= start)
    GNOME Shell crashed with signal 6
  Mutter asserts that a delete fits in the surrounding text it last got from the client; Chrome's surrounding text lags a key behind, so a delete right after the first letters of a field aborts the whole shell (on the desktop: the session). => DeleteSurroundingText must never be sent through GNOME Shell. v1 and v2 (any surrounding-text rewrite) rejected.
- v1/v2 code reverted (patch kept: qa-artifacts/FR-8/v2-ime-core-address.patch); ime-core and fe-fcitx untouched now.
- timing experiment (master daemon, run-20261125-045601-2795827, word committed by a Ctrl+Shift tap, Enter 1 s later): trace
    56:32.316286 commit_string("git")
    56:32.319493 -> set_surrounding_text("github.test", 3, 11)    <- Chrome's inline completion 3 ms after the commit
  (then the Ctrl release dropped it: confounded, so the case result search:git says nothing). It shows Chrome does complete an IME-committed word, ~3 ms later, and reports it through its surrounding text.
- fix v3 (fe-ibus only, key path): in a URL-purpose context, a press that the engine leaves unhandled after committing a word is answered handled=true and held; it is forwarded (ForwardKeyEvent press, then its release if that came meanwhile) when the client's next SetSurroundingText arrives, before any other call of the connection, or after HOLD_LIMIT = 100 ms.
- red (v3 tests against the unfixed source, src patch reversed): protocol 14 passed, 2 FAILED (in_an_address_field_the_key_ending_a_word_waits_for_the_client_to_take_the_word at protocol.rs:465 assert!(press.handled()); a_held_key_goes_out_after_the_limit_or_before_anything_that_follows at :500). green: 16 passed.

## Status snapshot (for a fresh developer)
Root cause (evidence above): Chrome's omnibox offers its inline completion only for text it holds, never for a preedit; after the IME commit it works the completion out ~3 ms later (trace: commit_string("git") 32.316286 -> set_surrounding_text("github.test", 3, 11) 32.319493). The engine commits at the boundary key and returns handled=false, so GNOME Shell delivers Enter/Tab ~1.6 ms after the commit (trace 34.712458 commit -> 34.714034 Enter) — before the completion exists. Enter then searches for the typed letters, Tab finds nothing to accept.
Tried and rejected:
  v1 URL purpose -> surrounding mode (commit per key + DeleteSurroundingText): FR-8 cases pass but omnibox AC-2 extra chars (Mutter converts the delete to bytes from a surrounding text one key behind; Chrome drops mis-sized deletes).
  v2 commit plain-ASCII words as typed, preedit from the first Vietnamese change: GNOME Shell CRASHED (Mutter assertion before >= start in delete_surrounding). Never send DeleteSurroundingText via GNOME Shell.
Current fix v3 (fe-ibus only): hold the key that ended a word in a URL-purpose context (reply handled=true), forward it with ForwardKeyEvent (press, then release if it came) on the client's next SetSurroundingText, before any other call of the connection, or after 100 ms.
Current worktree diff (vs master 7dc246d): crates/fe-ibus/src/ibus.rs (PURPOSE_URL), crates/fe-ibus/src/session.rs (Held, HOLD_LIMIT, serve loop timeout_at, keeps_held, forward_held, ProcessKeyEvent hold, SetSurroundingText forwards), crates/fe-ibus/tests/common/mod.rs (Seen::Forward), crates/fe-ibus/tests/protocol.rs (3 new tests), tests/e2e/e2e.py (cdp navigate/url), tests/e2e/run.sh (local site + host mapping, scenario `suggest`, set_mode).
v3 e2e run-20261125-050009-2825870 (with WAYLAND_DEBUG): AC-2 omnibox-1 PASS 1906/1906 lost 0 extra 0; chrome-1 PASS; AC-3/AC-4/AC-7 PASS; term-1 "window did not appear" and FR-8 "could not switch to EN" (env; rerunning without WAYLAND_DEBUG, set_mode now prints indicator/focus).
Next: read rerun (term + toggle focus suggest), run suggest alone for before (master daemon) / after (worktree daemon) evidence, clippy/fmt/fe-ibus tests (running), then rule table and report.

## v3 result (fe-ibus hold-key) — does NOT fix; reverted (patch: qa-artifacts/FR-8/v3-fe-ibus-hold-key.patch)
- guards with v3: cargo fmt --check OK; clippy --workspace --all-targets -D warnings clean; cargo test -p fe-ibus 25/12/1/16/15 passed.
- e2e v3 run-20261125-050009-2825870: AC-2 omnibox-1 PASS (1906/1906, lost 0 extra 0, 15.3 ms/key), chrome-1 PASS, AC-3/4/7 PASS; run-20261125-050403-2841214: term-1 PASS, AC-3/AC-4 PASS (FR-8 not evaluated there: set_mode needed a focused text field — fixed in run.sh).
- FR-8 suggest, same scenario, after = worktree v3 daemon run-20261125-050623-2855143 / before = master daemon run-20261125-050938-2870248: IDENTICAL —
    EN git/you/loc/tinh Return+Tab -> http://github.test/ … ; VI the same 8 cases -> search:git / search:you / search:loc / search:tinh; dduwowngf:Return -> search:đường; dduw:Tab -> search:đư ("10 of 12 cases differ" in both).
  (AC-3 FAILED once in the v3 run 050623 — window switch [] expected [việt]; PASS in 050009 and 050403 with the same build; unexplained, single occurrence.)
- why v3 fails (trace run-20261125-051424-2914563, VI git:Return, time-sorted chrome.log):
    09.663951 preedit_string(nil) 09.664022 commit_string("git") 09.666782 preedit_string(nil) 09.666848 done(66)
    09.675591 -> set_surrounding_text("github.test", 3, 11)   <- Chrome completed the word
    09.691815 done(67)  (Mutter's empty done answering Chrome's own commit)
    09.691850 -> set_surrounding_text("git", 3, 3)            <- completion removed 16 ms later, before any key
    09.768252 wl_keyboard.key(28 = Enter)                     <- forwarded at the 100 ms limit (the SetSurroundingText-triggered forward did not fire: not yet explained)
  So holding the key is not enough: after an IME commit Chrome drops its fresh inline completion on the next text-input done (likely re-applying the empty preedit as a composition clear, which deletes the selected completion). In EN mode (no composition ever) the completion survives the same dones.
- Rule found: DeleteSurroundingText must never be sent through GNOME Shell 46 (Mutter g_assert in meta_wayland_text_input_focus_delete_surrounding crashes the shell when the client's surrounding text lags).

## Next step (not done — stopped at a safe point, context budget)
1. Find what makes Chrome drop the completion at done(67): try (a) not sending our HidePreedit after the commit for ClientCommitPreedit clients (Mutter already sends preedit nil with the commit) and check the trace for a second preedit_string(nil)/drop; (b) check whether Chrome drops it in EN mode after a word committed by a toggle (no Ctrl confound: commit via FocusOut/Reset).
2. If (a) keeps the completion, combine with the v3 hold (forward Enter/Tab after Chrome's completing set_surrounding_text) and rerun `tests/e2e/run.sh --apps "" --scenarios "focus suggest"` before/after plus omnibox/chrome/term AC-2.
3. Otherwise this needs a user decision (Chrome-side limitation; options: accept + document, or a Chrome flag/upstream report).
Worktree now: only tests/e2e/e2e.py + tests/e2e/run.sh changed (scenario `suggest` reproduces the bug: FAIL on master, 10 of 12 cases).

## Files changed (worktree ../vr-talex-wt-FR8, uncommitted)
- tests/e2e/run.sh: local stdlib HTTP site + Chrome host mapping (github.test, youtube.test, tinhte.test, xn--ng-pma05d708i.test, localhost) with proxy bypass for those names only; scenario `suggest` (in the default list) — seeds typed history over CDP, types each case in ONE injection at 80 ms/key, compares VI with EN (and VI-only cases with expected addresses), screenshots per case; set_mode helper (focuses the page textarea first).
- tests/e2e/e2e.py: `cdp navigate TAB URL` (typed transition), `cdp url TAB` (current URL, a search as search:<q>).
- Product code: none (v1, v2, v3 reverted; patches in qa-artifacts/FR-8/).

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| sandbox, injection, CDP | tests/e2e (README, run.sh, e2e.py) | reused; extended with navigate/url and the suggest scenario |
| in-place rewrite of committed text | ime-core Edit::Surrounding | tried (v1/v2), rejected by evidence |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 scope | pass | product code unchanged in the final tree; harness additions only for the scenario |
| BASE-3 contracts | pass | no IBus / ime-core contract changed in the final tree |
| BASE-7/24 tests | fail | no fix landed, so no red/green pair for a fix; the red e2e exists (suggest FAIL on master, run-20261125-050938-2870248) |
| BASE-19 notes | pass | this file, progress line per step |
| BASE-37 replay before/after | pass (before) / n-a (after: no fix) | before runs 043856, 050938 |
| BASE-48 quoted read-back | pass | every state above quotes `cdp url` output or chrome.log lines |
| COST-1..20 | pass | heavy commands through run-heavy.sh in the background; scratch in qa-artifacts/FR-8; edits with Edit; one own task stopped by id (br3qwjt0m); 0 FR-8 sandbox processes left (tagged processes still running belong to qa-artifacts/FR-10) |
| SEC-1 | pass | no logging added; WAYLAND_DEBUG traces only in the throwaway sandbox chrome.log (test words) |
| SEC-12 | pass | password path untouched; AC-7 PASS in run 050009 |
| D2 / SEC-29 | pass | every run inside the tests/e2e sandbox with its guard and a throwaway Chrome profile |

## Out of scope noticed
- SEC-1 leak scan with --tmp hit /tmp/flutter_tools.*/…dill files of another project (run 042141): an unrelated 8-byte match outside the sandbox; the scan's --tmp scope may need narrowing.
- Each `e2e.py inject` call removes its keyboard from the seat at exit (focus-out commit in the app): harness steps that split one user action over several injections do not replay the user's flow.

## Continuation (second developer)
- read: notes, session.rs emit, saved inputMethod.js; fetched Chromium 157.0.8103.50 (installed version) text-input sources and mutter 46 meta-wayland-text-input.c into the scratchpad (read only).
- NOTE for leader: worktree is on base 7dc246d without FR-7; master merge is needed at merge time only (FR-7 does not touch emit).
- root cause found in Chromium source: ZwpTextInputV3Impl::OnDone applies commit_string, then calls OnPreeditString when the preedit of this done differs from the last applied one; InputMethodAuraLinux::UpdateCompositionIfTextSelected then calls SetCompositionText("") whenever there is no composition and a non-empty selection, which deletes the selection = the inline completion the omnibox computed synchronously inside the commit. A word shown as preedit and committed in the SAME done always has "preedit changed" (applied "git" -> ""), so the completion is always deleted. Hypothesis: clear the preedit in an EARLIER done than the commit (hide, then commit a few ms later) so the commit done carries an unchanged empty preedit.
- experiment exp4 (temporary code): URL purpose + ClientCommitPreedit + key cause -> send hide first, wait VRT_EXP_DELAY_MS (default 5), then commit.
- exp4 result run-20261125-052214-2984970 (WAYLAND_DEBUG): RESULT FR-8 PASS 12 cases, VI = EN / expected. Trace VI git:Return: 47.536281 preedit_string(nil) 47.536338 done(233) | 47.542274 preedit_string(nil) 47.542286 commit_string("git") 47.542290 done(234) | 47.550017 wl_keyboard.key(28 Enter) -> http://github.test/. No key hold needed: Chrome computes the completion synchronously while applying the commit.
- coordinator note (FR-10 finding, injection end removes the keyboard): checked — every suggest case is ONE `e2e.py inject` (word, pause, Tab/Shift+Tab, Return in one keys array, run.sh suggest); the trace above lies inside one injection. No conclusion here crosses an injection boundary.
- red (experiment off): protocol 13 passed, 2 FAILED — gnome_shell_never_gets_a_delete_surrounding_text (left [Commit("a"), Delete(-1, 1), Commit("á")] right [Commit("á")]); in_an_address_field_the_preedit_is_cleared_before_the_word_is_committed (left Commit("git") right hidden preedit).
- code: final fix in crates/fe-ibus/src/session.rs (ADDRESS_COMMIT_GAP, Context::caps(shell), is_shell, apply_caps on ClientCommitPreedit and on the panel claim, emit: hide-first + gap for URL purpose, DeleteSurrounding dropped for shell contexts), ibus.rs PURPOSE_URL.
- green: cargo test -p fe-ibus -> 25 / 12 / 1 / protocol 15 passed / 15 passed; cargo clippy --workspace --all-targets -D warnings clean; cargo fmt --check OK.
- e2e after (final build, no WAYLAND_DEBUG) run-20261125-052836-3032830:
    RESULT AC-2:omnibox-1 PASS expected 1906 chars, got 1906; lost 0, extra 0, replaced 0; mean 15.0 ms/key
    RESULT AC-2:chrome-1 PASS 1906/1906 lost 0 extra 0; RESULT AC-2:term-1 PASS 1906/1906 lost 0 extra 0
    RESULT AC-7 PASS; RESULT AC-4 PASS (VI->EN 5 ms, EN->VI 3 ms); RESULT AC-3 PASS ([việt], [đường])
    RESULT FR-8 PASS address bar purpose/hints 5/0; 12 cases, VI = EN / expected (VI git/you/loc/tinh Return+Tab -> the suggested address; dduwowngf:Return, dduw:Tab -> http://xn--ng-pma05d708i.test/; tieengs/vieetj -> search:tiếng / search:việt)
    RESULT SEC-1 PASS 0 hits; shell.log: 0 assertion/crash lines; cleanup: stopped 23 tagged processes
  before (master daemon, same scenario): run-20261125-050938-2870248, 10 of 12 cases differ.
- patch of the final product change: qa-artifacts/FR-8/v4-fe-ibus-address-gap.patch

## Final state (continuation)
Root cause (Chromium 157 source, ui/ozone/platform/wayland/host/zwp_text_input_v3.cc OnDone + ui/base/ime/linux/input_method_auralinux.cc UpdateCompositionIfTextSelected): the omnibox computes the inline completion synchronously while the commit_string is applied; in the same `done` the preedit changes from the word to empty, and Chrome answers an empty preedit with "no composition + non-empty selection" by SetCompositionText("") which deletes the selection = the completion. Enter/Tab then see only the typed letters.
Fix (fe-ibus only): for a ClientCommitPreedit context with URL purpose, send the hide first, wait ADDRESS_COMMIT_GAP (5 ms) so Mutter sends that `done` (idle callback), then CommitText; the commit's `done` carries an unchanged empty preedit. No key hold, no DeleteSurroundingText, ime-core untouched. If the gap is ever too short (shell main loop busy > 5 ms) the two share one `done` and the behaviour falls back to the old one for that word (completion dropped), nothing worse.
Shell safety: Context::caps(shell) masks surrounding_text for GNOME Shell contexts (ClientCommitPreedit set, or the connection owns the panel) so the engine never chooses Edit::Surrounding there (it holds the word instead); caps are re-applied when ClientCommitPreedit is set and when the panel is claimed; emit drops a DeleteSurrounding for such a context as a last guard.
Files changed (worktree, uncommitted): crates/fe-ibus/src/ibus.rs (PURPOSE_URL), crates/fe-ibus/src/session.rs (ADDRESS_COMMIT_GAP; Context::caps; Session is_shell; RequestName grant and ClientCommitPreedit re-apply caps; apply_caps; emit: `shell`/`address` lets, the `if address` plan arm, peekable loop + gap after HidePreedit, DeleteSurrounding guard), crates/fe-ibus/tests/common/mod.rs (KEY_RETURN), crates/fe-ibus/tests/protocol.rs (2 tests), tests/e2e/run.sh + e2e.py (previous developer: scenario suggest).
Overlap with FR-10 (emit FocusOut/Reset): my emit lines do not touch `skip_commit` or the cause match; the hide-first arm is placed after the `if skip_commit` arm.
Known trade-offs: +5 ms on the key that ends a word in an address field only; the word is cleared for those 5 ms (not visible in screenshots); a non-shell IBus client never sets ClientCommitPreedit, so GTK/Qt URL fields are unchanged. Not tested on other browsers (Firefox uses GTK IM -> through the shell too; same path, purpose URL: behaviour = hide, 5 ms, commit).
Needs at merge: master (FR-7) and FR-10 merged in; expect a small conflict in tests/e2e/run.sh scenario list.

## Rule compliance (continuation — replaces the table above)
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 scope | pass | fe-ibus emit/caps only + 2 tests; ime-core, fe-fcitx untouched (git diff --stat) |
| BASE-3 contracts | pass | IBus signals unchanged in kind; only order/timing for URL-purpose shell contexts; ime-core Caps contract unchanged |
| BASE-7/24 tests | pass | red: protocol 13 passed 2 FAILED (messages above); green: protocol 15 passed; e2e FR-8 FAIL before (run 050938) -> PASS after (run 052836) |
| BASE-19 notes | pass | this Continuation section |
| BASE-37 replay before/after | pass | same `suggest` scenario on the real Chrome in the sandbox: before run-20261125-050938-2870248, after run-20261125-052836-3032830 |
| BASE-48 quoted read-back | pass | RESULT lines and chrome.log trace lines quoted above |
| COST-1..20 | pass | e2e through run-heavy.sh as background tasks (b4wtu1c4r, bukyykytx, both exited 0); related tests only (cargo test -p fe-ibus); edits with Edit; scratch in qa-artifacts/FR-8 and the session scratchpad; nothing left running (cleanup: stopped 23 tagged processes) |
| SEC-1 | pass | no logging added; RESULT SEC-1 PASS 0 hits |
| SEC-12 | pass | password path untouched; RESULT AC-7 PASS; protocol password tests pass |
| D2 / SEC-29 | pass | all runs inside tests/e2e sandbox (guard), throwaway Chrome profile; live desktop untouched |

## Merge with master (FR-7, FR-9, FR-10)
- conflicts resolved by edit only (not staged): crates/fe-ibus/tests/protocol.rs (both sides tests kept, 21 tests), tests/e2e/run.sh (header + default SCENARIOS "password toggle focus focus-kept suggest install"; suggest and focus-kept blocks both kept). session.rs auto-merge checked: ADDRESS_COMMIT_GAP :45, caps(shell) :170, is_shell :318, emit address/shell lines :831-898 beside FR-7 set_enabled/SetGlobalEngine.
- cargo test -p fe-ibus --locked: 25 / 12 / 1 / protocol 21 / 15 passed; fmt --check OK; clippy --workspace --all-targets --locked -D warnings clean.
- e2e merged build run-20261125-053640-3056509: AC-2 term/chrome/omnibox PASS 1906/1906 lost 0 extra 0; AC-3 PASS; AC-3:chrome-kept PASS; AC-3:term PASS; FR-8 PASS 12 cases; AC-4:indicator PASS; SEC-1 PASS; AC-10 INCOMPLETE (D24) -> exit 1 only for that; shell.log 0 mutter text-input assertions (GLib-CRITICAL lines pre-date FR-8); cleanup stopped 23 tagged processes.
