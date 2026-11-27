# B1 Install by script from the latest GitHub release (D-APT-2)

## Progress
- read: D-APT-2, board row, A3/A4 notes, release.yml, test.yml, README, tools/apt-repo/README.md, tests/apt/run.sh, tests/deb/run.sh, vr-telex-setup root check
- red: tests/get/run.sh written first; run fails: missing packaging/get/vr-telex-install.sh (qa-artifacts/B1/red.log)
- code: packaging/get/vr-telex-install.sh + embed-key.sh; run2: all script checks pass, 3 README checks red (qa-artifacts/B1/run2.log)
- removed tools/apt-repo/ and tests/apt/ with plain rm (refs checked: only workflows, fixed next); README Install rewritten; packaging/get/RELEASING.md
- workflows: test.yml + release.yml rewritten; YAML parses; signing step simulated with throwaway key (qa-artifacts/B1/sim-sign.sh, sim-sign.log): good sig + sha OK, passphrase not in output, temp GNUPGHOME removed, wrong passphrase fails, non-pinned key refused
- version 0.1.1 (Cargo.toml, Cargo.lock via cargo update --workspace --offline: 6 workspace crates only); deb asset usr/bin/vr-telex-update; tests/deb expects it
- mutation check (qa-artifacts/B1/mutate.sh, mutate.log): 11 of 12 mutants killed; the survivor is equivalent (see Design choices, gpgv)
- final: tests/get PASS (130 ok), tests/deb STRICT PASS (71 ok), shellcheck rc 0, workflow run blocks shellcheck rc 0, YAML ok, guard rc 0

Tools available: Bash, Read, Edit, Write, Skill, ToolSearch, Artifact, Agent (unused, BASE-18), SubagentHandback. Present: dash, wget, curl, gpg 2.4.4, gpgv, dpkg-deb, python3 + PyYAML, shellcheck, cargo, cargo-deb.

## Summary
- Files added:
  - packaging/get/vr-telex-install.sh (755): POSIX sh install/update script; key embedded as a quoted heredoc in `pinned_key()`.
  - packaging/get/embed-key.sh (755): `[--check] [script] [key]`; rewrites the key block from packaging/apt/vr-telex.asc (or fails with --check).
  - packaging/get/RELEASING.md: release steps, signing key, renewal (extend expiry, re-export packaging/apt/vr-telex.asc, `packaging/get/embed-key.sh`, update the secret), release gate (environment apt-release + tag ruleset; gh-pages ruleset dropped; one-time "turn off Pages, delete gh-pages and its ruleset").
  - tests/get/run.sh (755): see Tests.
- Files changed:
  - .github/workflows/release.yml: no gh-pages. Build job: shellcheck list (+ new scripts), tests/deb (strict) + tests/get, artifact `release` = .deb + vr-telex-install.sh. Publish job (environment apt-release, contents: write, checkout with persist-credentials: false): temp GNUPGHOME (umask 077, trap kills the agent and removes it), key piped from APT_GPG_PRIVATE_KEY then unset, fingerprint read from packaging/apt/vr-telex.asc and required to be 2C30E91F97E5A566BEFF373736C30B9165329B85, the secret key must exist for it, SHA256SUMS over the .deb + script, `--local-user "$FPR!" --armor --detach-sign` with the passphrase on a pipe (loopback), verified with gpgv against the pinned key alone + `sha256sum --strict -c`; then `gh release create --verify-tag --latest` (or `upload --clobber`) with the 4 files. Master-tag gate unchanged.
  - .github/workflows/test.yml: apt test replaced by `bash tests/get/run.sh`; shellcheck list updated; apt-utils dropped, wget curl added.
  - crates/vr-telex/Cargo.toml: asset `["../../packaging/get/vr-telex-install.sh", "usr/bin/vr-telex-update", "755"]`.
  - Cargo.toml version 0.1.1; Cargo.lock: the 6 workspace crates 0.1.0 -> 0.1.1 (`cargo update --workspace --offline`, no dependency changed).
  - tests/deb/run.sh: expects `-rwxr-xr-x 0/0 ./usr/bin/vr-telex-update` and that it equals packaging/get/vr-telex-install.sh.
  - README.md: Install section "From the latest release" (install / update / remove); from-source and the vr-talex note kept (two switch lines reworded from "apt package" to "package" / "install command above").
  - .ai-dev-team/capabilities.md: the A4 apt-repo line replaced by a B1 line.
- Deleted with plain `rm -r` (BASE-11): tools/apt-repo/build.sh, tools/apt-repo/README.md, tests/apt/run.sh. References searched first: only both workflows and the deleted files themselves.
- Not touched: install.sh, uninstall.sh, packaging/common.sh, packaging/vr-telex-setup, tests/install/**, packaging/deb/{postinst,prerm,postrm} (none mentions the apt repository; postinst's "After an upgrade, each user runs 'vr-telex-setup' again" stays true), packaging/apt/vr-telex.asc (kept).

## README lines (exact)
- Install: `wget -qO /tmp/vr-telex-install.sh https://github.com/mvanvu/vr-telex/releases/latest/download/vr-telex-install.sh && sh /tmp/vr-telex-install.sh`
- Update: `vr-telex-update`
- Remove: `vr-telex-setup --remove` then `sudo apt remove vr-telex`

## Design choices
- **Root**: refused (`id -u` = 0: "do not run as root or with sudo; run it as your own user (it asks for sudo only to install the package)"), before any download. Why: the second half of the job is the per-user `vr-telex-setup`, which itself refuses root; under `sudo sh` the package would go in and the user would get no setup. Same rule and wording as vr-telex-setup. `id` is looked up on PATH (tests stub it); a caller who controls PATH already controls the user's shell, sudo included.
- **Architecture**: `dpkg --print-architecture` must be amd64, checked before any download; the .deb line in SHA256SUMS must end `_amd64.deb` and `dpkg-deb -f` Architecture must be amd64.
- **What is trusted**: only SHA256SUMS after `gpgv --keyring <embedded key, dearmored>` passes, with `GNUPGHOME` set to an empty dir inside the temp dir. From it: exactly one line `^<64 hex>  vr-telex_<ver>_amd64.deb$` (no path, strict charset; none: "lists no vr-telex .deb", two: "more than one"); the .deb's sha256 must equal it; `dpkg-deb -f` Package/Version/Architecture must match the name. The embedded key is dearmored with sed + base64 (gpg is not needed at run time; the test checks the result equals `gpg --dearmor`).
- **Seams**: `VR_TELEX_RELEASE_URL` accepts only the official URL or `http://127.0.0.1:<digits>[/...]`; anything else (look-alikes such as `http://127.0.0.1.example.invalid/` included) is refused before downloading. `VR_TELEX_TEST_KEY` is honoured only when that URL is loopback; with the official URL (default or explicit) it is an error, not silently ignored, so no run downloads with a swapped key. Net effect: for any non-loopback download the embedded key is the only trust anchor. Someone who can set env vars and run a loopback server already runs code as the user. Both are documented in the script header as test-only.
- **_apt notice**: handled by `chmod 0755` on the temp dir and `0644` on the .deb right before sudo (after all checks). apt reads local .debs as `_apt`; with the 0700 mktemp dir it would print "Download is performed unsandboxed as root ... couldn't be accessed by user '_apt'". Only the owner can write the dir (and /tmp is sticky), so the checked file cannot be swapped by another user; readers only see a public .deb. A TMPDIR under a 0700 home would still give the notice (harmless; the install goes on).
- **Update**: same script (`/usr/bin/vr-telex-update`). After the signature check it reads `dpkg-query -W -f '${Status} ${Version}' vr-telex`: equal: "vr-telex <ver> is already up to date" + hint to run vr-telex-setup, exit 0, .deb not downloaded, no sudo; installed newer than the release (`dpkg --compare-versions gt`): "newer ... nothing to do", exit 0 (no downgrade by a replayed old release); older / not installed: install + vr-telex-setup.
- **Downloader**: wget first (in Ubuntu desktop by default), curl otherwise; `--tries/--timeout` or `--retry/--connect-timeout`; no protocol pinning: integrity comes from the signature, not TLS.
- **Failures**: every check before sudo calls `die` (exit 1); the EXIT trap removes the temp dir (HUP/INT/TERM exit, so the trap runs). apt failure: "vr-telex-setup was not run". Setup failure: exit 1 with "installed, but vr-telex-setup failed; run vr-telex-setup again".
- **gpgv**: checked here that gpgv exits 0 for a signature by an expired key (EXPKEYSIG + "Good signature", rc 0), so renewing the key (same fingerprint) does not break old vr-telex-update copies; RELEASING.md says so. Also checked: with `--keyring`, gpgv ignores ~/.gnupg/trustedkeys.* (rc 2 when the signer is only in the default keyring). The empty GNUPGHOME is defence in depth, which is why that one mutant survives.

## Tests
tests/get/run.sh (130 checks, about 4 s): throwaway ed25519 keys (good + other) in temp GNUPGHOMEs (agents killed, dir removed by the trap); stand-in .deb by dpkg-deb; 10 fake releases (good, badsig, otherkey, badsum, nodeb, twodebs, pathdeb, nosig, missingdeb, empty) served by `python3 -I` http.server on 127.0.0.1:<free port> (stopped by the trap; its request log tells what was fetched); the script runs with `env -i ... sh` (dash), a throwaway HOME (whose ~/.gnupg/trustedkeys.gpg holds the other key) and TMPDIR; stubs log sudo (records sha256 and modes of the file at call time), apt, vr-telex-setup, dpkg-query (FAKE_INSTALLED), dpkg (FAKE_ARCH), id (FAKE_UID); a PATH without wget for the curl branch; failing wget/curl stubs for the seam cases.
Proves: embedded key == packaging/apt/vr-telex.asc, fingerprint 2C30...5329B85, decodes like gpg --dearmor, embed-key.sh --check / regenerate; README lines; happy path (wget and curl): one `sudo apt install -y <TMPDIR>/vr-telex-install.XXXXXX/vr-telex_0.9.0-1_amd64.deb`, that file's sha = released, modes 644/755, then `vr-telex-setup` once, temp dir removed; up to date (no sudo, .deb not fetched), older installed (installs), newer installed (no sudo); refusals with no sudo, no setup, temp dir removed: changed after signing, other key (also in the user's trustedkeys), no .asc, wrong sha256, .deb not listed, two .debs, path in name, .deb download fails, empty release, non-amd64 (nothing fetched), root (nothing fetched); apt fails (no setup, dir removed); setup fails (non-zero, message); seams: test key + official URL (default and explicit) refused with no download, foreign URL refused, look-alike loopback refused, loopback without the test key: the pinned real key is used and the release is refused.

## Commands run (trimmed)
```
$ bash tests/get/run.sh                    # red, before the script existed (qa-artifacts/B1/red.log)
error: missing /home/rainy/DEV/vr-telex/packaging/get/vr-telex-install.sh
$ bash tests/get/run.sh                    # run2, script written (qa-artifacts/B1/run2.log)
FAIL  README: install line
FAIL  README: update command
FAIL  README: no apt repository left
FAIL: 3 check(s) failed                    -> README rewritten
$ bash qa-artifacts/B1/mutate.sh           # mutate.log (each mutant on a temp copy)
killed:   no signature check (9 FAIL)
SURVIVED: user GnuPG home for gpgv        (equivalent: --keyring already excludes the default keyring, checked by hand)
killed:   test key with any URL (4 FAIL)
killed:   any base URL (4 FAIL)
killed:   no sha256 compare (3 FAIL)
killed:   no chmod for _apt (1 FAIL)
killed:   no root check (5 FAIL)
killed:   no arch check (5 FAIL)
killed:   no up-to-date skip (4 FAIL)
killed:   no cleanup trap (15 FAIL)
killed:   setup failure ignored (1 FAIL)
killed:   relative deb path (5 FAIL)
$ ( cd /home/rainy/DEV/vr-telex && $TEAM_BIN/run-heavy.sh bash tests/get/run.sh )   # final-get.log
ok    happy: one call 'sudo apt install -y <abs temp path>/vr-telex_0.9.0-1_amd64.deb'
ok    happy: _apt can read it (file 644, dir 755)
ok    happy: vr-telex-setup runs once, after apt, with no arguments
ok    up to date: says already up to date
ok    up to date: no sudo / apt call
ok    signed by another key (also in ~/.gnupg/trustedkeys.gpg): no sudo / apt call
ok    test key with the official URL: no download attempted
ok    loopback release without the test key (pinned key used): says why (signature)
...
PASS                                        rc=0, 130 ok, 0 FAIL
$ VR_TELEX_DEB_STRICT=1 $TEAM_BIN/run-heavy.sh bash tests/deb/run.sh                  # final-deb.log
package: /tmp/vr-telex-deb-test.TOh27s/out/vr-telex_0.1.1-1_amd64.deb
ok    file name is vr-telex_0.1.1-1_amd64.deb
ok    usr/bin/vr-telex-update matches packaging/get/vr-telex-install.sh
PASS                                        deb_rc=0, 71 ok
$ shellcheck -x packaging/get/vr-telex-install.sh packaging/get/embed-key.sh tests/get/run.sh tests/deb/run.sh \
    install.sh uninstall.sh packaging/vr-telex-setup packaging/deb/postinst packaging/deb/prerm packaging/deb/postrm
shellcheck_rc=0
$ shellcheck qa-artifacts/B1/runblocks/*.sh   # every run: block of both workflows (runblocks.py); no ${{ }} in any run block
shellcheck_runblocks_rc=0
$ python3 -I -c 'yaml.safe_load(...)' .github/workflows/{release,test}.yml
release.yml ok ['build', 'publish'] / test.yml ok ['test']
$ bash qa-artifacts/B1/sim-sign.sh            # publish signing step, throwaway key, fpr swapped (sim-sign.log)
right passphrase: rc=0, gpgv Good signature, sha256sum -c OK x2, passphrase in output: 0, temp GNUPGHOME left: 0
wrong passphrase: rc=2, no SHA256SUMS.asc
key not pinned:   rc=1 ::error::APT_GPG_PRIVATE_KEY is not the key of packaging/apt/vr-telex.asc
$ cargo fmt --check && $TEAM_BIN/run-heavy.sh cargo clippy --workspace --all-targets --locked -- -D warnings   # guard.log
    Checking vr-telex v0.1.1 (/home/rainy/DEV/vr-telex/crates/vr-telex)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 1.76s
guard_rc=0
```

## Deviations from the brief
- None in behaviour. Additions: refusal of a non-official, non-loopback `VR_TELEX_RELEASE_URL` (tighter than "honoured"); "newer installed: nothing to do" (no downgrade); `dpkg-deb -f` field check; `embed-key.sh` as the generator.

## Out-of-scope / for the owner
- Owner one-time steps after merge (RELEASING.md gate step 4): turn off GitHub Pages, delete `gh-pages` and its ruleset. Not done by this task (outward write).
- Until v0.1.1 is published with this flow, the README install line returns 404 (`releases/latest/download/vr-telex-install.sh` does not exist yet).
- Residual: an older, properly signed release served in place of the latest could be replayed to a fresh install (not to an update: newer-installed check). Downloads come only from github.com, so this needs GitHub itself compromised.
- No cargo test / tests/install run: no Rust or installer code changed (only the version number); the guard ran.

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| loopback HTTP server for tests | capabilities.md, tests/apt/run.sh | reused the `python3 -I` http.server + port-on-stdout pattern from tests/apt/run.sh (before deleting it), with the request log kept |
| throwaway keys / stand-in .deb | tests/apt/run.sh `new_key`, `fake_deb` | reused (copied, adapted) |
| check/ok/bad/cleanup harness | tests/deb/run.sh, tests/apt/run.sh | same helpers and output format |
| root refusal wording | packaging/vr-telex-setup | same message |
| publish secret handling | release.yml publish step, tools/apt-repo/build.sh gpg flags | kept: piped import, unset, temp GNUPGHOME + trap, loopback + passphrase-fd 0, pinned fingerprint |
| key renewal / gate docs | tools/apt-repo/README.md | moved to packaging/get/RELEASING.md and updated |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 | pass | working tree status: only row files + capabilities.md + notes; no install.sh/common.sh/setup/postinst edits |
| BASE-3 | pass | tests/get/run.sh written first; red.log (missing script), run2.log (README red); mutate.log |
| BASE-4 | pass | Commands run section (final-get.log, final-deb.log, guard.log, shellcheck) |
| BASE-5 | pass | final tests/get, tests/deb and clippy through run-heavy.sh; http server and gpg agents stopped by traps; no temp dirs left in /tmp |
| BASE-6 | pass | code, comments and docs in English; comments explain why |
| BASE-9 | pass | signature + sha256 + name/field checks before sudo; seams restricted (Design choices); secret never echoed (sim-sign.log: passphrase count 0) |
| BASE-10 | pass | ran tests/get, tests/deb, shellcheck, guard only |
| BASE-11 | pass | deleted with plain `rm -r tools/apt-repo tests/apt`; no git command on the tree |
| BASE-14 | pass | deb test + guard ran as one background task; no sleep or poll |
| BASE-15 | pass | stopped nothing by name; my one background task finished on its own |
| BASE-16 | pass | Reuse table; capabilities.md line replaced |
| BASE-17 | pass | no tool installed |
| BASE-18 | pass | no agents started |
| BASE-19 | pass | Progress lines from the start |
| BASE-20 | pass | grep for apt-repo / tests/apt / APT_PINNED_KEY / github.io before deletion: only the workflows (updated) |
| BASE-21 | pass | no secret in team files; throwaway keys only; the real private key and its GnuPG home never touched |
| BASE-22 | pass | env names follow VR_TELEX_* (VR_TELEX_RELEASE_URL, VR_TELEX_TEST_KEY, VR_TELEX_GET_KEEP like VR_TELEX_DEB_KEEP) |
| BASE-23 | pass | both entry paths: install (happy) and update (up to date / older / newer); the packaged copy is proven equal by tests/deb |
| BASE-24 | pass | no index or history command run |
| BASE-25 | pass | guard rc 0 (guard.log) |
| BASE-32 | pass | D-APT-2: no apt repo, script from the latest release, signed SHA256SUMS, embedded key, gates kept (apt-release env, master tag check) |
| BASE-38 | pass | no formatter run (cargo fmt --check only) |
| COST-1 | pass | heavy runs via run-heavy.sh |
| COST-3 | pass | no sleep/pgrep; the server port is read from its stdout |
| COST-4 | pass | no full suite |
| COST-5 | pass | server and gpg agents stopped by traps |
| COST-8 | pass | files written whole, edits batched; perl -pi for substitutions |
| COST-9 | pass | nothing left running |
| COST-10 | pass | related set: grep for vr-telex-install / tests/apt / apt-repo over tests/ gives tests/get, tests/deb |
| COST-13 | pass | throwaway scripts in qa-artifacts/B1 (mutate.sh, sim-sign.sh, runblocks.py) |
| COST-16 | pass | full outputs in qa-artifacts/B1/*.log, trimmed here |

n-a: BASE-2 (no API contract) · BASE-7 (no commit in this task) · BASE-8 (no new dependency) · BASE-12, BASE-13 (nothing written outside the repo; no untracked file deleted) · BASE-26, BASE-28, BASE-36, BASE-39, BASE-42, BASE-43, BASE-44 (no rewrite, third-party code, app scope, schema, test runner settings, access rules or fake adapters) · BASE-27, BASE-29, BASE-30, BASE-31, BASE-40, BASE-41 (no shared DB, browser, container, outward write or credentials) · BASE-33, BASE-46, BASE-48 (no claim about a remote system's state; GitHub release/Pages steps left to the owner) · BASE-34 (nothing blocked) · BASE-35 (no USER rules for this area) · BASE-37, BASE-47 (not a runtime defect fix; no computed value) · BASE-45 (AC text unchanged; D-APT-2 supersedes AC-5 in decisions.md) · COST-2, COST-6, COST-7, COST-11, COST-12, COST-14, COST-15, COST-17, COST-18, COST-19, COST-20 (no UI, browser, e2e, goldens, CI wait or audit in this task)

## Quick pass 1

- release.yml: dropped `--latest` from `gh release create` (Latest is now picked by gh by date and version); the `gh release upload --clobber` branch is untouched.
- README.md: after the install description, added a short paragraph saying the first run trusts `vr-telex-install.sh` on HTTPS alone (the signature protects the .deb and vr-telex-update), plus the optional by-hand check (download files, `gpg --import`, `gpg --verify`, `sha256sum -c --ignore-missing`). Install line unchanged.
- Commands: release.yml YAML parse: `yaml ok`; `grep -- --latest release.yml`: no match; `bash tests/get/run.sh`: PASS.
