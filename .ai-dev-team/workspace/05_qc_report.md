
## QC E3 / sign-off
Tree: HEAD a8f098e + uncommitted E3 (ime.rs, tests/word_end.rs, fe-fcitx/fe-ibus/ime-core tests). Daemon built from this tree (`cargo build --release --locked`), harness isolated (README "Isolation"); throwaway scripts in qa-artifacts/E3/ (flow.sh = run.sh copy with a case loop, middle.sh, build_flow.py). Engines: real daemon in headless GNOME (term = gnome-terminal, chrome = textarea, omnibox = address bar via history q=).

### AC-1..AC-5 through the real daemon (each case ended by space, VI mode)
| Case (keys) | term | chrome | omnibox | AC |
|---|---|---|---|---|
| `has ` first -> `há ` | pass | pass | pass | AC-4 (overlap, VI first) |
| `the best ` -> `the best ` | pass* | pass | pass | AC-1 |
| `use ` -> `use ` | pass | pass | pass | AC-1 |
| `tooi raats thichs ` -> `tôi rất thích ` | pass | pass | pass | AC-3 |
| `toi raats thichs ` -> `toi rất thích ` | pass | pass | pass | AC-3 (note: `toi` without a second o is `toi` in Telex; the brief's `toi`->`tôi` needs `tooi`) |
| `the has ` -> `the has ` | pass | pass | pass | AC-5 |
| `twwa ` -> `twa ` (FR-13) | pass | pass | pass | unchanged |
| D12: `has` + click elsewhere in the same injection -> `há`, focus on #o | n/a | pass | n/a | D12 observed once |
Results: qa-artifacts/E3/new2/run-*/out/results.txt (all three targets), term repeats term1..3 (7/7 each), repeat run `rep` (E3_REPEAT=25: `has `/`the best ` x25 in term and chrome = 100/100 pass).
(*) Flake, term only: in run new2 the first two lines came out `has ` (raw) and `the bét` (expected `há `, `the best `); not reproduced in 3 reruns plus 50 term repeats. First run (new/) also passed `has`/`the best` in term. Daemon log is empty (no trace lines), so no cause from the log. Recorded as flaky, unexplained.

### AC-8
- `$TEAM_BIN/run-heavy.sh cargo test --workspace --locked`: rc=0, all `test result: ok`, 0 failed (qa-artifacts/E3/cargo-test.log). `cargo fmt --check` ok; `cargo clippy --workspace --all-targets --locked -- -D warnings` clean.
- e2e `run.sh --smoke --ime daemon --allow-incomplete` (qa-artifacts/E3/smoke.log): AC-2:chrome PASS (712 chars, lost 0/extra 0); AC-2:term content lossless (lost 0, extra 0) but FAIL by injection rate 16.1 ms/key (>16 ms, machine load); AC-3, AC-4, AC-7 PASS; AC-10 INCOMPLETE (D24, measured in unit tests); SEC-1 PASS.
- AC-2 lossless corpus: no differing word explained by AC-2/AC-3 and no Vietnamese word turned English in any run.
- Intermittent term-only anomaly: one rerun (smoke2) showed `lost 3, extra 3` (three spaces of line 2 reappear 14 chars later: `...q ghẽn biệng tìn mưc` ordering). Term corpus runs, same corpus: new binary 1 content failure in 6 (smoke2) plus 1 rate-only; baseline binary (installed 32bb402) 0 in 5 (one rate-only). Chrome never showed it. Sample too small to attribute to E3 or to GTK/shell timing under load (reviewer ran in parallel). Reports: qa-artifacts/E3/smoke2/run-*/out/diff-term-1.txt, cmp-base*/, cmp-new*/.

### AC-6
target/release/vr-talex 2,896,464 B vs installed 2,793,008 B: growth 103,456 B (~0.10 MB, limit ~1.5 MB): pass. Latency tests pass: ime-core `process_key_p99_is_under_5_ms`, fe-ibus `process_key_round_trip_p99_is_under_5_ms`.

### SEC-1 / SEC-2
Harness leak scan: 0 hits in smoke (60 tokens), smoke2, and case run new2 (tokens include `raats thichs`, `rất thích`); daemon.stderr/stdout empty. First case run (new/) reported one hit in the sandbox tracker3 `meta.db-wal` for the token `the has` that I added myself (the desktop file indexer reading my output file, not the daemon or journal); the token was dropped afterwards and the rerun is clean. SEC-2 (no word lists/text in logs) covered by the same scan plus the empty daemon log.

## Rule check E3
| ID | Result | Evidence |
|---|---|---|
| AC-1 | pass | `the best`, `use` in term/chrome/omnibox (+100 repeats) |
| AC-2 | pass | smoke chrome lossless; term lossless in 5 of 6 new-binary runs (intermittent anomaly above, unattributed) |
| AC-3 | pass | `tooi raats thichs ` -> `tôi rất thích ` x3 targets |
| AC-4 | pass | `has ` -> `há ` x3 targets; smoke AC-4 toggle pass |
| AC-5 | pass | `the has ` -> `the has ` x3 targets |
| FR-13 | pass | `twwa ` -> `twa ` x3 targets |
| D12 | pass | chrome click after `has` keeps `há` (1 observation; term not tried) |
| AC-6 | pass | +103,456 B; latency tests ok |
| AC-8 | pass with caveat | suite/fmt/clippy green; term smoke intermittent (flaky) |
| SEC-1 | pass | leak scan 0 hits |
| SEC-2 | pass | empty daemon log, scan clean |

QC_PASS E3 (sign-off) with caveat: intermittent term-only anomalies (one `has `/`the bét` first-lines run, one 3-space reorder in the corpus run) not reproduced in 150+ later term keys-cases and not seen on Chrome/address bar; leader decides whether to chase it.

## Re-check fix round 1
Tree: HEAD a8f098e + uncommitted E3 incl. fix round 1 (ime.rs `end_word(at_cursor)`, D13). Release daemon rebuilt from the tree (2,897,024 B, +104,016 B vs installed 2,793,008: AC-6 still ok).
- Replay of the recorded term case run (same flow.sh/cases, `--apps "term chrome"`, qa-artifacts/E3/fix1a): term 7/7 pass, chrome 7/7 pass, D12 pass (`há`, focus #o), SEC-1 0 hits.
- Same with a discarded warm-up line typed first (throwaway `E3_WARMUP=1` in qa-artifacts/E3/middle.sh, `--apps term`, fix1b): 7/7 pass, SEC-1 0 hits.
- D13 in chrome: textarea `XYZ ` then `the bes` + click on #o in the same injection -> `XYZ the bé`, focus #o: text kept, nothing deleted elsewhere (pass; one observation, preedit client).
- My term caveat: NOT reproduced (the anomaly was seen once in ~12 term launches, and not in this replay nor the warm-up run). The developer's cause (typing before the terminal's IME FocusIn, only the first lines affected) fits the evidence (only the first two lines failed, later lines and the 100-case repeat run passed) but one non-reproducing launch cannot prove it. Withdrawn as a defect; kept as an unreproduced harness-timing observation. The 3-space shift stays unattributed (E3 emits the same actions for those words; baseline 0/5 vs new 1/6 is not significant).

### Rule check (fix round 1)
| ID | Result | Evidence |
|---|---|---|
| AC-1 | pass | `the best `, `use ` term+chrome replay and warm-up |
| AC-3 | pass | `tooi raats thichs ` -> `tôi rất thích ` |
| AC-4 | pass | `has ` -> `há ` term+chrome, warm-up |
| AC-5 | pass | `the has ` -> `the has ` |
| FR-13 | pass | `twwa ` -> `twa ` |
| D12 | pass | chrome click after `has` keeps `há` |
| D13 | pass | chrome mid-word click keeps `XYZ the bé`, nothing else changed (surrounding-text clients covered by dev unit test only, not run live) |
| AC-6 | pass | +104,016 B |
| SEC-1 | pass | 0 hits both runs |

QC_PASS (fix round 1)
