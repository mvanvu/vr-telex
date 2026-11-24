# T1 Spike: hot apply + client routes on GNOME 46

Mode: implement (spike, throwaway code). Side: be. Result: `.ai-dev-team/workspace/03_spike.md`. Throwaway code: `.ai-dev-team/workspace/qa-artifacts/T1/` (gitignored).
Tools available to this agent: Bash, Read, Write, Edit, Skill, ToolSearch (deferred WebFetch/TaskStop not needed), Artifact/Agent (not used).

## Progress
- read: spec §1/§5/§7, plan contracts, decisions D1–D13, SEC-6/8/29, BASE §3, COST §7, gnome-shell `misc/ibusManager.js`, `misc/inputMethod.js`, `ui/status/keyboard.js` (via `gresource extract`), libibus 1.5.29 `ibusbus.c` / `ibusshare.c`.
- wrote `lib.sh` (isolated env, live-desktop guard, tagged cleanup), `rd.py` (RemoteDesktop injector), `q1.sh`.
- q1 / q1c: headless shell + gnome-terminal + typing OK; Chrome 157 and VS Code 1.145 are native Wayland clients.
- wrote `fake_ibus.py`; q3 session/private: hot connect proven (running gnome-terminal gets the IME ~0.5 s after the address file); private socket fails open on service death, session-bus variant drops keys.
- wrote `fake_fcitx.py`, `q4.sh`; found X11 clients hang without `org.freedesktop.systemd1` on the isolated bus → `fake_systemd.py`; added `wait_win`.
- q4 fcitx / ibus × 3 apps: route matrix measured.
- q5 fake + q5 real (isolated second fcitx5 instance): both reconnect paths proven.
- Rust mini broker (`broker/`, zbus 6.5.0) built; q3 rust: accepted by gnome-shell, hot connect, fail-open.
- q2b: 614 keys at 18.7 and 7.4 ms/key through shell → IBus toy → terminal, text equal.
- wrote `03_spike.md`; final checks: no tagged process left, live fcitx5 pid 6881 unchanged, live address files untouched.

## Files
- Changed in the repo tree: `.ai-dev-team/workspace/03_spike.md` (new), `.ai-dev-team/workspace/04_dev_T1.md` (new). No tracked file changed.
- Throwaway (gitignored) under `.ai-dev-team/workspace/qa-artifacts/T1/`: `lib.sh`, `rd.py`, `fake_ibus.py`, `fake_fcitx.py`, `fake_systemd.py`, `q1.sh`, `q1c.sh`, `q2b.sh`, `q3.sh`, `q4.sh`, `q5.sh`, `broker/` (Cargo project; `target/` is 378 MB and can be deleted), `gres/` (extracted shell JS), `src-ibus/`, `src-fcitx/` (downloaded upstream sources for citation), `logs/`, `h/`, `r/` (throwaway HOME and runtime dir of the last run). `q1b.sh` is superseded by `q1c.sh`/`q4.sh` (it exports no stand-in systemd and prints less).
- Tests added: none (spike; see BASE-3).

## Commands run + result (trimmed)
All through `$TEAM_BIN/run-heavy.sh bash <script>`; full outputs in `qa-artifacts/T1/logs/*.out` and `logs/<run>/`.
```
q1.sh          typed file: [hello world 123 Viet Nam]
q1c.sh ""      t=3s (true, '"google-chrome:1214:true:about:blank - Google Chrome"')
q2b.sh         run 1: 613 chars, expected 613, equal=True / run 2: … equal=True; ProcessKeyEvent seen: 2456
q3.sh private  typed after service (same running terminal): [abc def|XIN CHAO|]; after death: […|dead svc|]; after second: […|SECOND SVC|]
q3.sh session  typed after service death: [abc def|XIN CHAO|]   (keys lost while the name has no owner)
q3.sh rust     [:1.1] authenticated (EXTERNAL), peer uid Some(1000); typed …[abc def|xin chao|dead svc|second svc|]
q4.sh fcitx    gnome-terminal [[xin] [chao]|] via fcitx-dbus=18; chrome V:XIN CHAO|#comp=2 via ibus=20; vscode [XIN CHAO ] via ibus=20
q4.sh ibus     gnome-terminal [XIN CHAO|] via ibus=18; chrome V:XIN CHAO| via ibus=20; vscode [XIN CHAO ] via ibus=20
q5.sh fake     3 typed after a new process took org.fcitx.Fcitx5 (same terminal): […|{second} {owner}|]
q5.sh real     after fcitx5-remote -e: process alive=no; address files: IBUS_ADDRESS= IBUS_DAEMON_PID= ; then same as fake
cargo build    Finished `dev` profile [unoptimized + debuginfo] (logs/broker-build.log)
```

## Deviations and things to know
- Harness teardown: the experiment scripts start a compositor and apps as their own children and stop them at exit with `kill` on the exact pids that carry the run's `VRT1_TAG` environment value (`lib.sh: cleanup`). No `pkill`/`killall`, nothing by name. This is the test harness stopping its own children, not `TaskStop`; reported here because BASE-15 names `TaskStop` only.
- The scripts contain fixed short pauses and one bounded wait (`wait_win`, max 30 s) for windows to map; the agent itself did not poll.
- A second fcitx5 instance was started inside the isolated session (`q5.sh real`: own bus, own HOME, own Wayland display) and asked to quit with `fcitx5-remote -e` on the isolated bus. The live fcitx5 (pid 6881) was never addressed; `guard` runs before both commands.
- `fake_ibus.py` uses libibus through GObject introspection only to serialize test values (throwaway tooling; the product stays libibus-free, G2).
- Two runs hit the run-heavy timeout: `q4.sh fcitx` at 110 s and 200 s, hung in `xlsclients` against an X display whose X11 services never started (root cause found, see `03_spike.md` Q1; `timeout 5` added). One of them was moved to the background by the tool after 180 s (it had queued behind another project's build); it ended on its own.
- BLOCKED-STEP: writing scripts through a Bash heredoc — the team guard hook rejects command text containing `&` / `kill` (BASE-14/15 patterns). Next route: the Write tool. No effect on results.
- BLOCKED-STEP: an inline `for … do :; done` + grep one-liner was rejected by the COST-8 hook as an inline script; reran as plain greps.
- Python crashed twice (`fake_ibus.py`, PyGObject property closures / floating variants) before the fix; apport is the core handler, no core file was left in the workspace.

## Out-of-scope issues noticed
- Plan fact F2 is outdated: Chrome/VS Code are Wayland-native and do not use the fcitx module (affects T6's reason, D8 wording).
- `org.fcitx.Fcitx5.service` D-Bus activation file can restart the real fcitx5 when vr-talex is down (T8).
- gnome-shell's own password dialog sends keys through the IBus context (B5 must cover it, T4/T5).
- Open items O1–O5 in `03_spike.md` (live run by the user; stock Ubuntu with ibus-daemon; X11 session; Qt apps; next-login environment).

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| isolated GNOME session helpers, key injector, fake services | `.ai-dev-team/capabilities.md` (does not exist yet), `ls .ai-dev-team/workspace/` | nothing to reuse; built new under `qa-artifacts/T1/`. Reusable by T9: `lib.sh`, `rd.py`, `fake_systemd.py` (listed in `03_spike.md` Q6.8; not added to an index because `capabilities.md` is the leader's file and absent) |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 | pass | `git status --short`: only `03_spike.md`, `04_dev_T1.md` are mine (untracked); everything else under gitignored `qa-artifacts/T1/` |
| BASE-3 | n-a | spike with throwaway code, no product behaviour; each answer is proven by a script run instead (`qa-artifacts/T1/q*.sh`, outputs in `logs/*.out`) |
| BASE-4 | pass | "Commands run + result" above; full output `qa-artifacts/T1/logs/` |
| BASE-5 | pass | every gnome-shell / browser / cargo run went through `run-heavy.sh`; final scan for `VRT1_TAG` processes printed none |
| BASE-6 | pass | `03_spike.md`, notes, scripts and code comments are in English |
| BASE-8 | pass | no dependency added to the repo; throwaway crate `qa-artifacts/T1/broker/Cargo.toml` pins the plan's zbus 6.5.0 / tokio 1.54.1 (+ futures-util, serde) |
| BASE-9 | pass | broker socket 0600 on a path, EXTERNAL auth, peer uid logged (`logs/q3-rust/ibus.log` line 2); logs hold only synthetic test strings |
| BASE-11 | pass | no stash/checkout/reset/restore; no tracked file touched |
| BASE-12 | pass | writes outside the repo: session scratchpad temp files and cargo's registry cache (`cargo fetch`) only |
| BASE-13 | pass | deleted only this run's own `qa-artifacts/T1/h`, `r`, `logs/<run>` (recreated per run by `lib.sh: iso_env`) |
| BASE-14 | pass | foreground through `run-heavy.sh`; the one auto-backgrounded run was not polled (read zbus sources until its completion notice) |
| BASE-15 | pass | no `pkill`/`killall`; scripts stop only their own tagged children (see Deviations); live fcitx5 pid 6881 before and after |
| BASE-16 | pass | `## Reuse` table above |
| BASE-17 | pass | nothing installed; ibus-daemon missing → open item O2 instead |
| BASE-18 | pass | no Agent/Workflow call |
| BASE-19 | pass | this file was created before the first experiment; `## Progress` lines |
| BASE-21 | pass | logs contain no secret; only the synthetic typed strings (`xin chao`, …) |
| BASE-24 | pass | no `git add`/commit/reset; `git status` shows the files untracked |
| BASE-32 | pass | D2 (isolated only), D4/D8/D9/D12 answered in `03_spike.md` Q3–Q6; no decision changed, F2 correction reported |
| BASE-33 | pass | assumptions on the environment checked and stated: live shell env and live app platform read from `/proc`/`ps` (`03_spike.md` Q1, Q3); unverifiable ones are O1–O5 |
| BASE-34 | pass | two `BLOCKED-STEP` lines above with the next route taken |
| BASE-46 | pass | all quoted outputs come from the final scripts; reruns after script fixes replaced earlier logs |
| COST-1 | pass | `run-heavy.sh` for all shell/browser/cargo runs; one browser launch per app per run |
| COST-3 | pass | no agent-side sleep/pgrep polling; in-script waits use `gdbus wait` or bounded pauses (see Deviations) |
| COST-5 | pass | `lib.sh: cleanup` on EXIT in every script; final tag scan empty |
| COST-7 | pass | D-Bus data read with `gdbus`/`dbus-monitor`; browsers launched only because the browser itself is the subject |
| COST-8 | pass | scripts written whole with Write; reads and greps batched |
| COST-9 | pass | nothing left running: tag scan empty, background task `b51723oau` completed |
| COST-13 | pass | all scripts and probes under `$TEAM_WS/qa-artifacts/T1/`; nothing in `$TEAM_TOOLS` |
| COST-16 | pass | full outputs in `qa-artifacts/T1/logs/`; only trimmed lines read into context |
| AC-5 | pass | feasibility answered: hot apply reaches gnome-shell (0.5 s) and fcitx-module apps without restart — `03_spike.md` Q3, Q5, Q6 (isolated session only; live proof is O1) |
| SEC-29 | pass | `lib.sh: guard` aborts on live HOME / runtime dir / bus; live fcitx5 pid 6881 and `~/.config/ibus/bus/*` (mtime 2026-11-22) unchanged; no gsettings/im-config/systemctl --user/fcitx5-remote on the real HOME |

n-a: BASE-2 (no product contract implemented; plan facts that proved wrong are reported, not changed) · BASE-7 (no commit) · BASE-10, BASE-25, COST-2, COST-4, COST-10, COST-11, COST-18 (no repo tests or guards exist or ran) · BASE-20 (nothing removed) · BASE-22 (no product names added) · BASE-23, BASE-26, BASE-36, BASE-37, BASE-39, BASE-43, BASE-44, BASE-47 (no feature, rewrite, fix or schema in a spike) · BASE-27, BASE-30 (no shared database or app written) · BASE-28 (no third-party code changed) · BASE-29, BASE-40, BASE-41 (no signed-in browser, outward write or credential used; Chrome/VS Code ran with throwaway profiles) · BASE-31 (no container) · BASE-35 (no `user-rules.md`) · BASE-38 (no formatter run) · BASE-42 (no test settings changed) · BASE-45 (no criterion added) · COST-6, COST-19, COST-20 (no UI sweep or qc check set) · COST-12 (leader rule) · COST-14 (no CI/deploy wait) · COST-15, COST-17 (no goldens)
