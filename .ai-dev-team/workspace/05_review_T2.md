# Review T2 — verdict: APPROVED

Tools available: Read, Bash (non-mutating), Write, Skill, SendMessage, SubagentHandback. Tests/clippy output taken from qa-artifacts/T2 (final-test.log: golden 31552 passed, rules 16 passed; clippy exit 0); not rerun.

## Findings (no blocker/major)
[minor] crates/telex-core/tests/golden.rs:28-34 — golden test passes vacuously when the TSV is missing
Scenario: file renamed/deleted/mis-pathed → `golden_list` prints SKIPPED and returns, exit 0, so AC-1 reports green with zero cases checked.
Fix: T3's file now exists; replace the skip with `panic!`/`expect` (the `cases >= 2000` guard then also protects the empty-file case).

[minor] crates/telex-core/src/lib.rs:173-183 — `pop` after an undo shows a different word than a BackSpace should
Scenario: `ass` shows `as`; BackSpace replays raw `as` → `á`. Likewise `aaa` shows `aa`, BackSpace → `â`. Matches the plan contract ("remove the last raw key") but the visible result is not "last shown char removed". No test covers pop after undo or after a w-mark (`raw_and_pop` only covers `vieetj`, `acf`).
Fix: leader/user decision. Either accept (document it for T4) or, in `Mode::Undone`, pop one char from the rendered text and keep Undone. Add a test either way.

[minor] rust-toolchain.toml:2 / Cargo.toml:13 — toolchain is not pinned to 1.100.0
`channel = "stable"` floats; `rust-version = "1.100"` is only a floor, so a later `rustup update` silently changes the compiler. (d) is acceptable (TOOL-2 stable only; naming 1.100.0 would force a second download, BASE-17); the comment in the file explains it. Revisit when a release pin is wanted.

## Developer interpretations
- (a) `uow`→`ươ` always: acceptable, literal spec §4 (`uow`/`uwow` → ươ) and golden agrees. Cost: `thuở`, `huơ`, `khuơ` cannot be typed (`thuowr` → `thưở`). These are common words (thuở nhỏ), so the user should confirm; a fix needs re-evaluating `uo`+`w` against the final (open `ươ` is not a syllable) — not required by the spec.
- (b) aa/ee/oo only when adjacent: acceptable, matches spec `aa`→â and protects `reset`/`photo`/`queue` (D15). Non-adjacent forms (`toio`) are not in the spec.
- (c) letters after undo → raw keys: acceptable, spec §4 only defines undo output; `xoong` cannot be typed, rare loanword. Mention in README later.
- (d) see the toolchain finding: acceptable.

## Checks done by me
- Traced: `sa` → sa; `asf` → à (re-tone); `ass` → as; `z` on toneless → raw (z not an initial/final); `dd`→đ only as the first letter, `DD`→Đ, `ddd`→dd; `W`→Ư, `ww`→w; digit → appended, passthrough; `bacr` → raw (stop final + hỏi); `class`, `https` raw. All consistent with spec §4/D15.
- Case kept per letter (Letter.upper, to_uppercase of precomposed chars); output comes from a precomposed table → NFC (test `output_is_precomposed`).
- golden.rs reads every line, skips only blank/`#`, collects all mismatches, asserts ≥2000 cases. Verified TSV: 31562 lines, no line without TAB among the non-comment ones.
- No word list/dictionary in lib.rs (D14); structural tables only (D15).
- No build.rs; Cargo.lock has tokio 1.54.1 from crates.io; deny.toml crates.io only, unknown-git deny. cargo-deny was not installed, so deny.toml is unverified by the tool (noted by developer; run it when installed). No manifest dependency added beyond tokio (`rt` only).
- No Display impl; Debug redacted; main.rs prints only constant text and frontend error Display (error contract forbids typed text). No unwrap/expect on typed data (only `unwrap_or*`).
- `wipe_string` best effort only (realloc history not covered) — SEC-4 later, not T2.

## Files read
Cargo.toml read, Cargo.lock skipped — generated (checked tokio entry only), rust-toolchain.toml read, deny.toml read, .gitignore read, README.md read, crates/*/Cargo.toml (6) read, crates/{ime-core,fe-ibus}/src/lib.rs read (fe-fcitx, fe-xim identical stubs by notes, skimmed via grep for forbid), crates/vr-talex/src/main.rs read, crates/telex-core/src/lib.rs read, crates/telex-core/tests/golden.rs read, crates/telex-core/tests/rules.rs lines 195-281 read (rest skimmed by test names), tests/golden/telex_golden.tsv skipped — T3 generated (structure checked), tools/golden-gen skipped — T3.

## Rule check T2
| Rule | Status | Evidence |
|---|---|---|
| TOOL-1 | pass | edition 2024, tokio 1.54.1 in Cargo.lock; rustc 1.100.0 per notes; zbus/x11rb/xim not yet needed |
| TOOL-2 | pass | channel stable, no prerelease |
| TOOL-3 | pass | Cargo.lock present, resolver 3, workspace lints |
| TOOL-4 | pass | tokio latest per notes (pubtime > 14 days) |
| AC-1 | pass | golden.rs reads every line, all mismatches reported; 31552 cases pass (final-test.log); skip-on-missing is a minor finding |
| SEC-2 | pass | Debug redacted, no Display, test debug_is_redacted |
| SEC-25 | pass | Cargo.lock, deny.toml crates.io only; deny not run (tool missing) |
| SEC-26 | pass | only tokio, no build.rs |
| SEC-27 | pass | forbid(unsafe_code) in all crate roots + workspace lint |
| BASE-1 | pass | only brief files + deny.toml |
| BASE-3 | pass | red.log shows tests failing before the engine |
| BASE-6 | pass | English, why-comments |
| BASE-8 | pass | single dependency, version from plan |
| BASE-9 | n-o | no external input boundary; push accepts any char safely |
| BASE-16 | pass | nothing pre-existing to reuse |
| BASE-22 | pass | crate names as plan |
| BASE-25 | pass | fmt/clippy exit 0 per notes |
| BASE-32 | pass | compared with D5, D13, D14, D15, golden agrees; no dictionary |

## Re-check quick pass 1 — verdict: APPROVE
Scope: Composer::pop rewrite (pop_letter, replay, resync_raw, outcome, render_to, tone_key_last), 5 new BackSpace tests + changed `raw_and_pop`, golden.rs. Output from qa-artifacts/T2/qp1-test.log (golden 31552 ok, rules 21 ok); not rerun.

Earlier findings
- Golden skip (minor): fixed. golden.rs:28-31 panics on a missing file; the `cases >= 2000` assert covers an empty one.
- pop after undo (minor): fixed per leader decision. Traced `ass<` (Undone: text "as" → "a", re-render of kept letters equals text → Viet, raw resynced to "a"), `aaa<`, `ww<` (text empty → clear), `tuw<` (letter popped), tone key BS (replay of raw minus last key), `vieet1<j` (non-letter Undone → Viet resume). All match the leader's rule.
- Toolchain (minor): unchanged, accepted.

No new defects found
- Raw/state desync after pop then push: none found. `resync_raw` rewrites raw as Telex keys of letters (+ tone key last), `tone_key_last` is cleared in push/resync/clear; the replay of resynced keys reproduces the same letters (checked `nguwow`, `tw`, `dd`, `ee`+`e` adjacency, Literal undo after pop). Raw-mode pop only swaps in the recomposed state when its text equals the shown text, and the old state is wiped via `again.clear()`.
- No-vowel pop drops the tone (pop_letter:232); the "unreachable" fallback keeps the shown text.
- SEC-2: Debug still redacted (len only); no new Debug/Display derives, no prints; scratch strings (`before`, `shown`, `text` in render) are wiped.

Nits (not blocking)
- [minor] lib.rs:194-203 — Undone → Viet resume can land on unparsable letters. Scenario: `tw` `n` `w` (w undoes a mid-word w-ư: letters become t,w,n, text "twnw"), BackSpace → text "twn" with mode Viet and Outcome::Composing although no syllable fits. The next letter then falls to raw restore, so no wrong text is produced; only the Outcome is optimistic. Fix: in that branch, if `parse(letters)` is None call `restore_raw`.
- [minor] lib.rs:210 — `keys` Vec<char> in the Raw branch is not wiped (best effort SEC-4, the Viet branch does `fill('\0')`).
- Plan contract comment for `pop` ("remove the last raw key") is now outdated; the developer notes list the change under BASE-2. The leader should update 02_plan.md before T4 relies on it.

Rule check delta: AC-1 pass (now fails when the list is missing); SEC-2 pass; SEC-27 pass (no unsafe added); BASE-2 pass with the documented pop semantics; BASE-3 pass (qp1-red.log shows the 5 tests red first). Other rows unchanged.
