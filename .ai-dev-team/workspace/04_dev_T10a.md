# T10a Free-order circumflex and đ in telex-core (D18) + T2 re-check nits

## Progress
- read: brief, decisions D13-D18, skill ai-dev-team:implementation loaded
- red: 5 new rules tests fail for the right reason (qa-artifacts/T10/red.log: 21 passed, 5 failed — free-order keys plain, twnw< Composing)
- code: circumflex/d free-order + pop nits in src/lib.rs; rules green 26/26 (green.log); probe in qa-artifacts/T10/probe
- related run: `cargo test -p telex-core --locked --no-fail-fast` → rules 26/26 ok; golden 34429/34431 (2 golden-data errors, see below); fmt/clippy exit 0
- done

# Summary
- Files changed: `crates/telex-core/src/lib.rs`, `crates/telex-core/tests/rules.rs` (worktree vr-talex-wt-T10, branch t10-free-order; 2 files, +120 −22). T10b's paths not touched.
- Engine (D18):
  - `circumflex()`: a later `a`/`e`/`o` hats the last matching unmarked nucleus vowel when the result parses as a syllable (or prefix); otherwise a plain letter (then the usual raw restore). Undo stays adjacent-only: if no plain match is left and the previous key was the same, the hat is removed and the key is literal (`aaa`→`aa`, `vietee`→`viete`, `tanaa`→`tana`).
  - `apply()`: a later `d` with initial `d` and more letters → `đ` (`dinhd`→đinh, `duowngfd`→đường, `dad`→đa); an adjacent repeat right after that undoes it (`dadd`→`dad`, `dinhdd`→`dinhd`). Initial already `đ` + non-adjacent `d` → plain letter → raw (`dduowngd` stays raw).
  - new helper `prev_key_is()` (shared by both).
- T2 re-check nits: (1) `pop()` Undone branch: when the kept letters do not parse (`twnw<`), raw is set to the shown text and the word goes raw → Outcome::Invalid (test `backspace_after_undo_reports_raw_when_no_syllable_fits`). (2) `pop()` Raw branch: `keys` Vec wiped with `fill('\0')` (SEC-4 best effort; a memory wipe has no observable test — verified by reading lib.rs).
- Tests added (rules.rs): `free_order_circumflex`, `free_order_circumflex_invalid_is_plain_letter`, `free_order_d`, `free_order_keeps_undo_by_repeat`, `backspace_after_free_order_marks`, `backspace_after_undo_reports_raw_when_no_syllable_fits`. Removed `adjacent_doubling_only` (D17 adjacency limit lifted by D18; its cases now in `free_order_circumflex`: `reset`→rết, `photo`→phôt, `tana`→tân).

## Commands (trimmed)
```
red (qa-artifacts/T10/red.log): test result: FAILED. 21 passed; 5 failed
  "vieset": want "viết", got "vieset" ... "twnw<" left: Composing right: Invalid
cargo test -p telex-core --locked --no-fail-fast (qa-artifacts/T10/test.log):
  tests/rules.rs  test result: ok. 26 passed; 0 failed
  tests/golden.rs 2 of 34431 golden cases failed:
    line 33978: "duowngd" want "đường" got "đương"
    line 33985: "Duowngd" want "Đường" got "Đương"
cargo fmt --check -p telex-core → exit 0
run-heavy.sh cargo clippy --workspace --all-targets --locked -- -D warnings → exit 0 (qa-artifacts/T10/clippy.log)
```

## Golden result (AC-1): 34429/34431, 2 data errors in T10b's file
`duowngd` has no tone key, so it cannot give `đường` (huyền). The D18 example drops the `f` (should be `duowngfd` → đường, which `free_order_d` proves). T10b's two rows should read `duowngd<TAB>đương` / `Duowngd<TAB>Đương` (or use `duowngfd`). Not edited by me (T10b's path, BASE-11).

## Probe (qa-artifacts/T10/probe, throwaway scratch crate; its target/ dir can be deleted)
nguoio→nguôi, nhana→nhân, ieue→iêu, aya→ây, data→dât, coco→côc, dodo→đô, teste→tết, dDinh→đinh, didd→did, dduowngd→raw, taata→raw, deadline/hello/update/code/done→raw.

## Deviations / notes for the leader
- Adjacent undo right after a toned free-order hat keeps the tone on the un-hatted letters, e.g. `viesee` → `víee` (same rule as the existing `booss`→`bôs`). Edge case, undo semantics unchanged.
- Hat target: the last matching unmarked vowel of the nucleus, same search as the adjacent form.
- Out of scope: none.

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| syllable check for the free-order trial | lib.rs `try_letters`/`parse` | reused |
| previous-key check | lib.rs `circumflex` (inline code) | extracted to `prev_key_is`, used by circumflex and d |
| BackSpace test helper | rules.rs `type_with_bs`/`check_bs` | reused |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 | pass | `git diff --stat`: only crates/telex-core/src/lib.rs and tests/rules.rs from me; golden/** and tools/golden-gen/** untouched |
| BASE-2 | pass | public Composer API unchanged (new/push/pop/text/raw/is_empty/clear, Outcome) |
| BASE-3 | pass | red.log: 5 new tests failed before the code change |
| BASE-4 | pass | trimmed output above; full logs qa-artifacts/T10/{red,green,test,clippy}.log |
| BASE-5 | pass | test/clippy through run-heavy.sh; nothing left running |
| BASE-6 | pass | English, comments say why (D18 rule, raw when no syllable fits) |
| BASE-7 | pass | no commit |
| BASE-10 | pass | only `-p telex-core` tests + workspace clippy as briefed |
| BASE-11 | pass | T10b's golden/** and gen.py not touched; their data error reported, not fixed |
| BASE-14 | pass | all foreground, each < 5 s |
| BASE-15 | pass | no background tasks |
| BASE-16 | pass | ## Reuse |
| BASE-17 | pass | nothing installed |
| BASE-18 | pass | no agents started |
| BASE-19 | pass | ## Progress from the start |
| BASE-22 | pass | test names follow rules.rs neighbours |
| BASE-24 | pass | no staging, no commit |
| BASE-25 | pass | `cargo fmt --check -p telex-core` exit 0; clippy -D warnings exit 0 |
| BASE-32 | pass | D18: `free_order_*` tests; D15/D16 kept: `invalid_words_pass_through_raw`, `backspace_in_raw_words` green; D14: no word list added |
| BASE-38 | pass | rustfmt check only on telex-core |
| BASE-45 | pass | AC-1 golden run reported as is (2 data errors named) |
| COST-1 | pass | heavy commands via run-heavy.sh |
| COST-3 | pass | no polling |
| COST-8 | pass | edits batched per file, Edit tool only |
| COST-9 | pass | nothing left running |
| COST-10 | pass | related set = telex-core tests (only tests that cover lib.rs) |
| COST-13 | pass | probe and logs only under qa-artifacts/T10 |
| COST-16 | pass | full output in logs, summaries read |
| AC-1 | fail (data) | 34429/34431; the 2 failures are wrong expectations in T10b's golden rows (`duowngd` has no `f`); engine behaviour proven by `free_order_d` |
| D18 | pass | `free_order_circumflex`, `free_order_circumflex_invalid_is_plain_letter`, `free_order_d`, `free_order_keeps_undo_by_repeat`, `backspace_after_free_order_marks` |
| SEC-2 | pass | Debug unchanged (len only); `debug_is_redacted` green; no new Debug/Display/prints |
| SEC-4 | pass | nit 1 test `backspace_after_undo_reports_raw_when_no_syllable_fits`; nit 2 `keys.fill('\0')` in pop Raw branch; old raw wiped via `wipe_string` before it is reset |

n-a: BASE-8 (no dependency added), BASE-9 (no I/O entry point), BASE-12, BASE-13, BASE-20, BASE-21, BASE-23, BASE-26..31, BASE-33..37, BASE-39..44, BASE-46, BASE-47 (pure library: no removals of used code, secrets, UI, DB, containers, third-party code, browsers, fakes, schema or runtime env) · COST-2, COST-4..7, COST-11, COST-12, COST-14, COST-15, COST-17..20 (no UI, browser, e2e, CI or full suite)
