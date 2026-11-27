# B3 apt upgrade updates vr-telex (D-APT-3)

## Progress
- read: D-APT-2/3, board row, B1 notes, release.yml, test.yml, README, tests/deb/run.sh, 2e1e6cb build.sh + tests/apt/run.sh, capabilities.md
- design: build script packaging/apt/build-flat-repo.sh (named in the brief), keyring committed as packaging/deb/vr-telex.gpg, source packaging/deb/vr-telex.sources; red test first
- red: tests/apt/run.sh written first; run fails: missing packaging/apt/build-flat-repo.sh (qa-artifacts/B3/red.log)
- code: build-flat-repo.sh, packaging/deb/vr-telex.sources, packaging/deb/vr-telex.gpg (gpg --dearmor of packaging/apt/vr-telex.asc)
- run1: apt asks for <base>/./InRelease -> local server 404. Checked GitHub (curl --path-as-is, HEAD-like GET of SHA256SUMS): latest/download/./SHA256SUMS -> 302 to releases/download/v0.1.1/SHA256SUMS, same as without ./ ; server now imitates that (two 302 hops like GitHub)
- run2 (qa-artifacts/B3/run2.log): everything green except the workflow checks (not written yet) and 2 "offers no vr-telex" checks (installed status entry counts as candidate; check fixed to look for the repo URL)
- finding: a source whose Signed-By file is missing makes apt-get update fail (E: ... is not signed, rc 100) -> a conffile source left after `apt remove` (keyring gone with the package) would break every apt update until purge. Decision: postinst-written source (template in /usr/share/vr-telex), postrm remove/purge deletes it
- tests/deb: keyring/source/DPKG_ROOT lifecycle checks added; STRICT run PASS 93 ok (qa-artifacts/B3/deb1.log)
- release.yml/test.yml: apt-utils, shellcheck list, tests/apt in build job (real .deb) and test.yml; publish step calls build-flat-repo.sh, uploads 5 more files; YAML ok
- tests/apt PASS 60 ok (stand-ins, run3.log) and with the real 0.1.2 .deb (run-realdeb.log)
- mutation (qa-artifacts/B3/mutate.sh, mutate.log): 8 of 9 killed; survivor release-lists-deb is equivalent (apt-ftparchive release never hashes .deb files)
- README Update/Remove + Install file list; tests/get README assertion narrowed (out-of-row file, see Deviations); RELEASING.md; capabilities.md line
- final: tests/apt PASS 60 ok, tests/deb STRICT PASS 93 ok, tests/get PASS 130 ok, shellcheck rc 0 (files + workflow run blocks), YAML ok, guard rc 0

Tools available: Bash, Read, Edit, Write, Skill, ToolSearch, Artifact, Agent (unused, BASE-18), SubagentHandback. Present: apt 2.8.4, apt-ftparchive, gpg/gpgv, dpkg-deb, python3 + PyYAML, shellcheck, cargo, cargo-deb (via the PATH prefix).

## Summary
- Files added:
  - packaging/apt/build-flat-repo.sh (755): `<deb> <out-dir>`; checks the .deb (name pattern, Package vr-telex, amd64, name = Version); the signing key must be the pinned key (APT_PINNED_KEY, default packaging/apt/vr-telex.asc); probe-signs first (wrong/missing passphrase fails, no prompt); `apt-ftparchive packages` on a temp dir holding only that .deb, `Filename: ./x` -> `Filename: x`; exactly one stanza; Packages.gz (gzip -9n); `apt-ftparchive release` over a dir holding only Packages + Packages.gz (Origin/Label vr-telex, Architectures amd64, Date, no Valid-Until); InRelease (clearsign) + Release.gpg (armored detached), SHA512 digest, `--local-user FPR!`; gpgv-verifies both with the pinned key alone and InRelease text == Release; only then installs the 5 files 0644 into out-dir. Never copies the .deb; other files in out-dir untouched.
  - packaging/deb/vr-telex.sources: deb822 source (Types deb, URIs https://github.com/mvanvu/vr-telex/releases/latest/download/, Suites ./, Architectures amd64, Signed-By /usr/share/keyrings/vr-telex.gpg) with a comment header (Enabled: no to opt out; apt remove removes it).
  - packaging/deb/vr-telex.gpg: binary keyring = `gpg --dearmor <packaging/apt/vr-telex.asc` (committed; tests/deb proves byte equality + fingerprint).
  - tests/apt/run.sh (755): see Tests.
- Files changed:
  - packaging/deb/postinst: on configure writes /etc/apt/sources.list.d/vr-telex.sources from /usr/share/vr-telex/vr-telex.sources when no file/symlink exists (via .dpkg-new + mv, 0644; apt ignores *.dpkg-new silently); an existing different file is kept with a 2-line note; new line "'sudo apt update && sudo apt upgrade' installs new releases."; all paths under "$DPKG_ROOT".
  - packaging/deb/postrm: on remove and purge `rm -f` the source (+ .dpkg-new); purge message unchanged.
  - crates/vr-telex/Cargo.toml: assets vr-telex.sources -> usr/share/vr-telex/ (644), vr-telex.gpg -> usr/share/keyrings/ (644).
  - Cargo.toml 0.1.2; Cargo.lock: the 6 workspace crates 0.1.1 -> 0.1.2 (`cargo update --workspace --offline`, no dependency changed).
  - .github/workflows/release.yml: header; build job installs apt-utils, shellchecks the 2 new scripts, runs `bash tests/apt/run.sh "$DEB"` (real .deb); publish job installs apt-utils; step renamed "Write and sign SHA256SUMS and the apt repository": after the SHA256SUMS signature + gpgv + sha256sum checks, `APT_GPG_KEY="$FPR" bash packaging/apt/build-flat-repo.sh "$REL/$DEB" "$REL"` with the same temp GNUPGHOME (trap unchanged) and APT_GPG_PASSPHRASE still in the step env (the script pipes it), then `unset APT_GPG_PASSPHRASE`, then exactly 9 files required; upload list + the 5 files; release notes mention apt upgrade. Gates unchanged (environment apt-release, tag on master, pinned fingerprint).
  - .github/workflows/test.yml: apt-utils install, shellcheck list + 2 scripts, step "Apt repository test" `bash tests/apt/run.sh`.
  - tests/deb/run.sh: expected contents + ./usr/share/vr-telex/vr-telex.sources and ./usr/share/keyrings/vr-telex.gpg (-rw-r--r-- 0/0); both equal their repo source; keyring == dearmored .asc, one key with fpr 2C30E91F97E5A566BEFF373736C30B9165329B85, binary, no secret packet; nothing under ./etc, no conffiles; source fields exact; maintainer scripts now run with DPKG_ROOT = a copy of the unpacked package; lifecycle: install writes the packaged copy 0644 and nothing else in /etc, upgrade keeps it, an edited file is kept on upgrade (+ note), prerm remove keeps, postrm remove deletes (edited too), purge after remove ok, purge deletes, an existing symlink is left alone.
  - tests/get/run.sh: README assertion "no apt repository left" (forbade sources.list|keyrings) -> "no GitHub Pages apt repository left" (github.io|gh-pages). See Deviations.
  - README.md: Install file list, Update, Remove (exact text in the report).
  - packaging/get/RELEASING.md: the apt repo files, tests/apt, nine uploaded files, key renewal also regenerates packaging/deb/vr-telex.gpg; apt rejects EXPKEYSIG, so the renewed keyring must reach users before 2029-11-26.
  - .ai-dev-team/capabilities.md: B3 line.

## Design choices
- Source file: postinst-written, not a conffile (deviation from "ships /etc/apt/sources.list.d/vr-telex.sources"; reason measured): with Signed-By pointing at a missing file apt-get update fails (`E: The repository '... ./ InRelease' is not signed.`, rc != 0; tests/apt check "keyring file missing"). A conffile stays after `apt remove` while the keyring (/usr/share/keyrings, a normal package file) is deleted, so every later `sudo apt update` of a user who removed vr-telex would fail until `apt purge`. Deleting a conffile from postrm remove goes against conffile semantics (dpkg would not recreate it on reinstall). So: template shipped at /usr/share/vr-telex/vr-telex.sources, postinst copies it when absent, postrm remove|purge deletes it. Kept from conffile semantics: a local edit survives upgrades (postinst never replaces an existing file or symlink); opt-out is `Enabled: no`. Lost: dpkg -S does not list the file, and a future template change will not reach an existing copy without an explicit migration in postinst.
- Keyring: committed binary (no build step before cargo-deb, no gpg needed to build); tests/deb fails with the regeneration command if it drifts from the .asc. Used only via Signed-By; nothing in /etc/apt/trusted.gpg.d (tests/deb: nothing under ./etc; postinst writes only the source).
- `./` in the request path: apt requests `<base>/./InRelease` and `<base>/./Packages.gz` for `Suites: ./`, and `<base>/<Filename>` for the .deb. Checked on GitHub with the current release: `curl --path-as-is https://github.com/mvanvu/vr-telex/releases/latest/download/./SHA256SUMS` -> 302 to `releases/download/v0.1.1/SHA256SUMS`, identical to the request without `./`. The test server imitates that (latest/download -> 302 releases/download/<rel>/<name> -> 302 asset; any other path 404).
- Filename is the bare .deb name so apt fetches `<base>/<deb>` (the asset URL).
- The script runs in the secret job: it comes from the same tagged master commit the owner approves (same trust as the workflow file); it pins the signing fingerprint itself, keeps the passphrase on a pipe, never echoes it, no `set -x`.
- Release window: `gh release create` with files creates a draft, uploads, then publishes, so latest/download never points at a release without InRelease. A rerun uses `upload --clobber` (not atomic; a client in that instant gets a hash mismatch and succeeds on its next update).
- Restart: postinst does not restart the user service (it never touches sessions; tests/deb proves no session tool is called), so README says: after `apt upgrade`, run `vr-telex-setup`.

## Tests
tests/apt/run.sh (60 checks, about 5 s, no root, no network): throwaway ed25519 keys (good + other) in temp GNUPGHOMEs (agents killed, dirs removed by the trap); stand-in .debs (or the real .deb given as argument = newest); the build script writes two "releases" (rel-old, rel-new) holding the .deb + another file; checks outputs, bare Filename, SHA256 of the .deb in Packages, Packages.gz == Packages, Release SHA256 + size of both indexes, only those two listed, no Valid-Until, Architectures, Date, both signatures with gpgv, InRelease text == Release, armored Release.gpg, passphrase not in output; refusals (dir unchanged): other package, name/version mismatch, missing .deb, no APT_GPG_KEY, unpinned key, key not in GNUPGHOME, wrong passphrase, no passphrase (agent killed first). Loopback server imitating GitHub (above); apt-get in a throwaway apt root (APT_CONFIG, Dir, own dpkg status file, amd64) with the packaged .sources where only the host and the Signed-By path are swapped: update clean (no W/E lines), InRelease fetched through both redirects, candidate = latest; status file with the old version installed (+ the newest version's Depends as installed): `apt-get -s upgrade` has nothing to do while latest == installed; latest switched to rel-new -> update clean, policy Installed old / Candidate new, `apt-get -s upgrade` shows `Inst vr-telex [old] (new ...)`; `apt-get download` gives the identical .deb through the latest/download redirect. Refused: keyring file missing, no Signed-By, other key, Packages changed (unexpected size), InRelease changed (BADSIG), no signatures (not signed), .deb changed (download hash mismatch); release.yml calls the script and uploads the 5 files.
Red: qa-artifacts/B3/red.log (script missing); run2.log (workflow checks red before the workflow change). Mutation: qa-artifacts/B3/mutate.log, 8 of 9 killed (no-pin-check, no-release-gpg, valid-until, unsigned-probe, filename-dot (caught by the script's own check), postrm-keeps-source, postinst-no-source, postinst-overwrites); release-lists-deb survived as an equivalent mutant (apt-ftparchive release never hashes .deb files).
Entry paths (BASE-23): first install via vr-telex-install.sh / apt install ./deb (postinst writes the source: tests/deb install), upgrade by apt (tests/apt upgrade plan + tests/deb upgrade lifecycle), upgrade by vr-telex-update (unchanged; tests/get PASS), remove / purge (tests/deb).

## Commands run (final, trimmed)
```
$ ( cd /home/rainy/DEV/vr-telex && $TEAM_BIN/run-heavy.sh bash tests/apt/run.sh )      # final-apt.log
ok    apt-get -s upgrade upgrades vr-telex 0.0.1~test-1 -> 0.0.2-1
ok    keyring file missing: apt-get update is refused
ok    a .deb changed after signing is refused at download (hash mismatch)
PASS                                   (60 ok, 0 FAIL)
$ $TEAM_BIN/run-heavy.sh bash tests/apt/run.sh <scratch>/vr-telex_0.1.2-1_amd64.deb   # run-realdeb.log
newest version: 0.1.2-1 ... PASS       (60 ok)
$ VR_TELEX_DEB_STRICT=1 $TEAM_BIN/run-heavy.sh bash tests/deb/run.sh                 # final-deb.log
package: /tmp/vr-telex-deb-test.XXXX/out/vr-telex_0.1.2-1_amd64.deb
ok    keyring holds one key, the release key 2C30E91F97E5A566BEFF373736C30B9165329B85
ok    remove: postrm remove deletes the source, even an edited one
PASS                                   (93 ok, 0 FAIL)
$ bash tests/get/run.sh                                                               # final-get.log
PASS                                   (130 ok, 0 FAIL)
$ shellcheck -x tests/apt/run.sh packaging/apt/build-flat-repo.sh tests/deb/run.sh tests/get/run.sh packaging/deb/postinst packaging/deb/postrm
rc 0   (workflow run blocks extracted with PyYAML: shellcheck -e SC2154 rc 0)
$ YAML parse of release.yml, test.yml -> yaml ok
$ cargo fmt --check && cargo clippy --workspace --all-targets --locked -- -D warnings   # guard.log
Finished `dev` profile ... rc 0
```

## Deviations
- Source file written by postinst instead of shipped under /etc (reason above, measured).
- tests/get/run.sh (not in the row's files): its README assertion forbade the words `sources.list` and `keyrings`, which D-APT-3 makes true; narrowed to the GitHub Pages repo (github.io|gh-pages). Revert if the leader prefers a README without those paths.
- test.yml: besides the test step, apt-utils install and the shellcheck list (the test needs apt-ftparchive; the new scripts are linted).
- packaging/apt/build-flat-repo.sh lives in packaging/apt (named in the brief; not in the row's file list).
- packaging/get/RELEASING.md updated (renewal must regenerate the keyring; apt rejects expired-key signatures).

## Out-of-scope noticed
- apt rejects signatures by an expired key (gpgv does not): the key expires 2029-11-26; a release carrying the renewed keyring must ship before then (RELEASING.md says so).

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| signing with the pinned key, passphrase pipe | 2e1e6cb:tools/apt-repo/build.sh, release.yml | reused the pinned-key check, probe-sign and sign() pattern; pool/gh-pages parts dropped |
| throwaway apt root, keys, loopback server | 2e1e6cb:tests/apt/run.sh, tests/get/run.sh | reused key generation, apt.conf, update_ok/update_refused, server start; server extended with GitHub-like redirects |
| maintainer-script sandbox | tests/deb/run.sh run_script | extended with DPKG_ROOT |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| BASE-1 | pass | row files + the listed deviations (tests/get one assertion, packaging/apt script named in the brief, RELEASING.md) |
| BASE-2 | pass | source fields exactly as D-APT-3 (tests/deb "apt source: deb822 ..."); file location changed with a measured reason |
| BASE-3 | pass | red.log, run2.log; mutate.log 8/9 killed, survivor equivalent |
| BASE-4 | pass | Commands run above; qa-artifacts/B3/final-*.log, guard.log |
| BASE-5 | pass | tests via run-heavy.sh; test HTTP server stopped by stop_http/trap; no leftover /tmp/vr-telex-apt.*, /tmp/vr-telex-deb-test.*, /tmp/flat-repo.* |
| BASE-6 | pass | English, why-comments only |
| BASE-9 | pass | pinned fingerprint, passphrase on a pipe, no set -x, passphrase-not-in-output checks; signature and hash refusal tests |
| BASE-10 | pass | only tests/apt, tests/deb, tests/get + guard |
| BASE-11 | pass | no stash/checkout/restore; nothing deleted or moved |
| BASE-14 | pass | foreground through run-heavy.sh; no waits |
| BASE-15 | pass | only the test's own server (recorded pid) and its own gpg-agents |
| BASE-16 | pass | Reuse table; capabilities.md line |
| BASE-17 | pass | nothing installed |
| BASE-18 | pass | no agents started |
| BASE-19 | pass | Progress section |
| BASE-21 | pass | throwaway passphrase only; no real key touched; logs hold no secret |
| BASE-23 | pass | entry paths listed under Tests |
| BASE-24 | pass | no index or history command |
| BASE-25 | pass | guard rc 0 |
| BASE-32 | pass | D-APT-2 kept (install line, SHA256SUMS assets, no Pages); D-APT-3 implemented |
| BASE-38 | pass | no formatter run (cargo fmt --check only) |
| BASE-46 | pass | final runs after the last change |
| COST-1..20 | pass | heavy via run-heavy; no polling; scripts in qa-artifacts/B3; logs to files, counts in context; nothing left running |

n-a: BASE-7 (no commit) · BASE-8 (no dependency change) · BASE-48 (no real machine state changed or reported; no sudo, /etc untouched) · BASE-12, 13, 20, 22, 26-31, 33-37, 39-45, 47 (no other repo, no untracked deletion, no removal, no new names, no rewrite, no shared data, no third-party code, no browser, no containers, no target environment, no user rules for this area, no app scope, no runtime defect, no schema, no outward writes, no credentials, no test-runner settings, no access rules, no client fakes, ACs unchanged, no computed value).

## Fix round 1
Findings from 05_review_B3.md and `## QC B3` (05_qc_report.md). Evidence under qa-artifacts/B3/fix1/.

1. major README 0.1.1 users: fixed. README Update, after the apt command: "If you installed vr-telex 0.1.1 or older, run `vr-telex-update` once (see below): those versions do not add the apt source. From 0.1.2 on, apt updates vr-telex." tests/get check "README: 0.1.1 or older run vr-telex-update once" (grep -F of that sentence). Red: `git show HEAD:README.md | grep -cF` of the sentence = 0; green: get.log 132 ok.
2. medium flaky `| grep -q` under pipefail: fixed. Output is captured first, then grepped (here-string), and the producer's exit status is kept (`out=$(cmd) || return 1`):
   - tests/apt: policy_has/candidate_is/no_candidate/installed_old_candidate_new (apt-cache policy), plans_upgrade/nothing_to_upgrade (apt-get -s), lists_only_indexes (awk | grep -v | grep -q).
   - tests/deb: no_at_maintainer, has_dep (DEP_NAMES), summary_ok (no head), extended_ok, dirs_root_owned and no_etc (CONTENTS=$(dpkg-deb -c) once; the old `! dpkg-deb -c | ... | grep -q` could even pass falsely on SIGPIPE), keyring_binary (also requires a public key packet now).
   - tests/get: fetched (tail | grep -q).
   - Left as they are: `cmd | cmp -s -` (cmp reads to the end when the inputs are equal; an early exit means a mismatch, a failure either way) and pipelines without an early-exiting reader.
   The flake could not be reproduced on purpose (qc: 1 in 4 before). After the fix, tests/apt ran green 11 times in a row: apt-1..6.log and apt-final-1..5.log, each rc 0, 60 ok, PASS.
3. minor stale lists: documented. README: "Run `sudo apt update` right before `sudo apt upgrade`, as above: once a newer release is out, package lists read before it can make the download fail (`404 Not Found` or a hash mismatch), and another `sudo apt update` fixes that." tests/get check "README: apt update right before apt upgrade". The Filename stays the bare name (no versioned path).
4. low CWE-59 .dpkg-new symlink: fixed. Red first: a new tests/deb case plants `vr-telex.sources.dpkg-new` as a symlink to a victim file, then runs postinst configure. Before the fix: FAIL "... writes nothing through the symlink" and FAIL "... and still writes the packaged source" (fix1-deb-red.log, 2 failed). postinst now runs `rm -f "$SOURCE_FILE.dpkg-new"` before the cp. Green: deb.log, 96 ok, PASS (STRICT).
5. low CWE-362 re-run clobber: fixed in release.yml. On an existing release it lists the assets. If the .deb is already there, it downloads it and requires the same bytes as the build artifact; a different .deb gets `::error::... re-run only the publish job, or bump the version`, exit 1, and nothing is uploaded. Otherwise it uploads in three calls: .deb, script, SHA256SUMS(.asc), Packages, Packages.gz; then Release, Release.gpg; then InRelease, so InRelease never names a file that is not uploaded yet. Why no client sees a mismatch: with the same .deb, Packages and Packages.gz are the same bytes (apt-ftparchive output for the same .deb; gzip -9n), so the old and new InRelease hash them alike, and a client mixing old and new files still verifies. A first publish (`gh release create`) is unchanged.
   - Simulation: fix1/sim-publish.sh runs the step from release.yml (PyYAML) with a stub gh; output in sim-publish.log. new → create; re-run with the same .deb → download, then 3 uploads in order; re-run with a different .deb → rc 1 with the error and no upload; partial release without the .deb → 3 uploads.
   - RELEASING.md step 4: re-run only the publish job; a full re-run is refused; bump the version for a new build.

Files changed this round: README.md, tests/get/run.sh, tests/apt/run.sh, tests/deb/run.sh, packaging/deb/postinst, .github/workflows/release.yml, packaging/get/RELEASING.md.

Commands (trimmed):
```
$ for i in 1..6: run-heavy.sh bash tests/apt/run.sh   -> rc 0, 60 ok, PASS (x6)
$ for i in 1..5: run-heavy.sh bash tests/apt/run.sh   -> rc 0, 60 ok, PASS (x5, after the last edit)
$ VR_TELEX_DEB_STRICT=1 run-heavy.sh bash tests/deb/run.sh -> rc 0, 96 ok, PASS
$ bash tests/get/run.sh                                 -> rc 0, 132 ok, PASS
$ shellcheck -x tests/apt/run.sh tests/deb/run.sh tests/get/run.sh packaging/deb/postinst packaging/deb/postrm packaging/apt/build-flat-repo.sh -> rc 0
$ release.yml run blocks via PyYAML | shellcheck -e SC2154 -> rc 0 ; YAML parse release.yml test.yml -> ok
$ cargo fmt --check && cargo clippy --workspace --all-targets --locked -- -D warnings -> rc 0 (fix1/guard.log)
```
Not mine: /tmp/vr-telex-apt.yNHSZ3 (20:44, created after my runs, probably a qc run with VR_TELEX_APT_KEEP=1); left in place.

Rule rows touched: BASE-3 (red: fix1-deb-red.log, HEAD README grep 0), BASE-4 (logs above), BASE-9 (CWE-59 and CWE-362 closed), BASE-25 (guard rc 0), BASE-46 (final runs after the last edit). All still pass.
