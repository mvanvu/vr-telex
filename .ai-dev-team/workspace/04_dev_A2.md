# A2 Packaged per-user setup: `vr-telex-setup` / `vr-telex-setup --remove`
Tools available: Bash, Read, Edit, Write, Skill, ToolSearch, SubagentHandback (no sub-agents used).

## Progress
- read brief, A1/A3 notes, install.sh, uninstall.sh, packaging/common.sh, tests/install/run.sh + stubs/systemctl, plan Fixed paths, spec AC-2/AC-3
- tests first: stub systemctl finds units in VR_TELEX_SYSTEM_UNIT_DIR (user dir wins); 11 new scenarios in tests/install/run.sh (make_pkg stand-in package); red: all 3 sampled FAIL `install: cannot stat '.../packaging/vr-telex-setup'`
- code: install/uninstall logic moved into packaging/common.sh (install_main / uninstall_main, use_checkout / use_package, share_file, check_package, retire_checkout_files); install.sh / uninstall.sh are thin wrappers; new packaging/vr-telex-setup; migrate_live reads legacy_was_current before stopping vr-talex (A1 review minor)
- green: 11 new scenarios PASS; mutation copy (qa-artifacts/A2/mut) fails them
- shellcheck counts compared with HEAD (no new warning)
- full tests/install/run.sh once (55 scenarios, 0 failed); strict deb test PASS; guard rc 0; capabilities.md line added

# A2 task notes
- Files changed: install.sh, uninstall.sh (now thin wrappers), packaging/common.sh (install + uninstall logic moved in), packaging/vr-telex-setup (new, mode 755), tests/install/run.sh (11 scenarios + helpers), tests/install/stubs/systemctl (system unit dir lookup), .ai-dev-team/capabilities.md (one line)
- Tests added (tests/install/run.sh): setup_fresh, setup_root_refused, setup_usage, setup_no_package, setup_broken_daemon, setup_from_source, install_after_setup, setup_unit_override, setup_remove_without_backup, setup_legacy_migrate, setup_legacy_keep_selection; helpers make_pkg, run_setup, pkg_sum, expect_setup_installed
- A3 follow-up: none. The setup needs only the five listed shared files. The checkout's unit, needed to recognise a from-source unit file on `--remove` without a backup and for the vr-talex template match, is derived from the packaged unit by `share_file`: the two differ only in ExecStart, and tests/deb guards that.

## Design
- **Reuse (BASE-16):** everything install.sh and uninstall.sh did now lives in packaging/common.sh (already shipped as /usr/share/vr-telex/common.sh) as `install_main` / `uninstall_main` plus `on_exit`. install.sh = `use_checkout "$REPO"; trap on_exit EXIT; install_main`; uninstall.sh = `use_checkout "$REPO"; uninstall_main`; vr-telex-setup = `use_package "$SHARE"`, then `install_main` or `uninstall_main`. The code was moved by line range, not copied. Only these parts differ by kind:
  - `use_checkout` / `use_package`: KIND, SHARE (packaging/ or /usr/share/vr-telex), DAEMON_BIN (~/.local/bin/vr-telex or /usr/bin/vr-telex), SYSTEM_UNIT_DIR, and the command names in messages (`./install.sh` / `vr-telex-setup`, `$REPO/uninstall.sh` / `vr-telex-setup --remove`).
  - Build step: checkout → `build_binary` (cargo, unchanged). Package → `check_package`: the binary and the packaged unit must be present, and a unit in ~/.config/systemd/user that vr-telex did not write (it would override the packaged one) is refused before any change. No cargo and no network (SEC-24).
  - `install_files`: checkout installs the binary and its own unit as before. Package calls `retire_checkout_files` and always runs `systemctl --user daemon-reload`.
  - `render_dbus_svc` takes the binary path (DAEMON_BIN), so in package mode the D-Bus activation shadow execs `"/usr/bin/vr-telex"`. A path holding `"` or `\` is refused, as HOME was before, and VR_TELEX_BIN must be absolute.
  - Migration (AC-2) runs the same code: `plan_migration` / `migrate_live` / `migrate_commit`, `legacy_was_current` + MIG_KEEP_SELECTION. Proven by setup_legacy_migrate and setup_legacy_keep_selection.
- **How the packaged unit is enabled:** first `systemctl --user daemon-reload`, because the user manager may not have loaded a unit the package just added. Then the unchanged `start_daemon` runs `systemctl --user enable --now vr-telex.service`. For a unit in /usr/lib/systemd/user this writes only the per-user link `~/.config/systemd/user/graphical-session.target.wants/vr-telex.service -> /usr/lib/systemd/user/vr-telex.service`; no unit file is copied. `--remove` → `restore_all` runs `systemctl --user disable --now`, which removes the link, and `remove_created_dirs` removes the dirs the backup recorded as created. Rejected: `systemctl --global enable` (needs root, applies to every user, against the per-user opt-in of AC-3) and a copy of the unit in ~/.config (it would hide later package upgrades of the unit).
- **One backup for both kinds:** MANAGED_FILES is unchanged, so the manifest is the same whichever kind ran first.
  - Checkout → package (`retire_checkout_files`): the recorded ~/.local/bin/vr-telex and ~/.config/systemd/user/vr-telex.service are removed (a user-edited one is moved aside, as install_managed does). The unit is disabled first so its link is made again for the packaged unit, and the records are dropped. The first backup stays, so `--remove` still returns to the state before the first install (setup_from_source).
  - Package → checkout: install.sh writes its own files as a rerun, and uninstall.sh restores the original state (install_after_setup).
- **Root refused** in vr-telex-setup before any shared file is sourced, because VR_TELEX_SHARE could point anywhere; `require_user` refuses again. setup_root_refused proves a planted common.sh never runs.
- `uninstall_main` without a backup now also acts when the unit is enabled or active, because the packaged setup leaves no binary or unit file in HOME.
- A1 review minor: `migrate_live` now reads `legacy_was_current` before `legacy_stop_unit`. The sandbox cannot show the difference (the stub shell does not drop a source when its engine goes), so there is no red test; all 4 A1 migration scenarios stay green.
- Test seams: VR_TELEX_SHARE, VR_TELEX_BIN, VR_TELEX_SYSTEM_UNIT_DIR (the stub systemctl reads it too), VR_TELEX_TIMEOUT, VR_TELEX_OS_RELEASE.

## Commands run (trimmed)
```
# red (tests written first, before packaging/vr-telex-setup existed)
$ VR_TELEX_TEST_DIR=qa-artifacts/A2/red bash tests/install/run.sh setup_fresh setup_root_refused setup_legacy_keep_selection
FAIL setup_fresh (exit 1)  install: cannot stat '/home/rainy/DEV/vr-telex/packaging/vr-telex-setup': No such file or directory
FAIL setup_root_refused (exit 1) ... FAIL setup_legacy_keep_selection (exit 1)
--- 3 scenarios, 3 failed
# green, new scenarios
$ bash tests/install/run.sh setup_fresh ... setup_legacy_keep_selection
PASS x11  --- 11 scenarios, 0 failed
  ok checks: fresh 39, legacy_migrate 42, from_source 28, install_after_setup 25, keep_selection 19,
  broken 10, remove_without_backup 9, root 8, usage 6, no_package 6 (incl. "default binary is /usr/bin/vr-telex"), unit_override 5
# mutation copy qa-artifacts/A2/mut (repo files never mutated)
root check removed           -> FAIL vr-telex-setup as root reads no shared file first (x2)
retire_checkout_files no-op  -> FAIL enabled through the packaged unit / no unit file of its own in ~/.config/systemd/user /
                                FAIL nothing in ~/.local/bin / the daemon is the packaged binary
package mode on the checkout branch -> setup_fresh: 22 FAIL
# full, once
$ $TEAM_BIN/run-heavy.sh bash tests/install/run.sh        (qa-artifacts/A2/full.log)
PASS fresh_fcitx5 ... PASS legacy_newer_mode, PASS setup_fresh ... PASS setup_legacy_keep_selection
--- 55 scenarios, 0 failed            rc=0
$ VR_TELEX_DEB_STRICT=1 $TEAM_BIN/run-heavy.sh bash tests/deb/run.sh   (qa-artifacts/A2/deb.log)
building: cargo deb -p vr-telex (repo sources)
ok    usr/bin/vr-telex-setup matches packaging/vr-telex-setup
... 62 ok
PASS                                   rc=0
$ shellcheck (codes per file, HEAD -> now)
install.sh          SC1091x1 SC2015x2 SC2034x1 SC2174x1 -> SC1091x1   (the rest moved into common.sh)
uninstall.sh        SC1091x1 -> SC1091x1
packaging/common.sh SC1003x1 SC2015x2 SC2034x3 -> SC1003x1 SC2015x4 SC2034x1 SC2174x1
  shell scripts total 12 -> 10 (vr-telex-setup: SC1091x1)
tests/install/run.sh SC2016 8->16, SC2088 9->10 (same style as the existing checks: sh -c '...$1', "~/..." labels); others equal
tests/install/stubs/systemctl 0 -> 0
$ cargo fmt --check && cargo clippy --workspace --all-targets --locked -- -D warnings
Finished `dev` profile ...   rc=0
```
Nothing left running: the background run finished (rc 0), the harness stops every scenario's stubs, and the sandbox dirs were removed (logs kept in qa-artifacts/A2).

## Deviations
- The plan allowed extra install/uninstall logic files under /usr/share/vr-telex. They were not needed: the logic lives in common.sh, so the Cargo assets stay as A3 wrote them.
- SEC-20 verify line (grep for /usr/ in the scripts): common.sh now names /usr/bin/vr-telex, /usr/share/vr-telex and /usr/lib/systemd/user as read-only defaults of `use_package`. Nothing is written outside HOME.
- Process note: a bulk perl edit of tests/install/stubs/systemctl went wrong early on (before any other change to that file). I put back the committed content by writing the HEAD blob over it (`git show HEAD:<file>` redirected into the file), then made the edits with the Edit tool. Only my own change was discarded. Repo-wide, git was used read-only.

## Out-of-scope issues noticed
- none

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| install / uninstall / migration logic for the package | install.sh, uninstall.sh, packaging/common.sh | moved into common.sh and shared by both kinds (no copy) |
| packaged unit + shared files | A3 notes, crates/vr-telex/Cargo.toml assets, packaging/deb/vr-telex.service | used as shipped; the checkout unit is derived from it |
| sandbox harness | capabilities.md (T8 harness) | extended: system unit dir in the stub systemctl, stand-in package |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| AC-3 | pass | setup_fresh (packaged binary + unit, nothing in ~/.local/bin or ~/.config/systemd/user, no cargo call, --remove restores the snapshot), setup_root_refused; install.sh/uninstall.sh: the 44 earlier scenarios are green |
| AC-2 | pass | setup_legacy_migrate, setup_legacy_keep_selection (same plan_migration / migrate_live / migrate_commit path, selection kept) + 9 legacy scenarios green |
| SEC-19 | pass | setup_broken_daemon: rollback, keyfile byte-identical, recovery line names vr-telex-setup --remove |
| SEC-20 | pass | root refused before sourcing (setup_root_refused); writes only under HOME; systemctl --user only |
| SEC-21 | pass | setup_fresh / setup_from_source / setup_legacy_migrate: snapshot after --remove = snapshot before |
| SEC-22 | pass | second setup changes no file (setup_fresh, setup_legacy_migrate) |
| SEC-23 | pass | set -euo pipefail, quoted variables, no pkill; shellcheck shows no new warning |
| SEC-24 | pass | package mode never calls cargo (the stub cargo logs; "never ran cargo" check); no curl/wget |
| BASE-1 | pass | diff limited to install.sh, uninstall.sh, packaging/common.sh, packaging/vr-telex-setup, tests/install/**, one capabilities.md line |
| BASE-2 | pass | plan Fixed paths are the defaults; A3 assets untouched |
| BASE-3 | pass | red run before the code; mutation copy |
| BASE-4 | pass | trimmed output above; logs qa-artifacts/A2/{full,deb}.log |
| BASE-5 | pass | heavy runs through run-heavy.sh; nothing left running |
| BASE-6 | pass | English, comments explain why |
| BASE-9 | pass | root refusal, absolute VR_TELEX_BIN, quote/backslash refused, no secrets |
| BASE-10 | pass | only tests/install/run.sh, tests/deb/run.sh (as asked) and the guard |
| BASE-11 | pass | no git add/rm/mv; see the process note under Deviations (my own broken edit of the stub undone from HEAD) |
| BASE-14 | pass | full run in the background, turn ended, no polling |
| BASE-15 | pass | only my own background task; no pkill |
| BASE-16 | pass | Reuse table; logic moved, not copied |
| BASE-17 | pass | only the pre-installed cargo-deb and shellcheck |
| BASE-18 | pass | no agents |
| BASE-19 | pass | notes created first, progress lines |
| BASE-22 | pass | VR_TELEX_* seam names, t_setup_* scenario names |
| BASE-23 | pass | every entry path tested: setup / --remove, the install.sh / uninstall.sh suites, switching both ways |
| BASE-24 | pass | nothing staged or committed |
| BASE-25 | pass | guard rc 0 |
| BASE-38 | pass | shellcheck only on my files; cargo fmt only with --check |
| BASE-46 | pass | full run, deb test and guard ran after the last code change |
| COST-1 | pass | run-heavy for the full suite and the deb build |
| COST-3 | pass | no sleep or polling |
| COST-8 | pass | Edit tool and perl -pi; no python heredoc edits |
| COST-9 | pass | nothing left running |
| COST-10 | pass | related set = tests/install/run.sh (the only test naming install.sh / uninstall.sh / common.sh) + tests/deb (names vr-telex-setup) |
| COST-13 | pass | throwaway files in qa-artifacts/A2 and the scratchpad |
| COST-16 | pass | full logs in files, trimmed output here |

n-a: BASE-7 (no commit) · BASE-8 (no dependency) · BASE-12, BASE-29, BASE-40, BASE-41 (no outside system) · BASE-13 (deleted only my sandbox dirs) · BASE-20 (moved functions keep their names except main -> install_main / uninstall_main, which only the wrappers call) · BASE-21 (no secrets) · BASE-26..28, BASE-30, BASE-31, BASE-39, BASE-43, BASE-44, BASE-47 (no rewrite of others' code, schema, containers, shared data, fakes of outside systems or computed values) · BASE-32 (decisions kept) · BASE-33, BASE-48 (no claim about the real machine; nothing touched outside the sandbox) · BASE-34 (no blocked source) · BASE-35, BASE-36, BASE-37, BASE-42, BASE-45 (no user-rules lines, scope change, runtime defect, test settings or spec edit) · COST-2, COST-4..7, COST-11, COST-12, COST-14, COST-15, COST-17..20 (no browser, e2e, goldens or CI)

DONE (round 0)

## Fix round 1
Progress: read 05_review_A2.md → tests first (red) → fixes → 9 related scenarios green → mutation mut2 → shellcheck → full run (background) → strict deb + guard pending at the time of writing (results below once run).

Files changed this round: packaging/common.sh (check_package, retire_checkout_files), packaging/vr-telex-setup (shebang, EUID check), tests/install/run.sh (t_setup_root_refused rewritten, t_setup_unit_override extended, new t_setup_from_source_edited and t_setup_legacy_then_override, helpers plant_user_unit / expect_override_refused).

| # | Finding | Reply | Red evidence | Fix | Green |
|---|---|---|---|---|---|
| 1 | override check only with a manifest | fixed | qa-artifacts/A2/fix1-red2: `FAIL no backup: names the overriding unit` (old code gave the "installed without a backup; run vr-telex-setup --remove first" loop) | check_package: with no installed record, refuse `"$UNIT_DST would replace the packaged unit and was not written by vr-telex; move it away..."` before any change, unless there is no manifest and the file equals the checkout unit (`share_file vr-telex.service`), which still gets the uninstall advice (and --remove removes it via remove_if_ours). Scenario covers no backup, with a backup, and the from-source-without-backup case | PASS setup_unit_override |
| 2 | moved-aside branch untested | fixed (test) | code was right, so red on mutation copy qa-artifacts/A2/mut2 (`keep_user_copy` → `rm -f`): `FAIL edited unit kept aside with the edit`, `FAIL edited binary kept aside with the edit`, `FAIL warning names the kept unit`, `FAIL both kept copies still there` | new t_setup_from_source_edited: install.sh, edit unit and binary, setup → saved copies hold the edits, no user unit/binary left, enabled through the packaged unit, packaged binary runs; --remove → snapshot equals pre-install except the kept copies and the dirs holding them | PASS |
| 3 | stale records after a package-mode vr-talex move | fixed | fix1-red: setup_legacy_then_override `FAIL after the move: setup exits 1`, `... nothing changed`, `FAIL the user's unit is where it was` (unit was moved aside) | retire_checkout_files drops the installed record when its file is absent | PASS setup_legacy_then_override |
| 4 | root check depends on PATH | fixed | fix1-red: `FAIL the root check reads bash's EUID`, `FAIL the interpreter is /bin/bash, not looked up in PATH`, `FAIL ... as root (EUID 0) reads no shared file first` (x2) | `#!/bin/bash`, `[ "$EUID" -eq 0 ]` before sourcing. Test: no user namespaces here (`unshare -r` → Operation not permitted), so the scenario runs a copy with `$EUID` replaced by 0 (the copy must differ, proving the check reads EUID) against a planted common.sh; the id-stub path still proves require_user refuses | PASS setup_root_refused |

Commands (trimmed):
```
$ bash tests/install/run.sh setup_root_refused setup_unit_override setup_from_source_edited setup_legacy_then_override   # before the fix
FAIL setup_root_refused / FAIL setup_unit_override / PASS setup_from_source_edited / FAIL setup_legacy_then_override
$ bash tests/install/run.sh setup_root_refused setup_unit_override setup_from_source_edited setup_legacy_then_override setup_from_source setup_legacy_migrate setup_fresh install_after_setup setup_remove_without_backup
--- 9 scenarios, 0 failed
$ bash qa-artifacts/A2/mut2/tests/install/run.sh setup_from_source_edited
--- 1 scenarios, 1 failed  (4 FAIL lines above)
$ shellcheck: common.sh SC1003x1 SC2015x4 SC2034x1 SC2174x1 (unchanged), vr-telex-setup SC1091x1 (unchanged), run.sh SC2016 16->21 (same sh -c '...$1' style), others unchanged
```
Not changed: `--remove` without a backup still disables a unit named vr-telex.service and removes ~/.local/bin/vr-telex unconditionally (pre-existing uninstall.sh behaviour, outside the findings); with finding 1 the setup no longer sends the user there for a foreign unit.

Final runs (after the last change):
```
$ $TEAM_BIN/run-heavy.sh bash tests/install/run.sh          (qa-artifacts/A2/fix1-full.log)
--- 57 scenarios, 0 failed     rc=0
$ VR_TELEX_DEB_STRICT=1 $TEAM_BIN/run-heavy.sh bash tests/deb/run.sh   (qa-artifacts/A2/fix1-deb.log)
62 ok ... PASS                  rc=0
$ $TEAM_BIN/run-heavy.sh sh -c 'cargo fmt --check && cargo clippy --workspace --all-targets --locked -- -D warnings'
Finished `dev` profile ...      rc=0
```
Rule rows touched this round: BASE-3 pass (red above), BASE-9 / SEC-20 pass (EUID, /bin/bash), BASE-23 pass (no-backup and backup paths of the override), BASE-25 pass (guard rc 0), BASE-46 pass (full run, deb and guard after the last change). Nothing left running; sandbox dirs removed, logs kept.

DONE
