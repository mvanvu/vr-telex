# Review E3 — code + security

Verdict: **FAIL** (CHANGES_REQUESTED / ISSUES_FOUND) — 1 blocker.

Tools used: Read, Bash (git diff, grep, `cargo test -p ime-core --locked`: 8+1+13+6+4+8+11+13 ok).

## Findings

[blocker / security high] crates/ime-core/src/ime.rs:179-190 (flush, `Edit::Surrounding` arm) reached from `reset` (ime.rs:349-358), `set_enabled(false)` pending (ime.rs:478-483) and, less likely, `focus_out` — CWE-367 rewrite at a cursor the IME no longer knows
Scenario: a surrounding-text client (no preedit cap) types `the best` → field shows `the bét`. The user clicks elsewhere, e.g. at the end of `hello world`. The toolkit sends `Reset` because the cursor moved (GTK calls it from the click / mark-set handler; the IBus/fcitx call is async, so the signals land after the move in any case). `reset` → `flush_and_forget` → `DeleteSurrounding{-3,3}` + `Commit("best")`; fe-ibus (session.rs:718-721, 898-906) and fe-fcitx (server.rs:337-341, 407-409) send both. Result: `hello wobest`, and `bét` stays where it was. User text silently deleted in another place. Before E3 a surrounding flush sent nothing (the client already holds the word), so this is new. Same path: `set_enabled(false)` mid-word parks Delete+Commit in `pending`, which is emitted by whatever call comes next — typically the `Reset`/`FocusOut` after the user clicked. The new test `every_word_end_event_commits_the_finished_text` asserts this behaviour for reset/disable/focus-out in SURROUNDING. D12 only covers preedit.
Fix: rewrite in surrounding mode only on a word end that happens at a known cursor — the key path (boundary key, COMMAND chord, Ctrl+Shift tap, overflow) and `set_caps` (emitted at once by apply_caps). For `reset`, `focus_out`, `set_enabled(false)`, `destroy_context` and `recover` of other contexts, keep the shown text in Surrounding (emit nothing, as before E3), e.g. `flush(out, rewrite: bool)`; the language stored can stay `finished.lang` or Unknown (all those paths forget it anyway, except recover). Change the test to assert `[]` for those events in SURROUNDING and record it next to D12 as the surrounding counterpart.

[minor] crates/ime-core/src/ime.rs:416-420 — overflow flush now commits `finish()` output, which for a 32-key run that the engine transformed is the raw keys (plan said "unchanged behaviour"; D11 only mentions `last = En`). Consistent with AC-1, so only a plan/decision gap: note it in D11.

Hunts checked, no defect: BackSpace that empties the word (compose clears, `last` unchanged, next flush is a no-op); Ctrl+Shift mid-word (flushed under the old mode then Unknown); destroy (flush with `last`, context gone); recover (broken ctx cleared + Unknown; release builds abort, Cargo.toml:36); two interleaved contexts (per-context `last`, tested); Surrounding delete count = `shown.chars().count()` of `composer.text()`, which is exactly what `compose`'s diff left in the client, incl. multi-byte and uppercase (`Việt` → 4); shell contexts never get Surrounding caps (fe-ibus session.rs:173), and emit drops DeleteSurrounding for the shell anyway; set_caps flushes under the old caps (caps assigned after flush).

## Files read
- crates/ime-core/src/ime.rs — read (whole diff + compose, set_caps, process_key, recover)
- crates/ime-core/tests/word_end.rs — read
- crates/ime-core/tests/pipeline.rs — read (diff)
- crates/ime-core/tests/security.rs — read (diff)
- crates/fe-fcitx/tests/bus.rs — read (diff)
- crates/fe-ibus/tests/protocol.rs — read (diff)
- .ai-dev-team/workspace/02_tasks.md, decisions.md — read (D11, D12)
- followed: telex-core lib.rs `finish`/`Finished`, ime-core action.rs (Drop/Debug), shared.rs (recover), fe-ibus session.rs (caps, Reset/FocusOut, emit), fe-fcitx server.rs (Reset, emit)

## Rule check E3
| Rule | Status | Evidence |
|---|---|---|
| AC-4 | pass | `Context.last: Lang` (Copy enum, no text); set in flush from `finished.lang`; Unknown on focus_in/out, reset, create, toggle, disable (ime.rs:198-202, 330-331); tests `the_language_starts_over_*`, `contexts_keep_their_own_language` |
| AC-5 | fail | Preedit/Hold correct (fe-ibus emit reorders HidePreedit+Commit, address order untouched, D12 for skip_commit); Surrounding rewrite on reset/disable-pending deletes at a moved cursor — blocker above |
| AC-6 | pass | `finish` only in `flush`; `compose` unchanged; latency.rs green |
| AC-8 | pass | ime-core suites green (run here); dev notes show fe-ibus/fe-fcitx green; the two frontend edits only swap incomplete `đâ`/`đườ` for complete `đâu`/`đức` (same key count for the zip), assertions unchanged in kind |
| SEC-2 | pass | no new Debug/log; `Finished` Debug redacted; `debug_prints_no_word` |
| SEC-4 | pass | `shown`/`finished.text` borrow the composer; the only copy goes into `Action::Commit`, wiped by `Drop for Action` (action.rs:28-35) |
| SEC-13 | pass | set_caps flushes before `ctx.caps = caps`, so delete/commit use the old edit mode |
| B3 | pass | every flush path emits the word (focus_out, reset, destroy, disable, recover-others, overflow); the blocker is about where it lands, not dropping it |

## Re-check fix round 1

Verdict: **PASS** (APPROVED / SECURE). Blocker closed. `cargo test -p ime-core --locked`: 8+1+13+6+4+8+11+15 ok.

- Closed: `end_word(out, at_cursor)` (ime.rs:174-207). The Surrounding arm rewrites only when `at_cursor && finished.text != shown`. Callers with `at_cursor = false`: focus_out (354), reset (368), set_enabled(false) (494), destroy_context (311), recover for the other contexts (530). Callers with `true`: set_caps (324, sent right away by fe-ibus apply_caps → emit), Ctrl+Shift tap (398, then `last = Unknown`), EN/password (418), COMMAND chord (422), overflow (429), boundary key (460). No path without a key sends DeleteSurrounding except set_caps, which D13 allows.
- Tests are sound. `every_word_end_event_commits_the_finished_text` expects `[]` for SURROUNDING on focus_out/reset/destroy/disable, and Delete+Commit for set_caps/toggle/Ctrl+a. Preedit and Hold still get the commit for every event. `surrounding_mode_never_rewrites_after_a_click_or_focus_change` covers reset, disable (pending), focus_out and destroy after real typing. `recover` is pub(crate) and not tested, but read in the code (flush_away). The flake replay test matches what the IME actually does (`s` alone gives `s`; Unknown after reset gives `bét`).
- [minor, no action needed] After an away flush in Surrounding, `last` takes `finished.lang` (e.g. En for `best`) although the client keeps the shown `bét`. Only recover (other contexts) keeps it, and recover is never reached in release (panic = abort). destroy drops the context, and the rest forget it.
- [uncertain, residual] set_caps rewrites in Surrounding. It is safe as long as the edit-mode change does not come after a cursor move that had no Reset first. D13 accepts this. Clients with surrounding but no preedit are rare.
- Terminal flake: the developer's explanation (keys typed before the terminal's IME focus settled) is **plausible but not proven**. The replay shows that a reset mid-word or between words produces exactly the observed output, and the `rep` run is clean 25/25. There is no call trace showing a Reset/FocusIn at the time of the failure, though, so the actual cause is not confirmed. To confirm it: add a warm-up line or wait for the engine's FocusIn in tests/e2e, then rerun the term cases. If the flake comes back, trace Reset/FocusIn in the daemon.

| Rule | Status | Evidence |
|---|---|---|
| AC-4 | pass | resets unchanged; the toggle sets Unknown after `flush` (398-399) |
| AC-5 | pass | D13 rows in `every_word_end_event_*`; `surrounding_mode_never_rewrites_*` |
| AC-6 | pass | `compose` untouched |
| AC-8 | pass | ime-core green (run here); fe suites per dev notes |
| SEC-2 | pass | no new output |
| SEC-4 | pass | `end_word` only borrows; Commit wiped on drop |
| SEC-13 | pass | set_caps uses `flush` before `ctx.caps = caps`, so the word is rewritten under the old caps |
| B3 | pass | Preedit/Hold commit on every away event; in Surrounding the client already holds the shown word, so nothing is dropped |
| D13 | pass | call-site audit above |
