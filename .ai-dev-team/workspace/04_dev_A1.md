# A1 fix round 1 — AC-2 migration: keep selection, prove position / runtime cleanup / newer mode
Tools available: Bash, Read, Edit, Write, Skill, SubagentHandback (no sub-agents used).

## Progress
- read review 05_review_A1.md, install.sh (select/reselect, migration), packaging/common.sh legacy section, uninstall.sh, tests/install/run.sh legacy scenarios, stubs/fake-ime
- wrote 4 scenarios in tests/install/run.sh (legacy_source_order, legacy_runtime_cleanup, uninstall_legacy_runtime_cleanup, legacy_newer_mode)
- red: legacy_source_order FAIL (mru head moved to vr-telex, 'put ... first again'); other 3 PASS on unmutated code -> mutation check next; fix: legacy_was_current (common.sh) + MIG_KEEP_SELECTION (install.sh)
- mutation red (copy in qa-artifacts/A1/mut, address-file rm + lock/socket rm removed, newer-mode guard removed): 3/3 new scenarios FAIL
- green: 5 targeted scenarios PASS; full tests/install/run.sh once (44 scenarios, 0 failed); shellcheck compared with HEAD; guard fmt + clippy clean

# A1 fix round 1 (task notes)
- Files changed: install.sh, packaging/common.sh, tests/install/run.sh (uninstall.sh unchanged)
- Tests added (tests/install/run.sh): `legacy_source_order`, `legacy_runtime_cleanup`, `uninstall_legacy_runtime_cleanup`, `legacy_newer_mode` (helpers `plant_legacy_runtime`, `expect_legacy_runtime_cleaned`)
- Deviations: none from the spec. The reviewer's suggestion "uninstall then restores the keyfile byte for byte" does not apply to `legacy_source_order`: the user reordered the lists after the vr-talex install, so uninstall keeps the user's lists minus vr-telex by design (gs_restore); the test asserts that instead (`[('xkb','us'),('xkb','fr')]` for both keys).

## Findings
| # | Finding | Red evidence | Fix | Green |
|---|---|---|---|---|
| 1 | selection not kept during migration | `legacy_source_order` on unchanged code: `FAIL mru-sources: English still current, vr-telex at its old place`, `FAIL does not claim to have put vr-telex first` (install printed "put the Vietnamese (Telex) input source first again") | packaging/common.sh `legacy_was_current` (mru head is vr-talex/vr-telex, or mru empty and sources head is) read in `migrate_live` before the rename; when the renamed source is listed and was not current, `MIG_KEEP_SELECTION=1` and `main` skips `select_source` (install.sh). When vr-talex was current the old path (reselect, D33/D34) runs unchanged; when no vr-telex entry is listed after the rename, `select_source` adds it as on a fresh install | PASS |
| 2 | "same position" unproven | same scenario: sources `[('ibus','vr-talex'), us, fr]`, vr-talex not current -> asserts `[('ibus','vr-telex'), us, fr]` (index 0 kept). Passed already on old code for the sources key (rename was correct; gap was the test) | test only | PASS |
| 3 | runtime dir / address-file cleanup unexercised | code was correct, so red shown by mutation: copy of the tree in `$TEAM_WS/qa-artifacts/A1/mut/` with the address-file `rm` and the `ibus.lock`/`ibus` `rm` removed in common.sh -> `legacy_runtime_cleanup` FAIL (stale address file, ibus.lock, ibus socket), `uninstall_legacy_runtime_cleanup` FAIL (ibus.lock, ibus socket, emptied dir). Note: on the uninstall path `restore_all` (common.sh:451-461) also removes the stale address file, so that check passes there even with the legacy_cleanup copy mutated | test only (install path keeps a foreign file and the dir; uninstall path has no foreign file and asserts the dir is removed; both assert another daemon's address file is kept) | PASS |
| 4 | newer vr-telex mode overwritten unproven | mutation: same copy with `&& ! exists "$DAEMON_STATE_DIR/mode"` removed in install.sh -> `legacy_newer_mode` `FAIL the newer vr-telex mode (VI) is kept` | test only | PASS |

Mutation diff kept: `$TEAM_WS/qa-artifacts/A1/mut/` (copy only; the repo files were never mutated, BASE-11).

## Commands run (trimmed)
```
$ VR_TELEX_TEST_DIR=... bash tests/install/run.sh legacy_source_order legacy_runtime_cleanup uninstall_legacy_runtime_cleanup legacy_newer_mode   # before the fix
FAIL legacy_source_order (exit 1)
PASS legacy_runtime_cleanup / uninstall_legacy_runtime_cleanup / legacy_newer_mode
--- 4 scenarios, 1 failed
$ bash qa-artifacts/A1/mut/tests/install/run.sh legacy_runtime_cleanup uninstall_legacy_runtime_cleanup legacy_newer_mode   # mutant
--- 3 scenarios, 3 failed
$ $TEAM_BIN/run-heavy.sh tests/install/run.sh      # after the fix, full, once
PASS fresh_fcitx5 ... PASS legacy_rollback_default_key
PASS legacy_source_order
PASS legacy_runtime_cleanup
PASS uninstall_legacy_runtime_cleanup
PASS legacy_newer_mode
--- 44 scenarios, 0 failed
$ shellcheck install.sh uninstall.sh packaging/common.sh tests/install/run.sh   (per-code counts, HEAD vs now)
install.sh          HEAD = NOW: SC1091x1 SC2015x2 SC2034x1 SC2174x1 (all pre-existing)
uninstall.sh        HEAD = NOW: SC1091x1 (HEAD copy only; none in tree)
packaging/common.sh HEAD = NOW: SC1003x1 SC2015x2 SC2034x3
tests/install/run.sh HEAD: SC2012x1 SC2016x7 SC2088x9 SC2119x37 SC2120x2 / NOW: SC2016x8 SC2119x41 (rest equal)
  -> no new warning class; +1 SC2016 (info, intended single-quoted `sh -c` script, same idiom as the existing checks) and +4 SC2119 (info, `run_install`/`run_uninstall` called without args, same as the 37 existing)
$ cargo fmt --check                     -> rc=0
$ run-heavy.sh cargo clippy --workspace --all-targets --locked -- -D warnings
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.13s   -> rc=0
```

## New states (round 1)
`MIG_KEEP_SELECTION` (install.sh): set only in `migrate_live`, read once in `main`.
- error halfway (daemon fails health check): rollback restores both keys from `MIG_SNAP/gs` as before (`legacy_rollback`, `legacy_rollback_default_key` PASS); the flag changes no key, so nothing extra to undo.
- second run: the next install has no vr-talex left, `MIGRATING=0`, flag stays 0 -> D33 rerun behaviour (`reselect_source` puts vr-telex first). This is the existing designed rerun behaviour (`reselect_on_rerun`), not a migration; flagged below for the leader.
- mru-sources empty: falls back to the head of sources (what gnome-shell activates).
- gs read failure in `legacy_was_current`: returns "not current"; `legacy_rename_sources` would then fail on the same read and die into the rollback.

## Out-of-scope noticed
- A user who migrated with English current and later re-runs `./install.sh` gets vr-telex moved to the mru head (D33 rerun rule). Consistent with D33; mention only if the leader wants AC-2's "keep selection" to cover reruns too.
- Packaged `vr-telex-setup` (A2/A3) must call `migrate_live` (or the same `legacy_was_current` + skip of `select_source`) to keep AC-2 "packaged setup alike".

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| read current source | common.sh `gs_get`, `list_items`, install.sh `reselect_source` | reused `gs_get`; new `legacy_was_current` in common.sh beside the other legacy helpers so the packaged setup can share it |
| legacy install fixture | tests/install/run.sh `legacy_install`, `legacy_files_gone`, `expect_installed` | reused |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| AC-2 keep selection | pass | `legacy_source_order` red -> green; install.sh `MIG_KEEP_SELECTION`, common.sh `legacy_was_current` |
| AC-2 same position | pass | `legacy_source_order` (index 0 of 3) + existing `legacy_migrate` (last) |
| AC-2 runtime address files / dir | pass | `legacy_runtime_cleanup`, `uninstall_legacy_runtime_cleanup`; mutation red |
| AC-2 no overwrite of newer mode | pass | `legacy_newer_mode`; mutation red |
| SEC-19 | pass | daemon still starts after the rename; rollback order unchanged; `legacy_rollback` PASS |
| SEC-20 | pass | no privilege change; `root_refused` PASS |
| SEC-21 | pass | foreign runtime file and another daemon's address file kept (`legacy_runtime_cleanup`) |
| SEC-22 | pass | `legacy_migrate` second-run idempotence PASS |
| SEC-23 | pass | no new `rm`; `set -euo pipefail` intact; shellcheck no new warning class |
| SEC-24 | pass | no network/remote code added |
| BASE-1 | pass | diff only install.sh, packaging/common.sh, tests/install/run.sh |
| BASE-2 | pass | no contract change |
| BASE-3 | pass | finding 1 test red first; 3/4 red by mutation copy |
| BASE-4 | pass | outputs above |
| BASE-5 | pass | full install suite and clippy via run-heavy.sh; nothing left running |
| BASE-6 | pass | English, why-comments |
| BASE-7 | n-a | no commits |
| BASE-8 | n-a | no dependency |
| BASE-9 | pass | no input boundary change |
| BASE-10 | pass | targeted scenarios while iterating; full install run once as the brief asked; guard once |
| BASE-11 | pass | no stash/checkout/reset; red via test-first and a copy in qa-artifacts |
| BASE-12 | n-a | nothing outside the repo |
| BASE-13 | pass | deleted only my own scratch dirs under qa-artifacts/A1 (red, green, mutrun, head) |
| BASE-14 | pass | all runs foreground with timeouts |
| BASE-15 | pass | no processes killed; sandboxes stop their stubs |
| BASE-16 | pass | Reuse table |
| BASE-17 | pass | nothing installed |
| BASE-18 | pass | no sub-agents |
| BASE-19 | pass | notes created at start with progress lines |
| BASE-20 | n-a | nothing removed |
| BASE-21 | n-a | no secrets in output |
| BASE-22 | pass | scenario names follow `legacy_*` / `uninstall_legacy*`; flag follows `MIG_*` |
| BASE-23 | pass | runtime cleanup proven through both entry paths (install and uninstall) |
| BASE-24 | pass | no git index/history command |
| BASE-25 | pass | guard: fmt rc=0, clippy rc=0 |
| BASE-26..BASE-37, BASE-39..BASE-44, BASE-46..BASE-48 | n-a | no rewrite, shared data, third-party code, browser, containers, schema, outward writes, credentials, runner settings, access rules, fakes of clients, fixed-value readers or real-machine state in this task |
| BASE-32 | pass | D33/D34/D37 kept: reselect still runs when vr-talex was current and on reruns |
| BASE-38 | pass | no formatter run on shell files; cargo fmt only checked |
| BASE-45 | pass | AC-2 text read from 01_spec.md |
| COST-1 | pass | heavy runs via run-heavy.sh |
| COST-2 | pass | developer tests only |
| COST-3 | pass | no polling |
| COST-4 | pass | full install suite once (requested by brief) |
| COST-5, COST-9 | pass | nothing left running |
| COST-6, COST-11, COST-12, COST-14, COST-15, COST-17, COST-19, COST-20 | n-a | no UI, e2e, CI, goldens |
| COST-7 | pass | shell tools only |
| COST-8 | pass | batched reads/edits |
| COST-10 | pass | related set = tests/install/run.sh (only test file naming the changed scripts) |
| COST-13 | pass | scratch in qa-artifacts/A1 only |
| COST-16 | pass | logs in sandbox/qa-artifacts, tails in context |
| COST-18 | n-a | no doomed run |

DONE
