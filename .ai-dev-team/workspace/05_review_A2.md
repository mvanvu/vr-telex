# Review A2 — CHANGES_REQUESTED

Tools available: Bash, Read, Write, Skill, SendMessage, SubagentHandback.

## Files read
- install.sh — read
- uninstall.sh — read
- packaging/common.sh — read (moved functions compared function by function with HEAD install.sh / uninstall.sh / common.sh; new: use_checkout, use_package, share_file, check_package, retire_checkout_files, install_main, uninstall_main, init_paths branch)
- packaging/vr-telex-setup (new) — read
- tests/install/run.sh — read (diff: only additions besides the header comment and the scenario list line)
- tests/install/stubs/systemctl — read

## Findings

[major] packaging/common.sh:942 — check_package refuses a user unit override only when a manifest exists
Scenario: the user has their own `~/.config/systemd/user/vr-telex.service` (hand-written, e.g. from an earlier manual build) and no vr-telex backup. `vr-telex-setup` skips the check because `[ -f "$MANIFEST" ]` is false, then `installed_without_backup` (common.sh:1225) stops with "vr-telex is installed without a backup; run vr-telex-setup --remove first". Following that advice, `--remove` (remove_without_backup) runs `systemctl --user disable --now vr-telex.service` on the user's own unit, deletes `~/.local/bin/vr-telex` without checking it, and leaves the unit in place ("changed after install"). The next `vr-telex-setup` stops with the same message. The user is stuck in a loop, and the advice it gives disables their unit and deletes their binary. t_setup_unit_override covers only the case with a manifest.
Fix: remove the `[ -f "$MANIFEST" ] &&` condition. With no installed record, refuse with the override message unless `UNIT_DST` matches `share_file vr-telex.service` (a from-source unit, which still goes to the "installed without a backup" path). Add a no-manifest case to t_setup_unit_override.

[major] packaging/common.sh:968-971 — retire_checkout_files: the "edited file is moved aside" branch has no test
Scenario: a mutation that always runs `rm -f -- "$f"` (and deletes a user-edited `~/.config/systemd/user/vr-telex.service` or `~/.local/bin/vr-telex` from an earlier install.sh) passes all 55 scenarios. t_setup_from_source checks only the unedited case ("no copy ... kept aside"). The brief names this behaviour, and a regression would silently lose the user's edit.
Fix: add a scenario: install.sh, edit the installed unit, then vr-telex-setup. Assert that the `*.vr-telex-saved-*` copy holds the edit, the packaged unit is enabled, and `--remove` restores the pre-install snapshot except for the saved copy.

[minor] packaging/common.sh:957-959 — stale installed records after a package-mode vr-talex migration
Scenario: when vr-telex-setup migrates a vr-talex install, legacy_rewrite_backup (common.sh:745-751) creates `installed/.local/bin/vr-telex` and `installed/.config/systemd/user/vr-telex.service`, but package mode never writes those files. retire_checkout_files runs `exists "$f" || continue` first, so the records stay. If the user later adds their own `~/.config/systemd/user/vr-telex.service`, check_package (common.sh:942) finds the record and does not refuse. retire_checkout_files then moves the user's unit aside instead of refusing before any change.
Fix: in retire_checkout_files, drop the record when its file is absent (`exists "$f" || { rm -f -- "$inst"; continue; }`).

[low] packaging/vr-telex-setup:1,21 — CWE-426: the root check relies on PATH
Data path: the caller's environment → `/usr/bin/env bash` (bash is found through PATH, and BASH_ENV is honoured) and the external `id` (also found through PATH).
Exploit: only a root caller whose PATH or BASH_ENV is already hostile, so this crosses no privilege boundary (sudo resets both). The env seams VR_TELEX_SHARE, VR_TELEX_BIN and VR_TELEX_SYSTEM_UNIT_DIR are honoured in production. They are set only by the same unprivileged user, root is refused before anything is sourced, and every write stays under HOME, so they are not a finding.
Fix: use `#!/bin/bash` for the packaged script and `[ "${EUID}" -eq 0 ]` (a bash builtin, not found through PATH).

Verified OK: the code is moved, not copied. Each moved function matches HEAD except the `$SHARE`, `$INSTALL_CMD` and `$UNINSTALL_PATH` substitutions and the legacy_was_current reorder in migrate_live (common.sh:1364-1365, now read before legacy_stop_unit). install.sh and uninstall.sh keep their behaviour: the only change is that uninstall without a backup also acts when the unit is enabled or active. All 44 earlier scenarios are present, with their assertions unchanged. Root is refused before `. "$SHARE/common.sh"`. The packaged unit is enabled only through the per-user wants link (daemon-reload first; no copy, no --global). Switching between install kinds keeps the first backup. The stub systemctl differs from HEAD only by the unit_file lookup.

## Rule check A2
| Rule | Status | Evidence |
|---|---|---|
| AC-3 | pass | vr-telex-setup → use_package (/usr/bin/vr-telex, /usr/lib/systemd/user); check_package never runs cargo; t_setup_fresh; root refused (vr-telex-setup:21) |
| AC-2 | pass | same plan_migration / migrate_live / migrate_commit path; t_setup_legacy_migrate, t_setup_legacy_keep_selection |
| Plan Fixed paths | pass | defaults match 02_plan.md:5-10; Cargo assets unchanged |
| SEC-19 | pass | on_exit/restore_all unchanged; t_setup_broken_daemon; print_recovery names `vr-telex-setup --remove` |
| SEC-20 | pass | root refused before sourcing; writes only under HOME; systemctl --user only (/usr paths are read-only defaults) |
| SEC-21 | pass | single backup shared by both install kinds; t_setup_from_source / t_install_after_setup snapshots |
| SEC-22 | pass | rerun keeps the manifest; idempotence checks in t_setup_fresh |
| SEC-23 | pass | set -euo pipefail; rm targets fixed under HOME; shellcheck: no new warnings (SC2174/SC2034 came over with the moved code) |
| SEC-24 | pass | package mode: no cargo, curl or wget (stub cargo logs; check "never ran cargo") |
| BASE-16 | pass | function-level diff against HEAD: moved, not copied |
| install.sh/uninstall.sh unchanged | pass | scenario list: 11 added, none removed; no assertion lines removed |
| BASE-11 | pass | `git diff tests/install/stubs/systemctl` = only the sysdir/unit_file edit |
| BASE-3 / tests | fail | edited-file branch of retire_checkout_files untested (major above); no-manifest override case untested |

REVIEW_FAIL

## Re-check round 1

Scope: the round-1 changes only. In packaging/common.sh, only `check_package` and `retire_checkout_files` changed (I compared the functions one by one with the round-0 tree). Also read: packaging/vr-telex-setup (shebang, EUID check), and tests/install/run.sh (t_setup_root_refused, t_setup_unit_override, t_setup_from_source_edited, t_setup_legacy_then_override, plant_user_unit, expect_override_refused). Evidence: fix1-full.log ends `--- 57 scenarios, 0 failed`; the red and mut2 lines are quoted in 04_dev_A2.md `## Fix round 1`.

1. **User-unit refusal: fixed.** common.sh:946-949 now refuses any `UNIT_DST` without an installed record, with or without a manifest, before any change. The only exception is no manifest with a file byte-identical to the from-source unit (`share_file vr-telex.service`, derived from the packaged unit, whose presence is checked just above). That case gets the `--remove` advice. `--remove` then reaches `remove_if_ours` with the same derived unit, which removes it because it matches. The next setup no longer finds `UNIT_DST`, so it cannot loop. It can delete only a file byte-identical to vr-telex's own unit, never a unit the user wrote. A from-source unit from an older release with different bytes is refused with "move it away". That wording is slightly off, but nothing loops and nothing is lost (not a finding). The test covers the no-backup, with-backup and from-source-without-backup cases, and asserts no changing systemctl call.
2. **Moved-aside branch: fixed.** t_setup_from_source_edited edits both the unit and the binary after install.sh. It asserts the saved copies hold the edits, the warning names the kept unit, the packaged unit is enabled and running, and `--remove` restores the pre-install snapshot except for the kept copies. The mut2 copy (keep_user_copy → rm -f) fails 4 checks, so the branch is really exercised.
3. **Stale records: fixed.** common.sh:967-970 drops the record when its file is absent. This loses nothing: `restore_entry` uses the record only to tell edits apart, and an absent file needs no such check. t_setup_legacy_then_override shows that a later user unit is refused and left in place.
4. **Root check: fixed.** vr-telex-setup now uses `#!/bin/bash` and `[ "$EUID" -eq 0 ]`, before `$SHARE/common.sh` is read. Real root is not available (no user namespaces). The test therefore runs a copy with `$EUID` replaced by 0, after asserting that the copy differs. This proves the check reads EUID and stops before the planted common.sh runs. The id stub still covers `require_user`. Without root, this is adequate evidence for a three-line, ordering-only check.

**`--remove` without a backup** (disables any `vr-telex.service`, runs `rm -f ~/.local/bin/vr-telex` unchecked): this behaviour already existed in uninstall.sh at HEAD, and A2 moved it unchanged. It is not an A2 finding. After fix 1, the setup no longer sends a user with a foreign unit there. Optional follow-up for the leader's backlog (low): check `~/.local/bin/vr-telex` against a recorded or known build before removing it.

No new issues found.

## Rule check A2 (round 1)
| Rule | Status | Evidence |
|---|---|---|
| AC-3 | pass | unchanged paths; t_setup_fresh; override refusal before any change |
| AC-2 | pass | migration path unchanged; t_setup_legacy_then_override |
| SEC-20 | pass | `#!/bin/bash`, EUID check before sourcing (vr-telex-setup:24) |
| SEC-21 | pass | t_setup_from_source_edited snapshot after --remove |
| SEC-23 | pass | no new rm target outside the recorded backup paths; shellcheck unchanged |
| BASE-3 / tests | pass | red runs fix1-red / fix1-red2; mut2 kills the moved-aside branch |
| BASE-16 | pass | only check_package and retire_checkout_files changed |
| BASE-46 | pass | fix1-full.log 57/0 and fix1-deb.log after the last change |

REVIEW_PASS
