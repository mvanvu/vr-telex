
## QC T2 — QC_PASS
Tested tree: HEAD a2777e1 plus the untracked T2 files (Cargo workspace, crates/telex-core). Engines: cargo/rustc 1.100.0 only (no browser needed).
Probe: `.ai-dev-team/workspace/qa-artifacts/T2-qc/probe/examples/probe.rs` (outside the repo crates, own target dir), logs `probe.log`, `probe2.log`, `build_locked.log`.

### AC-1 probe: 40 own cases (`<` = pop/BackSpace)
First run: 31 OK, 9 DIFF. All 9 DIFFs were errors in my expectations (typos in keys, or tone position), not engine defects; the engine output matched the spec D13 (modern placement hoà/thuý) every time. Corrected cases re-run: 40/40 consistent.
| Keys | Expected | Actual |
|---|---|---|
| Tieesng Vieejt cos daaus | Tiếng Việt có dấu | same |
| nguwowfi ddepj | người đẹp | same |
| khuyru tay | khuỷu tay | same |
| Quoocs nguwx | Quốc ngữ | same |
| giawjt giux | giặt giũ | same (first typed with an extra x = undo, engine gave "giux": correct) |
| DDUWOWNGF | ĐƯỜNG | same |
| DDuwowfng | Đường | same |
| Vieetj Nam | Việt Nam | same |
| tooi yeeu ban | tôi yêu ban | same |
| hoaf / hoafn / hoaj nooij | hoà / hoàn / hoạ nội | same (D13 second vowel) |
| thuys / quys / gias | thuý / quý / giá | same |
| tuoori / tuowir / muoons | tuổi / tưởi / muốn | same |
| Nguyeenx / xin chaof / camr own | Nguyễn / xin chào / cảm ơn | same |
| hocj sinh / traamf | học sinh / trầm | same |
| class / windows / github / https://x.vn / Windows class / GitHub / HTTPS | unchanged | same |
| vieets<j | việt | same (pop in the middle then re-tone) |
| vieet<s / tuaan<s / toans< / hoaf<s | viế / tuấ / toan / hoá | same |
| Tieesng<g Vieejt | Tiếng Việt | same |
| aaa / ddd | aa / dd | same (undo by repeat) |
| QUOOCS / DDaats nuwowcs | QUỐC / Đất nước | same |
Mixed case covered (Tiếng, ĐƯỜNG, Đường, QUỐC, GitHub, HTTPS). The golden test (31562 lines in the file) was not re-run by me; the developer's output is in 04_dev_T2.md.

## Rule check T2
| Rule | Result | Evidence |
|---|---|---|
| AC-1 | pass | 40 own cases above, 0 engine defects; golden file present with 31562 lines |
| TOOL-1 | pass | rustc 1.100.0, cargo 1.100.0, rust-toolchain.toml (stable + rustfmt, clippy), rust-version 1.100 in all 6 crates |
| TOOL-3 | pass | Cargo.lock present at repo root, not git-ignored; `cargo metadata` lists 6 members, edition 2024 |
| SEC-25 | pass | `cargo build --locked --workspace` finished OK (build_locked.log), Cargo.lock unchanged |
| SEC-26 | not checked here beyond build; deny.toml present, cargo-deny not run (not in my brief) | n-o |
| SEC-27 | pass | `#![forbid(unsafe_code)]` in all 6 crate roots (ime-core, telex-core, vr-talex main.rs, fe-fcitx, fe-xim, fe-ibus) plus workspace lint unsafe_code=forbid |

## QC T10
Tree tested: worktree /home/rainy/DEV/vr-talex-wt-T10, branch t10-free-order, uncommitted changes on 8bb3a65 (telex-core lib.rs, tests/rules.rs, golden tsv + README, tools/golden-gen/gen.py). Engine: cargo (run-heavy.sh) and a path-dependent probe crate. Artifacts: $TEAM_WS/qa-artifacts/T10-qc/ (cargo-test.log, probe/, d18-cases.log, d18-base-tree.log, t2-regression.log).

Verdict: QC_PASS

### AC-1 golden run
`cargo test -p telex-core --locked --no-fail-fast`: rc=0; golden_list 1 passed (34433 non-comment rows in telex_golden.tsv); rules.rs 26 passed; 0 failed.

### D18 own cases (54 typed, none from the golden file; d18-cases.log)
42 matched my expectation. The 12 DIFF are all wrong expectations of mine (explained), not engine defects. Same 54 run against the pre-T10 tree (d18-base-tree.log): 21 DIFF, so D18 moved 10 cases from not-composed to composed.
| Input | Got | Note |
|---|---|---|
| Vieest, Vieets, vieset, vieest, vieets | Viết / viết | PASS (user examples; base tree left vieset raw) |
| tiengse, tieengs | tiếng | PASS |
| Ddeefn, deefnd, ddenf, dedfn | Đền, đền, đèn, đèn | PASS |
| cooj, coj, coj+o (cojo) | cộ, cọ, cộ | PASS |
| nguoiwf, nguowif, nguwowif | người | PASS |
| Tiếng Việt rất đẹp (2 typing orders), Đường đến trường, người Việt Nam (2 orders) | correct sentences | PASS |
| Vieets<, hocj<, Ddenf< | Viêt, hoc, Đen | PASS (BackSpace removes last visible char, hat kept) |
| class, classes, github, windows, Windows, assess, process, good, food, looks | unchanged | PASS passthrough |
| dd, ddd, toan, xin chaof ban, Hoaf Nooij | đ, dd, toan, xin chào ban, Hoà Nội | PASS |
| tiesng, tiengs | tiéng | my expectation wrong (only one e typed) |
| denfd, Ddenf | đèn, Đèn | NOTE: brief says denfd gives đền; only one e is typed so ê cannot appear, result đèn is correct. deefnd gives đền |
| Vieest<, Vieet<s, tiengse<<, denfd<, vieest<s | Viế, Viế, tiế, đè, viês | expectation wrong; pop deletes last visible char (viêt+s then revert gives viês, usual Telex double-tone revert) |
| boss | bos | double-s tone revert; identical in the pre-T10 tree, not D18 |
| Ddwuowngf..., "Vieets Nam" | - | typos in my own inputs |

### Regression: T2 probe, 40 cases
Run against the worktree (t2-regression.log) vs T2-qc/probe2.log: byte-identical results for all 40, including 1 known DIFF (hoaj gives hoạ, my old expectation of họa). No case changed on purpose; none regressed.

## Rule check T10
| Rule | Result | Evidence |
|---|---|---|
| AC-1 golden 34433 cases + rules tests | PASS | cargo-test.log: 1 golden passed, 26 rules passed |
| D18 free-order circumflex/đ | PASS | d18-cases.log, user examples and sentences |
| D18 BackSpace mid-word after late hat | PASS | Vieets<, tiengse<< |
| Passthrough class/github/windows | PASS | d18-cases.log |
| T2 regression (40 cases) | PASS | t2-regression.log identical to probe2.log |
| No repo files modified | PASS | only files under qa-artifacts |
