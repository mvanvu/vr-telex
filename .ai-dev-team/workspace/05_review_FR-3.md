# Review FR-3 (code + security), final tree

Verdict: **APPROVED** (two minor findings, no blocker/major; SECURE for the security checklist)

Scope: `git -C /home/rainy/DEV/vr-talex-wt-FR3 diff` against base 62f5eca. Only fe-ibus changed (3 files). `git diff 62f5eca --stat -- crates/` lists only those 3 files, and `git diff --quiet 62f5eca -- crates/ime-core` is clean. session.rs, server.rs, socket.rs, ime-core and tests are identical to the base, and nothing is untracked apart from an ignored `tests/e2e/__pycache__/`. The pacing prototype is not in the tree. It exists only as `qa-artifacts/FR-3/pacing-prototype.patch`.

## Files read
| File | Status |
|---|---|
| crates/fe-ibus/Cargo.toml | read |
| crates/fe-ibus/src/address.rs | read (diff + `owned_dir`, `take_lock`, `prepare_socket` head) |
| crates/fe-ibus/src/lib.rs | read (diff + `Config::from_values/from_env`) |
| crates/vr-talex/src/main.rs (caller) | read `serve`, `watchdog`, `watchdog_period` (lines 170-290) |
| packaging/vr-talex.service (master) | read |
| install.sh `start_daemon`/`health_check`, packaging/org.fcitx.Fcitx5.service | read (activation and start paths) |

## Findings

[minor] crates/fe-ibus/src/lib.rs:164-168: the `NO_DISPLAY_WAIT` comment no longer matches the unit on master
Scenario: the comment says "one start every 8 s: below its start limit (10 in 60 s), so the retries never end". Master's unit now has `StartLimitIntervalSec=0` (so there is no start limit), plus `RestartSteps=4` and `RestartMaxDelaySec=15`. The cycle is 7 s plus a delay that grows 1 → ~2 → ~3.9 → ~7.6 → 15 s, so up to ~22 s per cycle. Behaviour is correct, but after the merge the comment explains the 7 s with a constraint that no longer exists. The only constraint left is `TimeoutStartSec=10`.
Fix: when merging, change the comment to "below the unit's `TimeoutStartSec=10`, so the start fails by our Err and not by a systemd timeout. The unit restarts it with its back-off (`RestartSec=1` … `RestartMaxDelaySec=15`)". Also drop the StartLimitBurst caveat from the FR-3 notes.

[minor] crates/fe-ibus/src/lib.rs:158: a user manager without any graphical session now restarts the daemon forever
Scenario: no graphical session (SSH-only or lingering user manager). A client asks for `org.fcitx.Fcitx5`, and D-Bus activation (`SystemdService=vr-talex.service`) starts the unit. fe-fcitx serves, fe-ibus fails after 7 s, and systemd restarts the daemon every 7 + 15 s for as long as the manager lives. Each cycle writes one static journal line and drops the fcitx clients. Before this change the daemon kept running headless. This is rare, and SEC-17 accepts "restart forever", so it is filed only for the record.
Fix (optional): none needed now. If it matters later, check `XDG_SESSION_TYPE`, or check whether `graphical-session.target` is active, before treating a missing display as "not ready yet".

No other defects found. These questions from the brief are answered with evidence:
- **Watchdog**: `serve` (main.rs:192-198) spawns the watchdog task before READY, so `WATCHDOG=1` keeps going from the main PID during the 7 s wait. systemd also arms `WatchdogSec` only once start-up is complete. Either way the wait cannot trip the watchdog.
- **TimeoutStartSec**: 7 s plus the time to exec and build the runtime leaves about 3 s of margin under 10 s. Even if the timeout won, systemd would kill and restart the daemon, which gives the same outcome.
- **READY**: fe-ibus keeps `Ready` until `without_display` returns and then drops it unused. `unready` therefore still holds fe-ibus and READY=1 is never sent. The test `under_systemd_..._fails_after_a_wait` checks `!watch.wait()`. fe-fcitx is spawned at the same time and owns its names during the wait. SIGTERM during the wait ends at once: the `Shutdown` event breaks the loop and `tasks.shutdown()` cancels the sleep.
- **Error text**: it is a static string with no environment values and no typed text (SEC-1).
- **Late GNOME environment**: the next start (after RestartSec=1, the first step) reads the user manager's environment again. On a login where the variables arrive late, GNOME Shell gets IBus about 8-9 s later: a visible delay, not a permanent failure. libibus watches the address file and reconnects when it appears. This remains unverified under a real user manager, as the notes say.
- **Lock (SEC-7)**: `open_lock` adds `O_NOFOLLOW`. A planted or dangling link at `ibus.lock` gives ELOOP, which maps to `PrepareError::Unsafe`, and nothing is created behind the link. The test proves this. The earlier `symlink_metadata` is_file/uid check stays in place, so a FIFO or another user's file is still refused. `rustix::fs::OFlags::NOFOLLOW` has the right value on each architecture. `cast_signed` is fine for MSRV 1.100. Cargo.lock is unchanged. Only a feature was added, with no new crate, so no dependency audit is needed.

## Rule check FR-3
| Rule | Result | Evidence |
|---|---|---|
| BASE-1 scope | pass | diff = fe-ibus Cargo.toml, address.rs, lib.rs only |
| BASE-3 contracts | pass | `run` doc updated; ime-core identical to base; main.rs semantics (`Err` → exit FAILURE → restart) unchanged |
| BASE-7/24 no commit | pass | `git status --short`: 3 modified, nothing staged |
| BASE-15 no pkill | pass | notes; no kill-by-name in diff |
| BASE-16 reuse | pass | O_NOFOLLOW from existing rustix dependency |
| BASE-19 notes + rule compliance | pass | 04_dev_FR-3.md has `## Rule compliance` with test/fmt/clippy output |
| Tests for changed behaviour | pass | `the_lock_is_never_opened_through_a_link`, `outside_systemd_...`, `under_systemd_...`; red-first stated |
| COST-13 scripts location | pass | throwaway scripts under qa-artifacts/FR-3 |
| SEC-1 no typed text in errors | pass | lib.rs static `"fe-ibus: no display in the environment"` |
| SEC-7 safe lock/socket creation | pass | address.rs `open_lock` O_NOFOLLOW + pre-open type/uid check; test |
| SEC-8/SEC-16 | pass | socket.rs/server.rs/session.rs identical to base, so caps and peer check are unchanged |
| SEC-17 crash recovery | pass | missing display now fails and restarts instead of silently dropping IBus; restarts forever under master unit |
| SEC-18 watchdog | pass | pings continue during the wait (main.rs:192-198, 272-279) |
| No pacing leftover | pass | crates/ diff limited to 3 fe-ibus files |
