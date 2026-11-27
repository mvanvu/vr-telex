# Review T10 - verdict: APPROVE (2 minor, 1 unverified item)

Reviewer tools: Read, Bash (read-only), Skill, SendMessage, SubagentHandback. A `cargo test` run was refused by the permission classifier, so no test was run by me.

## Files read
crates/telex-core/src/lib.rs (diff + whole engine part) read; tests/rules.rs read; tools/golden-gen/gen.py read; golden/README.md read; golden/telex_golden.tsv skipped as generated except 90 sampled new lines + duplicate-key check (0 duplicates, 34433 cases).

## Traces (by reading code)
- vieset viết, tiengse tiếng, toio tôi, reset rết, photo phôt, dinhd đinh: as D18 says.
- dduowngd: initial already đ, prev key n/g is not d, so `d` is pushed, parse fails, raw. OK.
- viesee: hat is not plain, prev key e, undo: "víee" (tone stays on the un-hatted letters, same as existing `booss`). Minor, see 1.
- twnw<: Undone branch, letters t,w,n do not parse, raw := "twn", Raw mode, Invalid. OK.
- ass<: unchanged path. vieets<j: tone BS replays "vieet", then j gives việt. OK.
- vietej BS: replay of raw minus j = "viete" gives viêt; second BS pop_letter gives "viê", raw resynced "viee". OK.
- dinhd< gives đin; vieset< gives viế (tone kept).
- Adjacent forms, D13 (render unchanged), D16 (validated() unchanged, wrong stop-final tone still raw), raw restore: no regression found.

## Findings
1. [minor] lib.rs:429-436 - undo after a toned free-order hat leaves the tone on the plain vowels: `viesee` gives `víee`. Scenario: user wanted the literal `viesee`-style undo; shows `víee`. Same rule as `booss`, so consistent; the developer noted it. Fix (optional): none needed, or add one golden/rules case documenting it.
2. [minor] gen.py / notes: the final golden list (34433 cases, after the `duowngd` fix) has no recorded green golden run. The only test.log (qa-artifacts/T10/test.log) is from before the fix (34429/34431, 2 data errors, since corrected). I traced the corrected rows (`duowngd` đương, `duowngfd` đường) and 90 sampled new rows by hand: all are correct Vietnamese for their keys and the engine traces agree. QC must run `cargo test -p telex-core --locked` on the final tree to close AC-1 (unverified by me).

## Rule check T10
| Rule | Status | Evidence |
|---|---|---|
| D18 | pass | traces above; tests free_order_* and backspace_after_free_order_marks; invalid result keeps a plain letter (toana, bae, hoeo); undo adjacent-only via prev_key_is |
| D13 / D16 | pass | render/validated untouched; stop-final wrong tone still invalid |
| BackSpace rule (T2 pass 1) | pass | traces above |
| AC-1 | pass (pending final run) | golden.rs reads every line, panics on a missing file; 34433 rows, no duplicate keys; 90 sampled new lines correct; final green run not recorded (finding 2) |
| Generator independence | pass | gen.py imports os/sys/unicodedata/zlib only, never reads crates/telex-core/src; own reverse function; notes say src not read |
| SEC-2 | pass | Debug impl unchanged (len only); no new Debug/Display/prints |
| SEC-4 | pass | pop Raw branch `keys.fill('\0')`; new Undone raw branch wipes raw before reset; Composer `again` cleared |
| T2 nits | pass | twnw< now Invalid with test; keys Vec wiped |
| BASE-1 | pass | worktree diff = 5 allowed files only (lib.rs, rules.rs, golden/**, gen.py) |
| BASE-3 | pass | red.log shows 5 new tests failing first |
| BASE-6 | pass | English, why-comments |
| BASE-25 | pass | fmt/clippy exit 0 per notes (not rerun by me) |
