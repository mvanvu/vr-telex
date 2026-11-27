# Review FR-13: PASS

No blocker or major findings. Read the whole diff (lib.rs, tests/rules.rs). I ran `cargo test -p telex-core --locked` (golden 1, rules 23, all pass). I also ran a throwaway probe of about 85 key sequences (qa-artifacts/FR-13).

## Findings
- [minor] crates/telex-core/tests/rules.rs:211 - no test pins the tone-then-mark undo or mixed-case rows.
  Scenario: `tuwsw`+`a` shows `túwa` and `wWa` shows `Wa`. Both are correct today but unpinned, so a later change could break them unnoticed.
  Fix: add `("tuwswa","túwa")`, `("WWa","Wa")` and `("ddd<d","đ")` rows.

## Checked and fine
- Undone key identification: the raw key before the current one is always the trigger of the last undo. Tone undo triggers are only s f r x j, which never overlap the mark set a e o d w. Undo through a non-letter key leaves a non-letter as "undone", which is not in the mark set. `z` removes the tone and never enters Undone.
- After BackSpace the mode goes back to Viet in every probed case (`ddda<a`→`dda`, `aaa<a`→`â`, `ww<w`→`ư`, `ddd<d`→`đ`). The Undone state does not keep a stale trigger.
- `Composer::horn` uppercase `W`: the literal takes the case of the removed ư only when that ư was upper. `Wwa`→`Wa`, `WWa`→`Wa`, `WWA`→`WA`, `wWa`→`Wa`, `Wwwa`→`Wwa`. No panic and no wrong removal. A lone `ư` that is not the last letter still becomes `w` as before.
- D37 unchanged: `session`, `array`, `offline`, `asss`, `assa`, `asssa` still restore raw; `lisst`→`list`.
- SEC-2/SEC-4: no logging or Debug added and no new buffers. `continue_shown` keeps its existing wipes.

## Rule check FR-13
| Rule | Result | Evidence |
|---|---|---|
| D39 | pass | Probe: ww→w, wwa→wa, www→ww, ddda→dda, aaai→aai, Wwa→Wa, eeea→eea, oooa→ooa, dddd→ddd, wwl→wl, tuwwa→tuwa. Test `letters_after_a_mark_undo_continue_the_shown_text` is green. |
| D37 | pass | Probe and existing tests: session, array, offline, asss, assa stay raw; lisst→list. |
| AC-1 | pass | I ran the suite: golden 1 and rules 23 passed. |
| SEC-2/SEC-4 | pass | No new logging or buffers in the diff. |

## Files read
- crates/telex-core/src/lib.rs: read
- crates/telex-core/tests/rules.rs: read
- .ai-dev-team/workspace/04_dev_FR-13.md: read

## Re-check quick pass 1: PASS
No new findings. My earlier minor test rows (`tuwswa`, `WWa`, `ddd<d`) are now in rules.rs.
- The same-key test compares lower-cased keys, so `WwW`, `AaAa` and `DdDd` restore the raw keys.
- The new branch runs only when the undone key is a mark key (a e o d w). Tone undos (s f r x j) skip it, so D37 is unchanged: `asss`, `assss`, `assa`, `asssa`, `Asss`, `session`, `array`, `offline` and `lissst` restore raw, and `lisst` gives `list`.
- BackSpace: `www<`→`ww`, `www<<`→`w`, `wwww<`→`www`, `wwwww<`→`wwww`, `aaaa<`→`aaa`, `dddd<`→`ddd`, `www<w`→`www`. Each removes exactly one character.
- Other letters still continue the shown text: `wwa`→`wa`, `ddda`→`dda`, `aaai`→`aai`, `wwl`→`wl`, `dddl`→`ddl`, `tuwswa`→`túwa`.
- One consequence to note: `Wwwa` gives `Wwwa` (the same key restores the raw keys, then `a` goes on from that), which is consistent with D40.
- `cargo test -p telex-core --locked`: golden 1 passed, rules 23 passed.

| Rule | Result | Evidence |
|---|---|---|
| D40 | pass | www, WWW, WwW, aaaa, dddd restore raw; `www<`→`ww`; `wwww<`→`www` |
| D39 | pass | wwa, ddda, aaai, wwl, WWa, tuwswa continue the shown text |
| D37 | pass | tone undos unchanged (probe above) |
| AC-1 | pass | suite green |
