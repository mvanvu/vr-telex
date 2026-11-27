
## QC A1 (commit e14cbc2, tree also has A3 WIP in crates/vr-telex/Cargo.toml and packaging/deb/, ignored)
- cargo test --workspace --locked: rc=0, 247 passed, 0 failed, 1 ignored (log: qa-artifacts/A1/cargo-test.log).
- cargo fmt --check: OK. cargo clippy --workspace --all-targets --locked -D warnings: clean.
- tests/install/run.sh (sandboxed: env -i, throwaway HOME, private bus, stubs): 40 scenarios, 0 failed (qa-artifacts/A1/install.log).
- git grep vr-talex/VR_TALEX outside .ai-dev-team: all hits classified as
  migration code (install.sh, uninstall.sh, packaging/common.sh), README "Upgrading from vr-talex" note,
  legacy fixture (tests/install/legacy/**, the old installer used to build a fake old install), test code (tests/install/run.sh, stubs/fake-ime). Other: none.
- AC-2 mapping: stop/disable unit, remove unit/binary/env/D-Bus+autostart files/state dir: legacy_migrate; mode moved: legacy_migrate ("VI/EN mode carried over"); backup moved (rewritten, old one removed): legacy_migrate; no overwrite of existing data: legacy_both_dirs; source renamed in place keeping selection: legacy_migrate (sources / mru-sources checks), legacy_source_only; idempotent: legacy_migrate (second install); uninstall restores pre-install state: legacy_migrate, uninstall_legacy; rollback: legacy_rollback*, foreign files kept: legacy_foreign_file, foreign_legacy_name_only; no backup: legacy_without_backup.
- Minor gap: explicit removal of the vr-talex runtime address files ($XDG_RUNTIME_DIR/vr-talex, IBus address files) is only covered indirectly (legacy_files_gone helper / address-file check in rollback); I did not separately confirm a dedicated assertion in the migrate path.

## Rule check A1
| Rule | Result | Evidence |
|---|---|---|
| AC-1 suites green | PASS | cargo test 247/0, fmt, clippy clean |
| AC-1 leftover vr-talex strings | PASS | all hits migration code / legacy fixture / README migration note / test code |
| AC-2 migration | PASS (runtime address file removal indirectly proven) | 40/40 install scenarios |
| SEC-19..24 | PASS | tests/install sandbox scenarios pass (foreign file, symlink, rollback cases) |

QC_PASS

## QC A3
Commit e14cbc2 + uncommitted A3 files. Engine: shell (tests/deb/run.sh, dpkg-deb, cargo-deb 3.8.0). No browser needed. Package NOT installed.

- `run-heavy.sh tests/deb/run.sh` -> `PASS with placeholders (missing A2 sources: packaging/vr-telex-setup)`, rc 0 (log: qa-artifacts/A3/qc_run.log). Setup-script item (content of /usr/bin/vr-telex-setup, the common.sh-vs-setup compare) UNVERIFIED until A2; the packaged setup is a 62-byte placeholder.
- Independent inspection (qa-artifacts/A3/vr-telex_0.1.0-1_amd64.deb, extracted to x/, control to ctl/):
  - dpkg-deb -f: Version 0.1.0-1 (Cargo 0.1.0); Maintainer `vr-telex project <https://github.com/mvanvu/vr-telex>` (no email); Depends `dbus-user-session, libc6 (>= 2.34), libglib2.0-bin, systemd`; Description summary+long text present.
  - dpkg-deb -c: /usr/bin/vr-telex 755, /usr/bin/vr-telex-setup 755, /usr/lib/systemd/user/vr-telex.service, /usr/share/vr-telex/{common.sh,90-vr-telex.conf,xinputrc,org.fcitx.Fcitx5.desktop,org.fcitx.Fcitx5.service}, /usr/share/doc/vr-telex/{README.md,THIRD-PARTY-NOTICES.md,copyright}; all owners 0/0.
  - Unit: `ExecStart=/usr/bin/vr-telex`, rest same as source (test enforces).
  - copyright: DEP-5, `License: MIT` full text, SCOWL third-party stanza pointing to THIRD-PARTY-NOTICES.md.
  - Maintainer scripts read in full: all print-only, `exit 0`, no systemctl/gsettings/su/HOME access; postinst points to vr-telex-setup; prerm(remove)/postrm(purge) tell users to run `vr-telex-setup --remove`; upgrades silent. Test also runs them under env -i with stubs (never called).
- Note: build copied packaging/ at run time; no mid-edit problem seen (common.sh packaged, test checked).

## Rule check A3
| Check | Result |
|---|---|
| AC-4 package paths/contents | pass (setup content unverified until A2) |
| AC-4 control fields (Depends/Description/Maintainer/version) | pass |
| AC-4 maintainer scripts leave sessions untouched, point to --remove | pass |
| AC-4 test of dpkg-deb -c/-f exists and passes | pass (with placeholders) |
| No install / no sudo | respected |

QC_PASS A3 (AC-4 fully re-verify with strict mode once A2's packaging/vr-telex-setup exists)

## QC A4
HEAD a31e480 + uncommitted A4 files (tools/apt-repo/build.sh, tests/apt/run.sh, .github/workflows/{test,release}.yml, packaging/apt/vr-telex.asc, README install section). Engines: bash, apt-get/apt-cache via throwaway root, gpg/gpgv, PyYAML. No browser needed.

- AC-5: `run-heavy.sh tests/apt/run.sh` -> rc 0, PASS (log qa-artifacts/A4/qc_run1.log). Independently seen in the output: "apt-get update with signed-by keyring passes the signature check", "apt-get update without the keyring is refused (NO_PUBKEY, not signed)" + no candidate, "with another key is refused", tampered Packages / InRelease refused, old version kept, candidate = newest.
- AC-5 with real committed package: `cargo deb -p vr-telex --locked` fails only because packaging/vr-telex-setup is missing at that moment (A2 in flight): "Can't resolve asset ... packaging/vr-telex-setup -> usr/bin/" (qa-artifacts/A4/qc_deb.log). Not an A4 defect; fake-deb run is the AC-5 evidence. Real-.deb run: unverified, re-run after A2 (CI release job also runs it).
- AC-6 static: both YAML files parse; release trigger push tags `v*`; test trigger push master + pull_request; permissions: top `contents: read`, build `contents: read`, publish `contents: write` only; all 4 `uses:` pinned by 40-hex SHA (checkout, upload-artifact, download-artifact); only secrets referenced: APT_GPG_PRIVATE_KEY, APT_GPG_PASSPHRASE (publish job step env only); no `set -x`; key unset after import; temp GNUPGHOME cleaned by trap; signing key tied to committed .asc fingerprint. Live run on GitHub: unverified: needs push.
- AC-7 by reading: commands exact and consistent (keyring /etc/apt/keyrings/vr-telex.gpg, signed-by line with arch=amd64, `stable main`, update, install, vr-telex-setup); fingerprint in README 2C30E91F97E5A566BEFF373736C30B9165329B85 == `gpg --show-keys packaging/apt/vr-telex.asc` (RSA 4096, no secret block); URL matches origin mvanvu/vr-telex Pages; remove order `vr-telex-setup --remove` then `sudo apt remove vr-telex`, then source + keyring removal; `--remove` exists in packaging/vr-telex-setup. Gap (minor): the README tells the user to compare the fingerprint but the pipeline's `wget` step is not gated; informational only.
- Nothing installed, no sudo, real key dir untouched.

## Rule check A4
| Check | Result |
|---|---|
| AC-5 local signed apt update passes with keyring / fails without | pass (fake debs) |
| AC-5 real cargo-deb .deb run | unverified: build blocked by A2 in flight (packaging/vr-telex-setup missing) |
| AC-6 YAML/triggers/permissions/SHA pins/secret names | pass |
| AC-6 live workflow run | unverified: needs push |
| AC-7 README commands, fingerprint, remove order | pass |
| No secrets in repo / private key untouched | pass |
| No install / no sudo / no code edits | respected |

QC_PASS A4
