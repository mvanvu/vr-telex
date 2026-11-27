# FR-13 Rename vr-talex -> vr-telex everywhere + legacy install migration
Worktree: /home/rainy/DEV/vr-telex-wt-FR13 (branch fr13-rename, from de15649). Nothing staged or committed (BASE-7/24).
Task diff for review: `git -C /home/rainy/DEV/vr-telex-wt-FR13 diff` + the untracked list below.

## Progress
- step 1: notes created; listed hits (`git grep -il talex`, 33 non-team files).
- step 2: Part A blanket rename (perl over tracked non-team files), mv of crate dir, 2 packaging files, stub; deleted tracked __pycache__; .gitignore += `__pycache__/`.
- step 3: vendored a frozen copy of the vr-talex installer from de15649 into tests/install/legacy/ as the migration fixture.
- step 4: Part B code (packaging/common.sh legacy section, install.sh migration + rollback-to-legacy, uninstall.sh legacy paths) + new scenarios in tests/install/run.sh.
- step 5: new scenarios run red/green (1st run: 1 check wrong in the test itself, fixed); full install suite: `uninstall_not_installed` caught a gsettings read creating ~/.config/glib-2.0 -> split `legacy_found` (files/unit only) from `legacy_source_listed`; added `legacy_source_only` scenario.
- step 6: cargo test (workspace), fmt + clippy guard, cargo build --offline, full install suite 37/37, README section.

## Files
Modified (tracked): .gitignore, Cargo.lock, Cargo.toml, README.md, crates/fe-fcitx/src/lib.rs, crates/fe-ibus/src/{address.rs,ibus.rs,lib.rs}, crates/fe-ibus/tests/{address.rs,common/mod.rs,protocol.rs}, crates/fe-xim/src/lib.rs, crates/ime-core/src/state.rs, crates/ime-core/tests/state_store.rs, install.sh, packaging/common.sh, packaging/org.fcitx.Fcitx5.desktop, packaging/org.fcitx.Fcitx5.service, packaging/xinputrc, tests/e2e/{README.md,install_scenario.sh,lib.sh,run.sh,stub_ime.py}, tests/install/run.sh, tests/install/stubs/fake-ime, uninstall.sh.

Moved (plain `mv`, leader stages as renames):
| old | new |
|---|---|
| crates/vr-talex/ (Cargo.toml, src/main.rs) | crates/vr-telex/ (content renamed) |
| packaging/vr-talex.service | packaging/vr-telex.service |
| packaging/90-vr-talex.conf | packaging/90-vr-telex.conf |
| tests/install/stubs/broken-vr-talex | tests/install/stubs/broken-vr-telex |

Deleted: tests/install/stubs/__pycache__/fake-imecpython-312.pyc (tracked build artifact; `__pycache__/` now in .gitignore).
New (untracked): tests/install/legacy/install.sh, tests/install/legacy/packaging/{common.sh,vr-talex.service,90-vr-talex.conf,xinputrc,org.fcitx.Fcitx5.desktop,org.fcitx.Fcitx5.service} — byte-exact `git show de15649:<path>` copies (the vr-talex installer, used by the tests to make a real legacy install).
crates/telex-core: not touched (`git status --short crates/telex-core` empty).

## Part A — renamed identifiers
| old | new | where |
|---|---|---|
| crate/package `vr-talex`, dir crates/vr-talex | `vr-telex`, crates/vr-telex | Cargo.toml members, Cargo.lock (only the `name =` line changed; `cargo metadata --locked --offline` ok) |
| binary `vr-talex`, `~/.local/bin/vr-talex` | `vr-telex`, `~/.local/bin/vr-telex` | install.sh, common.sh, unit, README |
| `vr-talex.service` | `vr-telex.service` | packaging, scripts, D-Bus service `SystemdService=` |
| `90-vr-talex.conf` | `90-vr-telex.conf` | environment.d |
| IBus engine name / source `('ibus', 'vr-talex')` | `('ibus', 'vr-telex')` | fe-ibus `ENGINE_NAME`, common.sh `VR_SOURCE`, tests, e2e |
| runtime dir `$XDG_RUNTIME_DIR/vr-talex` (ibus.lock, ibus socket) | `.../vr-telex` | fe-ibus address.rs `APP_DIR` |
| state dir `$XDG_STATE_HOME/vr-talex/mode` | `.../vr-telex/mode` | ime-core state.rs `APP_DIR` |
| backup `~/.local/share/vr-talex/backup` | `~/.local/share/vr-telex/backup` | common.sh |
| temp names `.vr-talex-tmp.*`, `.<name>.vr-talex.tmp`, kept copies `*.vr-talex-saved-*` | `vr-telex` forms | common.sh, address.rs |
| env vars `VR_TALEX_BIN`, `VR_TALEX_TIMEOUT`, `VR_TALEX_OS_RELEASE`, `VR_TALEX_TEST_DIR` | `VR_TELEX_*` | install.sh, common.sh, tests, e2e |
| log prefix `vr-talex:` | `vr-telex:` | main.rs, common.sh |
| test helpers `expect_no_vr_talex_left`, `no_vr_talex_alive`, stub `broken-vr-talex` | `..._telex_...`, `broken-vr-telex` | tests/install |
| README clone URL / `cd` | `https://github.com/mvanvu/vr-telex.git`, `cd vr-telex` | README.md |
No D-Bus *bus names* contained the name (org.fcitx.Fcitx5 / portal names are fcitx's). All 300 hits were the forms `vr-talex`, `vr_talex`, `VR_TALEX` (checked with `git grep -ohi '[A-Za-z0-9_.-]*talex[A-Za-z0-9_.-]*'`), so the replace could not touch `telex-core`/`Telex` words.

## Part B — migration design
Detection (`legacy_found`, common.sh): `~/.local/share/vr-talex` exists, or `~/.local/state/vr-talex/mode`, or the vr-talex unit/binary/env file *that is ours*, or the vr-talex unit enabled/active. Separately `legacy_source_listed`: `('ibus','vr-talex')` in sources/mru-sources (not read inside `legacy_found`, so a plain `uninstall` on a clean HOME still touches nothing).
Ownership (`legacy_is_ours`, SEC-24): a file at a vr-talex path is ours when it equals the copy the vr-talex installer recorded in `backup/installed/<rel>`; without the backup: unit/env equal the vr-talex template (current template with the name swapped back), binary contains the string `vr-talex`. Anything else is left in place with `warning: <path> is not the file vr-talex installed; left in place`.

install.sh order (main):
1. preflight, build; `legacy_found` -> `plan_migration`:
   - no vr-telex manifest and no vr-talex manifest -> die "installed without a backup; run ./uninstall.sh first" before any change (same rule as the existing no-backup case);
   - `legacy_snapshot`: `$DATA_HOME/.vr-telex-migrate.XXXXXX` (0700) holds copies/presence of every managed file (new names), the vr-talex bin/unit/env, the new mode file, both gsettings keys, both units' enabled/active state, and a copy of `~/.local/share/vr-telex` if it existed. Then MIGRATING=1, ROLLBACK=1.
   - no vr-telex manifest -> `legacy_copy_backup`: `cp -a` of the vr-talex backup into a temp dir, `legacy_rewrite_backup` (manifest `file`/`dir` paths of bin/unit/env/state dirs mapped exactly, input source in `gs` values, `installed.gs` values, `files/` and `installed/` entries renamed, marker `from-vr-talex`), then one `mv -T` into `~/.local/share/vr-telex/backup`. Unknown manifest entries -> refuse, nothing changed. The vr-talex backup stays until commit.
   - `elif legacy_source_listed` (only a dead entry left, nothing else of vr-talex): drop it before `backup_state`, so uninstall never brings it back.
2. RERUN path (manifest now exists); `install_files` (shared files xinputrc/autostart/D-Bus shadow equal the renamed installed copies, so they are updated as ours; the shadow now says `SystemdService=vr-telex.service`, bus reloaded).
3. `migrate_live`: `systemctl --user disable --now vr-talex.service` (never by name), rename `('ibus','vr-talex')` -> `('ibus','vr-telex')` in place in mru-sources then sources (dropped instead if vr-telex already listed), copy `~/.local/state/vr-talex/mode` to the new state dir (0700) when the new one does not exist.
4. hand-over, `select_source` (finds vr-telex first -> no change), `start_daemon`, `health_check` — unchanged (SEC-19: sources written before the daemon start; D33/D34: daemon restarted with vr-telex at the head of mru-sources, so the running shell keeps Vietnamese (Telex)).
5. ROLLBACK=0, `migrate_commit` -> `legacy_cleanup`: stop unit if still enabled, remove vr-talex unit/bin/env when ours, daemon-reload, IBus address files pointing at `$XDG_RUNTIME_DIR/vr-talex/`, that dir's `ibus.lock`/`ibus` entries + rmdir, legacy mode file + rmdir, and the vr-talex backup dir only when the vr-telex backup carries the `from-vr-talex` marker (then the marker is removed). Otherwise (both dirs existed before) the vr-talex backup is left untouched with `warning: kept the older backup in ~/.local/share/vr-talex ...`.

Rollback decision: **migration commits only after the health check; until then a failure returns to the vr-talex install, not to the pre-vr-talex setup.** `restore_legacy` (install.sh): input sources back from the snapshot first, the D-Bus shadow back (it names vr-talex again) and bus reload before the vr-telex unit stops, `disable --now vr-telex.service`, every snapshot path back (saved copy replaces / path that was absent loses what this run wrote), `~/.local/share/vr-telex` removed and the pre-run copy put back if there was one, daemon-reload, then the units' enabled/active state restored (vr-talex enabled + started). Output: "rolled back: vr-talex runs again as before" + a vr-talex recovery line. Reason: rolling back to the original setup would restore fcitx5, which is purged on the user's machine (D31), leaving no Vietnamese input method. Known residue: if `install_managed` moved a user-edited shared file aside during the failed run, the `.vr-telex-saved-*` copy stays next to the restored original (content is the user's, nothing lost).
Idempotent: after a migration nothing legacy is left, so the second run takes the normal re-run path (tested: snapshot and keyfile identical, no start/stop/enable/disable of vr-talex). Both-dirs case: every run reports the kept old backup and changes nothing.

uninstall.sh:
- vr-telex manifest missing, vr-talex manifest present (user runs the new uninstall on a vr-talex install): `legacy_copy_backup` + `legacy_rename_sources`, then the normal `restore_all`; `restore_all` now also stops `vr-talex.service` (it holds org.fcitx.Fcitx5, fcitx5 could not come back) and cleans IBus address files of either daemon.
- after a complete `restore_all`: `legacy_cleanup` (backup dropped only with the marker) and `remove_created_dirs` again (factored out of `restore_all`) so dirs freed by the legacy cleanup go too.
- no backup at all: `remove_without_backup` also accepts the vr-talex D-Bus shadow / xinputrc / autostart contents (`legacy_render_dbus_svc`, `legacy_template`), stops vr-talex; then `legacy_cleanup 0` (drops the dead vr-talex input source).

## Tests (tests/install/run.sh, sandbox: temp HOME, private bus, GSETTINGS_BACKEND=keyfile, stub systemctl)
Legacy install made by the real vr-talex installer (tests/install/legacy, frozen from de15649) with fake-ime installed as `~/.local/bin/vr-talex`; fake-ime takes the `vr-talex` role from that file name.
- `legacy_migrate`: running vr-talex + mode EN -> install: vr-talex stopped via systemctl, its pid gone, unit/bin/env/state/backup dirs gone, sources `[('xkb', 'us'), ('ibus', 'vr-telex')]`, mru head vr-telex at daemon start, mode EN carried, manifest has no vr-talex and maps paths, pre-vr-talex ~/.xinputrc in the backup, installed.gs renamed, no snapshot/marker left; 2nd install: snapshot + keyfile identical, no vr-talex output or state change; uninstall: files and keyfile byte-identical to the state before vr-talex, fcitx5 back, no `vr-t[ae]lex` string/name left.
- `legacy_rollback`: broken new daemon -> exits non-zero, every file and the keyfile identical to the vr-talex install, vr-talex unit active+enabled and owning org.fcitx.Fcitx5 with its address file; then a good install migrates and uninstall reaches the state before vr-talex.
- `legacy_both_dirs`: pre-existing vr-telex backup (saved sources changed to tell them apart): install warns, vr-talex backup byte-identical (find+sha256), rest moved; 2nd run no-op; uninstall restores from the vr-telex backup and keeps the old one with a warning.
- `legacy_foreign_file`: user-edited 90-vr-talex.conf kept through install, re-install and uninstall, warning names it.
- `foreign_legacy_name_only`: user's own `~/.local/bin/vr-talex` script without any vr-talex install: no migration, untouched through install/uninstall.
- `uninstall_legacy`: new uninstall on a vr-talex install: state before vr-talex restored exactly, fcitx5 back.
- `legacy_without_backup`: install refuses with no change, vr-talex still runs; uninstall removes its unit/bin/env/shadow/autostart/xinputrc and the source.
- `legacy_source_only`: dead `('ibus','vr-talex')` entry dropped before the backup; uninstall gives `[('xkb', 'us')]`.

## Commands and output (trimmed)
```
$ bash tests/install/run.sh            # full install suite, final code
PASS fresh_fcitx5 ... PASS reselect_keeps_user_edits   (29 existing)
PASS legacy_migrate
PASS legacy_rollback
PASS legacy_both_dirs
PASS legacy_foreign_file
PASS foreign_legacy_name_only
PASS uninstall_legacy
PASS legacy_without_backup
PASS legacy_source_only
--- 37 scenarios, 0 failed
```
Red/green: first run of the 7 new scenarios: 6 PASS, `legacy_migrate` FAIL on a test bug ("second install did not touch vr-talex" matched the read-only `is-enabled` probes) -> check narrowed to `^systemctl --user (disable|enable|stop|start|restart) .*vr-talex`. First full run: `uninstall_not_installed` FAIL (`+d 700 ./.config/glib-2.0/settings` — gsettings read in `legacy_found`) -> fixed as described in step 5. The rollback behaviour itself has no red run against the old code (the old code had no migration at all); `legacy_rollback` asserts the vr-talex unit is active again, which the pre-existing `restore_all` rollback would not do.
```
$ $TEAM_BIN/run-heavy.sh cargo test --workspace --locked --offline   (log: $TEAM_WS/qa-artifacts/FR-13/cargo-test.log)
test result: ok. ... every crate, 0 failed; exit 0
$ $TEAM_BIN/run-heavy.sh sh -c 'cargo fmt --check && cargo clippy --workspace --all-targets --locked --offline -- -D warnings'
    Checking vr-telex v0.1.0 (.../crates/vr-telex)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 11.59s
guard exit 0
$ cargo build --locked --offline   -> Finished; target/debug/vr-telex
$ cargo metadata --locked --offline -> LOCK-OK
$ bash -n install.sh uninstall.sh packaging/common.sh tests/install/run.sh tests/install/legacy/{install.sh,packaging/common.sh} tests/e2e/*.sh tests/install/stubs/{systemctl,broken-vr-telex}  -> all ok
$ grep -nE 'sudo|pkexec|/etc/|/usr/' install.sh uninstall.sh packaging/common.sh   (SEC-20)
install.sh:65: os_release=${VR_TELEX_OS_RELEASE:-/etc/os-release}   (read only, pre-existing)
packaging/common.sh:32: "do not run as root or with sudo" (message)
$ grep -nE 'curl|wget|\| *(ba)?sh' install.sh uninstall.sh packaging/common.sh   (SEC-24) -> none
```
shellcheck: not installed (brief). e2e: not run (needs a nested shell; qc decides) — tests/e2e only got the rename.

## Final `git grep -il talex` (outside .ai-dev-team)
```
README.md:8            # "Upgrading from vr-talex" section
install.sh:21          # migration + rollback-to-legacy (comments, messages)
packaging/common.sh:27 # LEGACY_* names, legacy section, restore_all stopping the legacy unit
tests/install/run.sh:100  # legacy scenarios
tests/install/stubs/fake-ime:4  # vr-talex role for the legacy fixture
uninstall.sh:5         # removal of a vr-talex install
```
plus the untracked fixture tests/install/legacy/** (frozen vr-talex installer). Every hit names the legacy install on purpose; nothing else names talex.

## Deviations
- "move ~/.local/share/vr-talex" is implemented as copy + rewrite, then deletion of the old backup only after the health check (needed for the rollback to vr-talex). Net effect after a successful run is a move.
- Ownership check for the binary without a backup record is weak (contains the string `vr-talex`); with the record (normal case) it is an exact compare.
- The legacy fixture adds ~900 lines of frozen shell under tests/install/legacy; chosen over hand-building a legacy state (would mirror the migration's own assumptions) and over `git show` at test time (fails in shallow clones).

## Out-of-scope / notes
- The threat model text (SEC-21/22) still names `~/.local/state/vr-talex/backup` and `90-vr-talex.conf`; .ai-dev-team was out of scope for this task — the leader may want to update it.
- I ran a no-op `python3 - <<EOF` (empty) once by mistake; it edited nothing. I also ran `python3 -m py_compile` on fake-ime, which created `tests/install/stubs/__pycache__/`; I deleted that directory (created by me, untracked, ignored).
- qa-artifacts: $TEAM_WS/qa-artifacts/FR-13/cargo-test.log; scratch scenario sources in the session scratchpad only.

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| file restore without delete-first | packaging/common.sh | reused `replace_with`, `same_entry`, `exists` |
| source list editing | common.sh `without_vr`, `list_items` | generalized to `without_source` (`without_vr` kept as wrapper) |
| dir cleanup after restore | `restore_all` tail | factored out as `remove_created_dirs`, called again by uninstall after legacy cleanup |
| legacy install for tests | tests/install stubs, git history | frozen de15649 installer under tests/install/legacy; existing stubs (systemctl, fcitx5, fake-ime) reused |
| sandbox checks | tests/install/run.sh helpers | reused `snap`, `same_snap`, `expect_installed`, `started_with_vr_head`, `addr_file_pid_is`; `no_vr_telex_alive` takes a role |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| AC-5 | pass | `legacy_migrate`: install over vr-talex without logout, daemon started with vr-telex first (`started_with_vr_head`), expect_installed |
| AC-6 | pass | `legacy_migrate` 2nd run snapshot/keyfile identical; uninstall byte-identical to pre-vr-talex; `uninstall_legacy`, `legacy_both_dirs` |
| D37 | pass | `git grep -il talex` above: only intentional legacy hits; repo URL in README |
| D11 | pass | backup kept and rewritten (`legacy_rewrite_backup`), only user-level files; `legacy_migrate` manifest checks |
| D33 | pass | install still restarts the daemon each run; `legacy_migrate` 2nd run restarts with vr-telex head (normal path) |
| D34 | pass | in-place rename keeps order: `legacy_renamed_sources` (common.sh), sources `[('xkb', 'us'), ('ibus', 'vr-telex')]`, mru head vr-telex before start |
| D31 | pass | rollback returns to vr-talex, not to fcitx5 (`restore_legacy`, `legacy_rollback`) |
| SEC-19 | pass | sources renamed in `migrate_live` before `start_daemon`; `legacy_rollback` keyfile byte-identical after a dying daemon |
| SEC-20 | pass | grep output above; no sudo/pkexec; writes only under HOME/XDG dirs inside HOME |
| SEC-21 | pass | backup copied before any change, original pre-vr-talex values restored on uninstall (`legacy_migrate`, `uninstall_legacy`) |
| SEC-22 | pass | idempotent re-run (`legacy_migrate`, `legacy_both_dirs`, `legacy_foreign_file` 2nd-run snapshots) |
| SEC-23 | pass | `rm -rf` targets: `${DATA_HOME:?}/vr-telex[/backup]`, `${DATA_HOME:?}/vr-talex/backup`, `${tmp:?}`, `${MIG_SNAP:?}` (grep above); units stopped via `systemctl --user` only |
| SEC-24 | pass | `legacy_is_ours` before every removal; `legacy_foreign_file`, `foreign_legacy_name_only`; no curl/wget (grep above) |
| SEC-1/SEC-2 | pass | no key data logged; Rust changes are string renames only |
| SEC-27 | pass | `#![forbid(unsafe_code)]` untouched in crates (rename only); clippy clean |
| BASE-1 | pass | diff = rename + installer/tests/README; crates/telex-core untouched |
| BASE-2 | pass | no API contract change; install/uninstall CLI unchanged |
| BASE-3 | pass | new scenarios run before final code (red runs listed above) |
| BASE-4 | pass | outputs above |
| BASE-5 | pass | cargo test and guard through run-heavy.sh; install suite run directly as the brief lists it; nothing left running |
| BASE-6 | pass | English comments, no bug history |
| BASE-9 | pass | manifest rewrite refuses unknown entries; symlinked backup dirs refused (`legacy_copy_backup`) |
| BASE-10 | pass | related: install suite + workspace cargo test (allowed: crate rename) + guard |
| BASE-11 | pass | worked only in the worktree; no checkout/restore/stash/reset |
| BASE-13 | pass | only deleted the __pycache__ I created; tracked .pyc removal is listed for the leader |
| BASE-14 | pass | cargo test as background task; no polling |
| BASE-15 | pass | no processes stopped by name; sandbox stubs cleaned by the suite |
| BASE-16 | pass | Reuse table |
| BASE-17 | pass | nothing installed |
| BASE-18 | pass | no sub-agents |
| BASE-19 | pass | Progress section |
| BASE-20 | pass | every `talex` reference searched with `git grep -ohi` incl. env-var forms and helper names |
| BASE-22 | pass | new names follow neighbours (`LEGACY_*` beside `*_DST`, `t_legacy_*` scenarios) |
| BASE-23 | pass | both entry paths tested: install over vr-talex and uninstall on vr-talex (+ no-backup path) |
| BASE-24 | pass | no git add/rm/mv; plain `mv` |
| BASE-25 | pass | guard output above |
| BASE-32 | pass | D11, D31, D33, D34, D37 kept (rows above) |
| BASE-38 | pass | `cargo fmt --check` only (no formatter writes) |
| BASE-48 | pass | install still never claims the source is selected; migration messages say what was done |
| COST-1 | pass | heavy commands via run-heavy.sh |
| COST-3 | pass | no sleep loops |
| COST-4 | pass | full cargo suite once (shared infrastructure, allowed by brief) |
| COST-8 | pass | batched edits; one accidental empty `python3 -` heredoc edited nothing (noted) |
| COST-9 | pass | nothing left running |
| COST-10 | pass | related set = tests/install/run.sh (only suite naming install.sh/uninstall.sh/common.sh) + cargo workspace for renamed crates |
| COST-13 | pass | artifacts under $TEAM_WS/qa-artifacts/FR-13 |
| COST-16 | pass | cargo test output to log file, summary only in context |

n-a: BASE-7 (no commit) · BASE-8 (no dependency change) · BASE-12, BASE-40 (nothing outside this repo) · BASE-21 (no secrets in output) · BASE-26, BASE-28, BASE-36, BASE-39, BASE-43, BASE-44, BASE-47 (no rewrite / third-party code / app scope / schema / access rule / fake adapter / computed value) · BASE-27, BASE-30, BASE-31, BASE-29, BASE-41 (no shared DB, browser, container or credentials) · BASE-33, BASE-46 (no live system relied on; real-machine run is qc's) · BASE-34 (nothing blocked) · BASE-35 (no USER rules for this area) · BASE-37 (not a runtime-defect fix) · BASE-42 (no test-runner settings changed) · BASE-45 (AC text unchanged) · COST-2, COST-5, COST-6, COST-7, COST-11, COST-12, COST-14, COST-15, COST-17..COST-20 (no UI/browser/e2e/golden/CI work) · D35 (n/a per brief)
- fix round 1 started: 4 findings from 05_review_FR-13.md

## Fix round 1
Findings from $TEAM_WS/05_review_FR-13.md. No Rust changed (guard not rerun). Red runs: $TEAM_WS/qa-artifacts/FR-13/pre/ is a copy of the fixed scripts with only the four fixes reverted (`diff` showed exactly those hunks); logs in pre/out/.

1. [major] Weak ownership test for an unrecorded `~/.local/bin/vr-talex`: **fixed**. Choice: an unrecorded binary is never deleted. `legacy_is_ours` (packaging/common.sh, legacy section) no longer has a content rule for the binary. Only an exact match with vr-talex's `backup/installed/` copy makes it ours. `legacy_retire_file` leaves an unrecorded binary with `warning: <path> cannot be told apart from a file of yours (vr-talex left no record of it); left in place, remove it by hand if it is the old vr-talex binary`. An unrecorded binary also no longer counts as a sign of an install (`legacy_found`), so uninstall.sh's no-backup branch is not entered for it alone. The unit and env file keep their exact-template rule (full-file compare, not a text match).
   Tests: `foreign_legacy_name_only` now uses the reviewer's wrapper (`exec "$HOME/src/vr-talex/target/release/vr-talex" "$@"`) and runs uninstall before install too. `legacy_without_backup` now expects the binary left in place and named in the warning.
   Red on pre: `uninstall says nothing is installed` FAIL, `uninstall left the user's wrapper untouched` FAIL, `the user's ~/.local/bin/vr-talex is untouched` FAIL; legacy_without_backup `unrecorded ... left in place` FAIL. Green: both PASS.
   Probe `weak_bin_probe.sh` now prints `legacy_is_ours: no`. It still prints `legacy_found: YES`, but that comes from the probe running against the real systemd user manager, where this machine's real `vr-talex.service` is enabled. The probe does not sandbox systemctl, so this is not the wrapper. In the sandbox, uninstall with only the wrapper says "not installed".
2. [minor] Snapshot deleted after a failed restore_legacy: **fixed**. install.sh `KEEP_SNAP=1` when `restore_legacy` fails. The warning prints the path (`...; the saved vr-talex files and settings are kept in <MIG_SNAP>`), and on_exit removes the snapshot only when `KEEP_SNAP=0`.
   Test: new `legacy_rollback_restore_fails` (a cp wrapper that fails copies out of the snapshot, plus a broken daemon). Red: `the snapshot is still there, with its saved files` FAIL. Green: PASS.
3. [minor] Bare `rm -rf` in legacy_cleanup: **fixed**. Removing the old backup is now `if rm -rf ...; then rmdir ...; else warn "could not remove the older backup ...; it is no longer used, remove it by hand"; fi`. The other `rm -f` calls in legacy_cleanup (address files, runtime entries, mode file) now `|| warn` too, so the function never fails, as its comment says.
   Test: new `legacy_backup_rm_fails` (an rm wrapper that fails on `*/vr-talex/backup`). Red: `install exits 0` FAIL (exit 1 after a healthy start) and the warning FAIL. Green: PASS.
4. [minor] Rollback wrote keys that were at their default: **fixed**. `restore_legacy` skips a key that already holds its saved value, and otherwise uses `gs_put`, which resets a key whose saved value equals the schema default.
   Test: new `legacy_rollback_default_key` (user reset mru-sources, then a broken daemon). Red: `mru-sources not set in the keyfile` FAIL and `keyfile byte-identical` FAIL. Green: PASS.

Commands (final code):
```
$ bash -n install.sh uninstall.sh packaging/common.sh tests/install/run.sh   -> all ok
$ bash tests/install/run.sh
... PASS (all 37 earlier scenarios)
PASS legacy_rollback_restore_fails
PASS legacy_backup_rm_fails
PASS legacy_rollback_default_key
--- 40 scenarios, 0 failed
```
Rule rows touched: SEC-21/SEC-24 pass (finding 1 tests), SEC-19 pass (`legacy_rollback_default_key` keyfile byte-identical), SEC-23 pass (no bare `rm -rf` whose failure aborts after commit), BASE-3 pass (red runs above), COST-8 pass (perl/Edit only). Nothing left running; nothing staged.
- quick pass: dropped 'Review FR-13 minor N:' prefixes from 3 test comments (BASE-6); bash -n tests/install/run.sh ok
