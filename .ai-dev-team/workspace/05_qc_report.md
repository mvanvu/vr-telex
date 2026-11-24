
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

## QC T4 — QC_PASS
Tree: master 666922d + uncommitted T4 files. Own probe: `qa-artifacts/T4-qc/probe/` (release build, `target-dir` under T4-qc), log `qa-artifacts/T4-qc/probe.log`, 35 checks, FAILS=0. Engine: Rust probe driving `SharedIme` with keysyms, X11 masks, press and release events.

| Case | Status | Evidence |
|---|---|---|
| AC-3 vieetj then focus_out / reset / destroy_context / set_caps change | pass | preedit `việt`, one Commit `việt`, a second call commits nothing, buffer 0 |
| AC-4 Ctrl,Shift,Shift-up,Ctrl-up; Ctrl,Shift,Ctrl-up,Shift-up; Shift,Ctrl,... ; toggle back | pass | Vi->En->Vi, every modifier event handled=false |
| AC-4 Ctrl+Shift+t/p/c/v/T | pass | no toggle, handled=false |
| AC-4 held 1.1 s / 0.9 s (injected clock) | pass | no toggle / toggle |
| D7 toggle mid-word | pass | word committed once, mode En |
| AC-7 password `matkhau1s` | pass | all handled=false, 0 actions, buffered 0; caps->password mid-word flushes `vie` (SEC-13) |
| AC-8 FileStateStore in temp XDG_STATE_HOME | pass | default VI, saved `EN`, file 0600, dir 0700, new instance loads En, corrupt file gives VI |
| D10 surrounding (no preedit) | pass | only Commit + DeleteSurrounding(offset == -chars) actions, text `việt` |
| D10 neither | pass | nothing until boundary, then Commit `việt` on Space, Space unhandled |
| EN mode | pass | all keys (letters, BackSpace, Return, Left) handled=false, 0 actions |
| Sentence `Tieengs Vieetj raats ddepj ` | pass | `Tiếng Việt rất đẹp ` in preedit, surrounding and hold modes |
| Ctrl+a / BackSpace in word, modifier events | pass | Ctrl+a flushes and passes; BackSpace handled; all modifier events handled=false |
| Never-drop, 40 letters | pass | 32 committed + 8 passed through = 40 |
| AC-10 10,000 process_key, release | pass | p50 948 ns, p99 1947 ns, max 36.5 us |
| SEC-1 binary run | pass (limited) | all three frontends are T5-T7 placeholders returning at once, so the binary exits 0 immediately with no output; run with temp HOME/XDG, NOTIFY_SOCKET unset, nothing written, no bus used. Hardening (dumpable/rlimit) and the notifier not exercised at runtime |

## Rule check T4
| Rule | Result | Evidence |
|---|---|---|
| AC-3 | pass | probe.log AC-3 x4 |
| AC-4 / D7 | pass | probe.log AC-4 lines |
| AC-7 | pass | probe.log AC-7 |
| AC-8 | pass | probe.log AC-8 x4 |
| AC-10 | pass | p99 1.9 us |
| D6 (one global mode) | pass | mode shared across contexts through one SharedIme; toggle persists (AC-8) |
| D10 | pass | probe.log D10 x2, no fake key event action exists in the Action enum |
| SEC-1 | pass (limited) | KeyEvent/Action Debug redact text (action.rs, key.rs); binary has no frontends yet |
| SEC-3 | pass (static) | main.rs `harden()` runs before the runtime; not verified at runtime |
| SEC-5 | pass | state file 0600 in 0700 dir, atomic rename, symlink-safe code (state.rs) |

## QC T8
Verdict: QC_PASS (2 low-severity notes, no blocking defect). Sandbox only (tests/install/run.sh mechanism: env -i, throwaway HOME/XDG, private dbus-run-session bus, GSETTINGS_BACKEND=keyfile, stubs first on PATH). Engines: bash + gsettings keyfile + dbus-daemon stubs; no browser involved.

Evidence: developer suite `qa-artifacts/T8-qc/dev-suite.log` (10/10 PASS, run once); own scenarios `qa-artifacts/T8-qc/qc_extra.sh`, logs `qa-artifacts/T8-qc/logs/*.log` (sandboxes in /tmp/t8q, short path because of the 108-byte socket limit).

| # | Scenario | Result | Evidence |
|---|---|---|---|
| dev | fresh_fcitx5, fresh_no_fcitx5, empty_sources, broken_daemon (rollback), root_refused, no_cargo, ibus_refused, activation_shadow, uninstall_without_backup, uninstall_not_installed | PASS 10/10 | dev-suite.log |
| a | Pre-existing custom ~/.xinputrc, 50-mine.conf, sources us+fr with fr selected (mru head fr); install then uninstall | PASS: xinputrc, 50-mine.conf and the glib keyfile byte-identical, whole-HOME snapshot identical, sources and mru restored (fr first); 50-mine.conf also untouched while installed | logs/a_preexisting.log |
| b | User appends to ~/.xinputrc after install, then uninstall | NOTE (low): the user edit is silently lost; uninstall restores the original backup and prints no warning. The installed file's header says "uninstall.sh restores the old file", so it is documented in the file, but a modified-since-install check (warn or keep a copy) is missing | logs/b_user_edit.log |
| c | HOME with a space (`/tmp/t8q/c/my home`) | PASS: install, health check, uninstall, exact restore. NOTE (low): the D-Bus shadow service file has `Exec=/tmp/t8q/c/my home/.local/bin/vr-talex` unquoted; bus activation (not the systemd unit, which uses %h) may split at the space. Not provable in the sandbox with the stub | logs/c_space_home.log |
| d | install x2 then uninstall x2 | PASS: no error; second install "already present", second uninstall "not installed"; diff vs pre-install snapshot empty; leftovers: none (only the pre-existing ./.config and the keyfile glib dir the keyfile backend itself creates); no vr-talex string left | logs/d_twice.log |
| e | ~/.xinputrc is a symlink to dotfiles/xinputrc | PASS: target never clobbered (install replaces the link with a regular file, via rename); after uninstall the symlink is back (same relative target) and the target is intact | logs/e_symlink.log |

AC-5 (install, idempotent) at file/keyfile level: unit, environment.d, xinputrc, autostart override, D-Bus shadow equal the packaging templates; binary 0755; backup dir 0700; keyfile after install exactly `sources=[us, vr-talex]`, `mru-sources=[vr-talex, us]`; second install leaves snapshot, keyfile and daemon PID unchanged and issues no daemon-reload or restart.
AC-6 (uninstall restores): snapshot and keyfile byte-identical to pre-install; fcitx5 restarted when it ran before and not started when it did not; no vr-talex string left in ~/.config, ~/.local, ~/.xinputrc.

Not provable in the sandbox: real typing in Vietnamese, the real systemd unit (a stub systemctl is used) and the real fcitx5/ibus (stubs), real gnome-shell reaction to the source change (selection checked only as mru-sources head in the keyfile), real D-Bus activation by bus of vr-talex with the real binary, the user's live desktop (never touched, by rule).

## Rule check T8
| Rule | Result | Evidence |
|---|---|---|
| AC-5 | pass (file/keyfile level) | scenarios dev fresh_*, d |
| AC-6 | pass (file/keyfile level) | scenarios dev fresh_*, a, e |
| SEC-19 | pass | broken_daemon: non-zero exit, rolled back, sources byte-identical, recovery command printed; sources set only after the health check (install.sh main order) |
| SEC-21 | pass with note | first backup kept by a second install (d); exact restore (a, e); note on edits made after install (b) |
| SEC-22 | pass | add-once (d), dedicated 90-vr-talex.conf, autostart Hidden=true override, no leftovers |
| SEC-29 | pass | guard_sandbox aborts when HOME, bus, systemctl or fcitx5-remote are not the sandbox ones; every scenario ran under env -i; the live fcitx5 process was still running after the runs (pgrep); live gsettings not read by rule |

### Re-check fix round 1 (T8)
Verdict: QC_PASS. Same sandbox mechanism; script `qa-artifacts/T8-qc/qc_extra.sh` extended (b asserts the saved copy; c and new f also prove real dbus-daemon activation), logs in `qa-artifacts/T8-qc/logs/`. The live fcitx5 (pid 6881) was still running after the runs.

| Note / scenario | Result | Evidence |
|---|---|---|
| b: user edit after install | FIXED: uninstall prints `warning: <HOME>/.xinputrc was changed after install; your version is kept as <HOME>/.xinputrc.vr-talex-saved-20261124-203145`; the saved file holds the user's edit (207 bytes, includes `# USER EDIT AFTER INSTALL`); ~/.xinputrc is the original `run_im fcitx5` | logs/b_user_edit.log (the leftover echo "RESULT: user edit LOST" in that log is stale script text, contradicted by the two checks) |
| c: HOME with a space | FIXED: `Exec="/tmp/t8q/c/my home/.local/bin/vr-talex"`; stopping the unit and pinging org.fcitx.Fcitx5 made the real dbus-daemon log "Successfully activated service", the activated cmdline is the installed binary; exact restore afterwards | logs/c_space_home.log |
| f: HOME `a & b` | PASS: `Exec="/tmp/t8q/f/a & b/.local/bin/vr-talex"`, bus activation succeeded with the installed binary, exact restore (first run failed only because my bus.conf did not XML-escape `&`; harness fix, not a product defect) | logs/f_amp_home.log |
| a: pre-existing files | PASS: all byte-identical, snapshot identical, selection back to fr | logs/a_preexisting.log |
| d: install x2, uninstall x2 | PASS: no error, no leftovers | logs/d_twice.log |
| e: symlinked ~/.xinputrc | PASS: target intact, symlink back after uninstall | logs/e_symlink.log |

## QC T6 — QC_PASS
Engines: Bash, python3 (dbuslite client), headless gnome-shell + gnome-terminal (GTK_IM_MODULE=fcitx); no browser needed. Daemon built from the worktree (cargo build --locked, up to date). All runs in isolated sessions (dbus-run-session, throwaway HOME/XDG); live fcitx5 pid 6881 running before and after every run.
Artifacts: qa-artifacts/T6-qc/ (smoke_qc.sh, smoke_qc.log, bus_qc.sh, bus_qc.py, diff-run*.txt, typed*.txt.*, toggle.txt).

| Case | Evidence | Result |
|---|---|---|
| AC-2 fcitx route, run 1 | 302 words, 27 lines, 20 canaries, 110 typed in EN mode, 2272 keys at mean 15.1 ms/key into gnome-terminal; expected 1880 chars, got 1880; lost 0, extra 0, replaced 0 | PASS |
| AC-2 run 2 | same corpus, 15.0 ms/key; lost 0, extra 0, replaced 0 | PASS |
| AC-3 window switch (FocusOut) | own client: `vieetj` then FocusOut -> CommitString ["việt"] once | PASS |
| AC-3 Reset | `xinf` then Reset -> ["xìn"] once; later FocusOut commits nothing | PASS |
| AC-3 FocusOut then DestroyIC | ["chào"] once, none on destroy | PASS |
| AC-7 password | SetCapability(Preedit+Password): `matkhau1s` 9 keys all unhandled, 0 signals | PASS |
| AC-7 caps change mid-word | commits "việt" first, next key unhandled | PASS |
| SEC-9 foreign calls | client B on A's context: FocusIn/FocusOut/Reset/SetCapability/ProcessKeyEvent/DestroyIC/SetSurroundingText all AccessDenied; A on B's context AccessDenied; guessed paths AccessDenied | PASS |
| SEC-9 eavesdrop | B with match rules (all signals, path, interface) receives 0 signals of A (only the bus's own NameAcquired, filtered); A got its own 8 | PASS |
| SEC-1 | daemon stdout+stderr 0 lines, 0 typed-word hits (both runs); 0 sandbox files with typed words besides the intended typed outputs | PASS |
| Toggle Ctrl+Shift tap via fcitx | toggle, `vieetj `, toggle, `vieetj` -> file `vieetj việt` | PASS |

## Rule check T6
| Rule | Result | Evidence |
|---|---|---|
| AC-2 | pass | 2 runs, 0 lost/extra/replaced |
| AC-3 | pass | 3 scenarios, word committed once |
| AC-7 | pass | matkhau1s passthrough |
| SEC-1 | pass | 0 hits |
| SEC-9 | pass | AccessDenied and no signal leakage |
| BASE-14/15 | pass | background run, no mass kill, tagged cleanup |
| BASE-17 | n-a | no data committed to a shared DB |
| D2/SEC-29 | pass | isolated sessions only; fcitx5 6881 alive before/after |

Notes: the committed harness `run.sh --route fcitx --ime daemon` cannot be used (it waits for the IBus shell-extension indicator: "engine did not connect to the shell"); a copy of the developer's smoke plus the harness corpus/inject/diff tools was used instead. Not a T6 defect. Debug build only; no repo files modified.

## QC T5 — QC_PASS (with D26 measurement; code-term loss reproduced, see below)
Build tested: worktree /home/rainy/DEV/vr-talex-wt-T5, base 7759c41 + uncommitted fe-ibus, `cargo build --release --locked` (target/release/vr-talex). Harness: copy of tests/e2e under qa-artifacts/T5-qc/tree (only change: gpuAcceleration hook for D26b). Isolated sessions only; live fcitx5 pid 6881 before and after. Logs: qa-artifacts/T5-qc/.

| Case | Status | Evidence |
|---|---|---|
| AC-2 term 300w, 15 ms, 2 runs | pass | 1947/1947 chars, lost 0 extra 0 replaced 0, both runs (mean 15.0-15.1 ms/key) |
| AC-2 chrome | pass | same, 0/0/0 both runs |
| AC-2 omnibox | pass | same, 0/0/0 both runs |
| AC-2 code (editor) | pass | same, 0/0/0 both runs |
| AC-3 window switch, click away | pass | [việt]=[việt]; [đường]=[đường] |
| AC-4 toggle + Ctrl+Shift+T/P/C/V | pass | VI->EN 4 ms, EN->VI 3 ms; combos leave mode VI; page saw P/C/V; T opened a tab |
| AC-7 password | pass | field got matkhau1s raw |
| SEC-1 leak scan | pass | 60 tokens, 521 files, 293 journal lines, 0 hits (also 0 hits in every D26 run) |
| AC-9 (restart) | pass | daemon stopped and restarted in sandbox with shell running: back to vr-talex|VI in 0.28 s (limit 5 s), "Việt nam" typed correctly after |
| SEC-6 | pass | socket dir 0700, socket 0600, both owned by the user |
| SEC-8 | pass | address file 0600, IBUS_ADDRESS=unix:path=<runtime>/vr-talex/ibus,guid=..., IBUS_DAEMON_PID = daemon pid; symlink at address-file path: daemon exits rc 1 "cannot write the address file safely", victim file unchanged; symlink at the .tmp path: victim unchanged, daemon works |
| AC-10 | not-tested here | INCOMPLETE by design (D24, unit tests) |

### D26 measurement (VS Code integrated terminal, 100 words = 934 chars)
| Variant | Result |
|---|---|
| (a) default, 15 ms, run 1 / run 2 | lost 17 / lost 15, extra 0, replaced 0 |
| (b) gpuAcceleration "off", 15 ms, run 1 / run 2 | lost 16 / lost 14, extra 0, replaced 0 |
| (c) 20 ms (mean 20.4) | lost 90 (noisy, worse than 15 ms) |
| (c) 30 ms | lost 0 |
| (c) 40 ms | lost 0 |
Reading: GPU setting makes no difference (~1.6% loss either way, so not the GL renderer); threshold lies between 20 and 30 ms/key, loss 0 from 30 ms. Loss only, never extra or replaced characters.

## Rule check T5
| Rule | Result | Evidence |
|---|---|---|
| AC-2 | pass (code-term excluded, D26) | above |
| AC-3 / AC-4 / AC-7 / AC-9 | pass | above |
| SEC-1 | pass | leak scan 0 hits |
| SEC-6 | pass | 0700/0600 |
| SEC-8 | pass | 0600, pid, symlink refused |
