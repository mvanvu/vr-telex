# T2 Scaffold Cargo workspace + telex-core engine

## Progress
- 19:30 read brief, plan (Components, Contracts, Toolchain), spec §4/§6, D5/D13, SEC-2/25/26/27, rule packs BASE/COST/TOOL.
- Toolchain: rustc/cargo 1.100.0 installed as `stable` (rustup list shows only stable-x86_64). tokio 1.54.1 = latest (`cargo search`), pubtime 2026-10-21 in the crates.io sparse index (> 14 days).
- Scaffold written: workspace Cargo.toml, rust-toolchain.toml, .gitignore, README.md, deny.toml, crates/{ime-core,fe-ibus,fe-fcitx,fe-xim,vr-talex} stubs + main wiring.
- Tests written first (crates/telex-core/tests/rules.rs, tests/golden.rs) against a placeholder Composer (text()==raw). Red run: 13/14 rules tests FAILED, golden 12054/13375 failed (qa-artifacts/T2/red.log).
- Engine written (crates/telex-core/src/lib.rs). run1: rules 13/14, golden 24 mismatches (qa-artifacts/T2/run1.log). Fixed: my test typo (`tiesng`), lone `w` after `gi` (giw → giư), `uow` → ươ always (spec literal, golden agrees; first version turned word-final uo+w into uơ), aa/ee/oo only when the two keys are adjacent (reset, photo, queue), letters after an undo-by-repeat restore the raw keys (session, array, password).
- Coordinator note D14/D15: design was already structural only (no word list, no correction); added a `windows` case.
- run2: all green. clippy: removed `drop(ime)` in stubs (clippy::drop_non_drop), removed unused telex-core dep from ime-core (T4 adds it). fmt clean. Final runs below.

## Quick pass 1 (review 05_review_T2.md, leader decision on BackSpace)
- Finding 1 (golden skip) — fixed: `crates/telex-core/tests/golden.rs` now panics with `cannot read golden list <path>: <err>` when the TSV is missing; the `cases >= 2000` assert covers an empty file. Not run with the file missing (it belongs to T3); the branch is a plain `panic!`.
- Finding 2 (BackSpace) — fixed in `crates/telex-core/src/lib.rs` `Composer::pop`. Rule:
  1. BackSpace removes exactly the last character shown: `ass<` → a, `aaa<` → a, `ddd<` → d, `ww<` → "", `tuw<` → t, `aa<` → "", `nguowi<` → ngươ, `vieet<` → viê, `dduongw<` → đươn, `class<` → clas, `vieetf<` → vieet.
  2. Exception: when the last key only set or cleared the tone (s f r x j z), BackSpace takes that tone back: `vieets<j` → việt, `hoaf<s` → hoá, `asz<` → á.
  3. After BackSpace the composer continues from what is shown. In Vietnamese mode the letters keep their marks and `raw` is rewritten as Telex keys for them (`ngươ` → `nguwow`). After an undo (`as`), when BackSpace brings the text back to the word before the literal key, Vietnamese mode resumes (`ass<s` → á, `booss<s` → bố, `vieet1<j` → việt). In raw mode, the shorter keys are recomposed and kept only if they show the same text (`acf<` → ac, Composing; `acf<s` → ác; `vieetf<` stays raw `vieet`).
  4. If a removed letter leaves no vowel, the tone is dropped.
- New state: `tone_key_last` (set by a tone/z key, cleared by any other key, pop or clear). `Undone` mode now keeps the letters (the text before the literal key) instead of wiping them; `Raw` still wipes them.
- Tests added (red first, qa-artifacts/T2/qp1-red.log: 5 FAILED incl. the updated `raw_and_pop`; 17 wrong outputs, e.g. `"ass<": want "a", got "á"`, `"tuw<": want "t", got "tu"`): `backspace_after_undo_removes_last_shown_char`, `backspace_after_a_mark_removes_the_marked_letter`, `backspace_after_a_tone_key_removes_the_tone`, `backspace_in_raw_words`, `backspace_state_stays_consistent`. `raw_and_pop` updated: `viêt` + 2×BackSpace → `vi` (was `vie` under the replay-raw rule).
- Runs (green):
```
run-heavy.sh cargo test -p telex-core --locked --no-fail-fast -- --nocapture   exit 0 (qp1-test.log)
golden_list: 31552 cases passed
test result: ok. 1 passed; 0 failed     (golden)
test result: ok. 21 passed; 0 failed    (rules)
cargo fmt --check                                                               exit 0
run-heavy.sh cargo clippy --workspace --all-targets --locked -- -D warnings     exit 0 (qp1-clippy.log)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.20s
```
- Rule rows affected: BASE-2 — `pop` doc changed from "remove the last raw key" (plan contract comment) to "remove the last shown character" per leader decision; signature unchanged. BASE-3 — qp1-red.log. AC-1 — the golden test now fails when the list is missing. Nothing left running.

## Files changed
Cargo.toml, Cargo.lock, rust-toolchain.toml, .gitignore, README.md, deny.toml,
crates/telex-core/{Cargo.toml, src/lib.rs, tests/rules.rs, tests/golden.rs},
crates/ime-core/{Cargo.toml, src/lib.rs}, crates/fe-ibus/{Cargo.toml, src/lib.rs}, crates/fe-fcitx/{Cargo.toml, src/lib.rs}, crates/fe-xim/{Cargo.toml, src/lib.rs},
crates/vr-talex/{Cargo.toml, src/main.rs}. Not touched: crates/telex-core/tests/golden/**, tools/** (T3).

## Tests added
- crates/telex-core/tests/rules.rs — 16 tests: tone keys, tone anywhere after the vowel, letter transforms, undo by repeat, more letters after undo → raw, adjacent doubling only, case per letter, modern placement, qu/gi, invalid words raw (class, https, windows, ...), Outcome, raw/pop, clear, non-letter input, precomposed output (every vowel × tone, both cases = 1 code point), redacted Debug.
- crates/telex-core/tests/golden.rs — AC-1 runner over T3's list.

## Commands + trimmed output (full logs in qa-artifacts/T2/)
`run-heavy.sh cargo test -p telex-core --locked --no-fail-fast -- --nocapture` (final-test.log), exit 0:
```
Running tests/golden.rs
golden_list: 31552 cases passed
test result: ok. 1 passed; 0 failed
Running tests/rules.rs
test result: ok. 16 passed; 0 failed
```
`run-heavy.sh cargo clippy --workspace --all-targets --locked -- -D warnings` (clippy.log), exit 0:
```
    Checking vr-talex v0.1.0 (crates/vr-talex)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.17s
```
`cargo fmt --check` → exit 0, no output. `run-heavy.sh cargo run -q -p vr-talex --locked` → exit 0 (stubs return at once).
`cargo tree -e normal --depth 1 --locked`: only workspace crates + tokio v1.54.1 (in vr-talex).
`grep -rn unsafe crates --include=*.rs | grep -v forbid` → empty.

## Deviations / interpretations (leader please confirm)
- rust-toolchain.toml uses `channel = "stable"` (= 1.100.0 here); `channel = "1.100.0"` would make rustup download a second toolchain (BASE-17). The version is pinned by `rust-version = "1.100"`.
- `uow` → ươ always (spec §4 literal; golden agrees). Consequence: `thuở` / `huơ` cannot be typed (`thuowr` → `thưở`). Needs a user decision if wanted.
- aa/ee/oo transform only when the two keys are adjacent (golden English words reset/photo/queue need it); tone keys and `w` stay free (`dduongwf` → đường).
- After an undo-by-repeat the word ends with the literal key (`ass` → `as`); any further letter restores the raw keys (`session`, `password`). So `xoong` cannot be typed (`xooong` → raw); a rare loanword nucleus.
- `Outcome::Invalid` is returned both for raw passthrough and for the post-undo state; `text()` is authoritative. A non-letter given to `push` is appended and makes the word passthrough (the contract says only a-z / A-Z).
- Frontend stub signature: `pub async fn run(_ime: SharedIme) -> ime_core::Result<()>`, `ime_core::Error = Box<dyn Error + Send + Sync>` (no anyhow).
- cargo-deny is not installed (not installed by me, BASE-17): deny.toml is not verified by the tool.
- The golden skip-when-missing branch was not exercised live (T3's file existed from the start; moving it would touch T3's path). Code: `let Ok(data) = read_to_string(..) else { eprintln!("SKIPPED ..."); return; }`.

## Out-of-scope issues noticed
- none.

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| Telex engine, workspace | capabilities.md (missing), repo (LICENSE only) | built new; indexed in capabilities.md |
| Unicode normalization | — | not needed: output comes from a precomposed table; test `output_is_precomposed` |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 | pass | `git status`: only the brief's files + deny.toml (asked by SEC-25); no T3 path touched |
| BASE-2 | pass | Composer API = plan contract (new/push/pop/text/raw/is_empty/clear, Outcome{Composing, Invalid}); stub `run(SharedIme) -> Result<()>` per plan Integration points |
| BASE-3 | pass | red.log: 13/14 rules tests and golden failed on the placeholder before the engine existed |
| BASE-4 | pass | trimmed outputs above; full logs qa-artifacts/T2/*.log |
| BASE-5 | pass | test/clippy/run through run-heavy.sh; nothing left running |
| BASE-6 | pass | English; comments say why (adjacency rule, raw restore, panic=abort) |
| BASE-7 | pass | no commit |
| BASE-8 | pass | one dependency: tokio 1.54.1 (plan Toolchain; latest per `cargo search`; pubtime 2026-10-21; features `rt` only — runtime for async frontends) |
| BASE-10 | pass | only `-p telex-core` tests + workspace clippy, as briefed |
| BASE-11 | pass | no stash/branch/reset commands; T3 paths untouched |
| BASE-14 | pass | all commands foreground through run-heavy.sh, each < 2 s |
| BASE-15 | pass | no background tasks started |
| BASE-16 | pass | ## Reuse table |
| BASE-17 | pass | nothing installed; toolchain channel kept on the installed stable |
| BASE-18 | pass | no agents started |
| BASE-19 | pass | ## Progress from the start |
| BASE-22 | pass | crate names as plan Components |
| BASE-24 | pass | no git add/commit |
| BASE-25 | pass | `cargo fmt --check` exit 0; `cargo clippy --workspace --all-targets --locked -- -D warnings` exit 0 |
| BASE-32 | pass | D5/D13: tests `modern_tone_placement`, `qu_and_gi`; D14/D15: no word list in lib.rs, `invalid_words_pass_through_raw` incl. `windows` |
| BASE-38 | pass | rustfmt ran only on my .rs files |
| BASE-45 | pass | AC-1 text as in 01_spec.md §6 |
| COST-1 | pass | heavy commands via run-heavy.sh |
| COST-3 | pass | no polling |
| COST-8 | pass | files written whole, edits batched per file |
| COST-9 | pass | nothing left running |
| COST-10 | pass | related set = telex-core tests (the only tests of changed code) |
| COST-13 | pass | logs only under qa-artifacts/T2 |
| COST-16 | pass | full output in qa-artifacts/T2/*.log, summaries read |
| TOOL-1 | pass | rustc 1.100.0, edition 2024, tokio 1.54.1 = Toolchain table; zbus/x11rb/xim not added (no crate needs them yet) |
| TOOL-2 | pass | stable only |
| TOOL-3 | pass | resolver 3, workspace.package / workspace.lints, Cargo.lock generated by cargo |
| TOOL-4 | pass | nothing held below latest |
| AC-1 | pass | tests/golden.rs: 31552 cases passed; reports every mismatch; skips with a message if the file is missing |
| SEC-2 | pass | `impl Debug for Composer` prints `Composer { <redacted len=N> }`; test `debug_is_redacted`; no Display; no unwrap/expect on text |
| SEC-25 | pass | Cargo.lock present, all builds `--locked`; deny.toml: crates.io only, unknown-git deny (cargo-deny not installed — not run) |
| SEC-26 | pass | `cargo tree --depth 1`: tokio only; no build.rs in the workspace |
| SEC-27 | pass | `#![forbid(unsafe_code)]` in all 6 crate roots + `[workspace.lints.rust] unsafe_code = "forbid"`; grep unsafe → only forbid lines |

n-a: BASE-9 (no I/O entry point; push(char) handles any char) · BASE-12, BASE-13, BASE-20, BASE-21, BASE-23, BASE-26, BASE-27, BASE-28, BASE-29, BASE-30, BASE-31, BASE-33, BASE-34, BASE-35, BASE-36, BASE-37, BASE-39, BASE-40, BASE-41, BASE-42, BASE-43, BASE-44, BASE-46, BASE-47 (pure library + scaffold: no other repos, removals, secrets, UI, DB, containers, third-party code, browsers, fakes, schema, fix round or runtime env) · COST-2, COST-4, COST-5, COST-6, COST-7, COST-11, COST-12, COST-14, COST-15, COST-17, COST-18, COST-19, COST-20 (no UI, browser, e2e, CI, golden regeneration or full suite)
