# A4 Signed apt repo script + local apt test + release workflow + README apt section

## Progress
- read: spec AC-5..7, plan Repo + CI (A4), A3 notes, README, profile, capabilities
- red: tests/apt/run.sh run1 3 FAIL (test helper bug: `build` not visible in bash -c) -> rewritten with functions
- code: tools/apt-repo/build.sh (validate, probe-sign before writing, pool kept, indices, InRelease/Release.gpg, key export); tests/apt/run.sh
- green: run3 PASS 42 ok (qa-artifacts/A4/run3.log); mutations caught (qa-artifacts/A4/mutation.log, mutation2.log)
- key: packaging/apt/vr-telex.asc copied (public only, fpr checked)
- code: .github/workflows/test.yml, release.yml; README install section; YAML parse + shellcheck of run blocks
- guard + final run: guard rc 0, tests/apt/run.sh PASS (42 ok), .deb-argument path PASS (qa-artifacts/A4/final.log, argpath.log)

Tools available: Bash, Read, Edit, Write, Skill, ToolSearch, Artifact, Agent (unused, BASE-18), SubagentHandback. Present: dpkg-deb, apt-ftparchive, apt-get, gpg 2.4.4, gpgv, shellcheck, PyYAML 6.0.1. cargo-deb not needed locally (stand-in .debs). Missing: none required. actionlint / zizmor are not installed (not requested).

## Summary
- Files changed / added:
  - tools/apt-repo/build.sh (new) — `build.sh <deb>... <out-dir>`, env APT_GPG_KEY (required), GNUPGHOME, APT_GPG_PASSPHRASE (optional). Validates every .deb first (name `vr-telex_<ver>_amd64.deb`, Package/Architecture/Version via `dpkg-deb -f`; a different file under a name already in the pool is refused), checks the secret key exists and probe-signs before writing anything, copies into `pool/main/v/vr-telex/` (existing pool kept), `apt-ftparchive packages` -> `dists/stable/main/binary-amd64/Packages{,.gz}`, `apt-ftparchive release` (Origin/Label vr-telex, Suite/Codename stable, Components main, Architectures amd64), `InRelease` (clearsign) + `Release.gpg` (detached, armored), SHA512 digest, exports `vr-telex.asc` and binary `vr-telex.gpg`. gpg always runs `--batch --pinentry-mode loopback --passphrase-fd 0` with the passphrase on a pipe: never a prompt, never on a command line.
  - tests/apt/run.sh (new) — see Tests.
  - .github/workflows/test.yml (new) — push to master + pull_request; `contents: read`; checkout with `persist-credentials: false`; fmt, clippy -D warnings, cargo test, shellcheck + tests/apt/run.sh. No cargo-deb build (kept cheap).
  - .github/workflows/release.yml (new) — tag `v*`. Job `build` (contents: read, no secrets): tools, fmt/clippy/test, `cargo install cargo-deb --locked --version 3.8.0`, `cargo deb -p vr-telex --locked`; tag must be vMAJOR.MINOR.PATCH and the .deb must be `vr-telex_<tag without v>-1_amd64.deb`; `VR_TELEX_DEB_STRICT=1 bash tests/deb/run.sh <deb>`; `bash tests/apt/run.sh <deb>`; upload artifact. Job `publish` (needs build; `contents: write` only here; concurrency group publish-apt, no cancel): imports APT_GPG_PRIVATE_KEY into a mktemp GNUPGHOME under RUNNER_TEMP (umask 077; trap kills its gpg-agent and removes it), key fed by `printf | gpg --import`, variable unset right after; signing key = fingerprint read from the committed packaging/apt/vr-telex.asc (a secret for another key fails); gh-pages as a worktree (orphan on first release); build.sh adds the .deb (older ones stay); `.nojekyll`; commit + push gh-pages; then `gh release create` (or `gh release upload --clobber` when the release exists) with the .deb. Actions pinned by commit SHA: actions/checkout d23441a48e516b6c34aea4fa41551a30e30af803 (v6.1.0), actions/upload-artifact cf430e030ddbb5b0abf93d22962f4752f3646cd9 (v7.0.2), actions/download-artifact 9000827ccba6bdab643e8b6fd33ac0654aef8333 (v8.0.2) — from `git ls-remote --tags` of the official repos (lightweight tags, so commit SHAs). No `${{ }}` inside any `run:` block (values pass through `env:`).
  - packaging/apt/vr-telex.asc (new) — public key copied from the leader's GNUPGHOME; contains no PRIVATE block; fingerprint 2C30E91F97E5A566BEFF373736C30B9165329B85 (RSA 4096, [SC], expires 2029-11-26). The private key was never read or used.
  - README.md — Install section only: "With apt" (keyring via `sudo wget -qO /etc/apt/keyrings/vr-telex.gpg https://mvanvu.github.io/vr-telex/vr-telex.gpg`, `gpg --show-keys` + the fingerprint to compare, `signed-by` source line with arch=amd64, `apt update`, `apt install vr-telex`, `vr-telex-setup`), Update (`apt upgrade` + `systemctl --user restart vr-telex.service`), Remove (`vr-telex-setup --remove` first, then `apt remove`; how to drop source + keyring); "From source" kept verbatim plus one line (one install kind per user); vr-talex note kept, now says `./install.sh` and `vr-telex-setup` both migrate (AC-2).
  - .ai-dev-team/capabilities.md — one line.
- Tests added: tests/apt/run.sh (42 checks, ~5 s). Stand-in .debs built with dpkg-deb, no cargo build: the test proves the repository (layout, indices, signatures, keyring, kept old versions, refusals), not the package contents (tests/deb/run.sh covers those). With a .deb argument (CI passes the real cargo-deb output) that file is published as the newest version. Throwaway ed25519 keys (one passphrase-protected, one other key) in temp GNUPGHOMEs; their agents are stopped and the temp dir removed by a trap. apt runs from a throwaway root via APT_CONFIG (Dir, Dir::State::status, Dir::Etc::Parts, Dir::Bin::Methods=/usr/lib/apt/methods, Debug::NoLocking, APT::Sandbox::User=$USER) with a `file:` source — no sudo; the host's apt state and trusted keys are never read or written.
  - Checks: two builds over the same site keep both versions; Release fields; gpgv verifies InRelease and Release.gpg; InRelease text == Release; .asc is the signing key with no secret material; passphrase absent from build output; `apt-get update` with signed-by keyring: rc 0 and no W/E/Err lines; `apt-cache policy` candidate = newest, old version still listed; `apt-get download` returns the identical .deb; without keyring: refused (NO_PUBKEY / not signed) and no candidate; with another key: refused, no candidate; Packages changed after signing: refused (hash mismatch); InRelease changed after signing: refused; build.sh refuses a changed file under a published name / a non-vr-telex package / name-version mismatch / no APT_GPG_KEY / key not in GNUPGHOME / wrong passphrase / missing passphrase — each leaving the site byte-identical; the identical file is accepted again (rerun of a release).

## Commands run (trimmed)
```
$ bash tests/apt/run.sh                                   # run1 (red: test helper bug)
_: line 1: build: command not found
FAIL    ... with a reason
FAIL  build.sh refuses a package that is not vr-telex
FAIL  build.sh refuses a file name that does not match the version
FAIL: 3 check(s) failed                       -> helpers rewritten as functions
$ bash tests/apt/run.sh                                   # run2
FAIL  InRelease carries the same text as Release   -> compare via gpgv --output -, no default GNUPGHOME
$ bash tests/apt/run.sh                                   # final (qa-artifacts/A4/final.log)
ok    apt-get update with signed-by keyring passes the signature check
ok    apt-cache policy: candidate is the newest version (0.0.1-1)
ok    apt-cache policy: old version 0.0.0~test-1 still listed
ok    apt-get download fetches the newest .deb unchanged
ok    apt-get update without the keyring is refused (NO_PUBKEY, not signed)
ok      ... and apt offers no vr-telex
ok    apt-get update with another key is refused
ok    a Packages index changed after signing is refused (hash mismatch)
ok    an InRelease changed after signing is refused (bad signature)
ok    build.sh with a wrong passphrase fails without a prompt (site unchanged)
...
PASS            (42 ok, rc 0)
$ bash tests/apt/run.sh <stand-in vr-telex_0.1.0-1_amd64.deb>     # argpath.log
newest version: 0.1.0-1 ... ok apt-cache policy: candidate is the newest version (0.1.0-1) ... PASS
# mutations on a temp copy (mutation.log, mutation2.log):
InRelease not signed        -> FAIL InRelease exists / verifies / same text (rc 1)
pool guard off + no probe   -> FAIL refuses a changed file...; FAIL wrong passphrase ... (rc 1)
$ shellcheck tools/apt-repo/build.sh tests/apt/run.sh     -> rc 0, no output
$ shellcheck on the run: blocks extracted from both workflows -> rc 0
$ python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' .github/workflows/{test,release}.yml
release.yml ok ['build', 'publish'] / test.yml ok ['test']
$ grep for ${{ in run: blocks -> none; grep 'set -x' -> only the two "never add set -x" comments
$ cargo fmt --check && $TEAM_BIN/run-heavy.sh cargo clippy --workspace --all-targets --locked -- -D warnings
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.11s     guard_rc=0
```

## For the leader: user steps (none done by me)
1. Secret (exported from the dedicated GNUPGHOME and piped, never written to disk):
   `gpg --homedir /home/rainy/.local/share/vr-telex-apt-gnupg --armor --export-secret-keys 2C30E91F97E5A566BEFF373736C30B9165329B85 | gh secret set APT_GPG_PRIVATE_KEY --repo mvanvu/vr-telex`
   Only if the key has a passphrase: `gh secret set APT_GPG_PASSPHRASE --repo mvanvu/vr-telex` (it prompts; never pass it as an argument).
2. Pages, after the first release run has pushed gh-pages: Settings > Pages > Build and deployment: Source "Deploy from a branch", Branch `gh-pages`, folder `/ (root)`; or `gh api -X POST repos/mvanvu/vr-telex/pages -f 'source[branch]=gh-pages' -f 'source[path]=/'`. URL: https://mvanvu.github.io/vr-telex
3. Workflow permissions: the `publish` job asks for `contents: write` itself; this works unless the repo/org setting forbids it (Settings > Actions > General > Workflow permissions).
4. Tag: the workspace version must match (tag v0.1.0 -> vr-telex_0.1.0-1_amd64.deb); then create and push the tag.
5. Not verifiable locally: the workflows have not run on GitHub; the first run is the proof. Rerunning the whole workflow rebuilds the .deb; if cargo-deb output is not byte-identical, build.sh refuses it (by design: a published version never changes) — rerun only the failed `publish` job, which reuses the artifact.

## Deviations from the plan
- build.sh also publishes a binary keyring `vr-telex.gpg` beside `vr-telex.asc`, so the README needs no `gpg --dearmor` step (wget only; curl is not on a stock Ubuntu desktop).
- The local apt test uses a `file:` source from the temp dir instead of an HTTP server: apt still runs the full signature path, and no server process has to be managed.
- README "From source" gained one sentence (one install kind per user) and the vr-talex note mentions `vr-telex-setup` (AC-2 says both kinds migrate).

## Out-of-scope issues noticed
- README "Requirements" still says "then run `./install.sh` again" and "## Uninstall" covers only `./uninstall.sh`; the apt path is covered in Install > Remove. A wording pass after A2 settles vr-telex-setup's messages may help.
- README "Development" does not list `bash tests/deb/run.sh` / `bash tests/apt/run.sh` (outside my section).
- A gpg-agent for /home/rainy/.local/share/vr-telex-apt-gnupg is running (pid 134039) — not started by me (I never used that homedir). The leader may stop it with `gpgconf --homedir /home/rainy/.local/share/vr-telex-apt-gnupg --kill gpg-agent`.
- `cargo test --workspace` in CI needs `dbus-daemon` (installed in both workflows); other runner gaps, if any, show on the first run.
- tests/install/stubs/systemctl shows as modified — not mine (A2).

## Reuse
| Needed | Looked in | Result |
|---|---|---|
| test output helpers (ok/bad/check, temp dir + KEEP env) | tests/deb/run.sh | same pattern and naming (VR_TELEX_APT_KEEP); not sourced, A3's file is not a library |
| package test in CI | tests/deb/run.sh, A3 notes | reused: CI runs `tests/deb/run.sh <deb>` with VR_TELEX_DEB_STRICT=1 |
| repo builder / apt test | capabilities.md, `ls tools tests` | none existed; new (added to capabilities.md) |

## Rule compliance
| Rule | Status | Evidence |
|---|---|---|
| AC-5 | pass | tools/apt-repo/build.sh; tests/apt/run.sh final.log: signed-by update passes, no keyring / other key refused, gpgv InRelease + Release.gpg, .asc exported, no sudo |
| AC-6 | pass (static) | .github/workflows/release.yml: tag v*, test -> .deb -> strict deb test -> apt test -> sign with APT_GPG_PRIVATE_KEY (+APT_GPG_PASSPHRASE) -> gh-pages keeps pool -> GitHub Release; SHAs pinned; contents: write only in `publish`; test.yml on push/PR. YAML parse + shellcheck of run blocks clean; first GitHub run is a user step |
| AC-7 | pass | README.md Install: keyring /etc/apt/keyrings/vr-telex.gpg, signed-by line, apt install vr-telex, vr-telex-setup, update, remove (setup --remove first), fingerprint, from source kept, vr-talex note kept |
| SEC key handling | pass | no `set -x` (grep); passphrase only on a pipe (build.sh `sign()`), test asserts it never appears in output; CI GNUPGHOME mktemp + trap (agent killed, dir removed), umask 077; secret only in the `publish` signing step env, unset after import; throwaway keys only in tests; real private key never touched; no `${{ }}` in run blocks |
| BASE-1 | pass | only row files + capabilities.md line + notes |
| BASE-2 | pass | plan layout dists/stable/main/binary-amd64, pool/main/v/vr-telex, InRelease + Release.gpg, <out>/vr-telex.asc |
| BASE-3 | pass | run1/run2 red before green; mutations caught (mutation*.log) |
| BASE-4 | pass | final.log, argpath.log, mutation*.log in qa-artifacts/A4 |
| BASE-9 | pass | see SEC row; build.sh validates every input before writing |
| BASE-10 | pass | ran only tests/apt/run.sh + guard; tests/deb not rerun (unchanged) |
| BASE-11 | pass | no stash/checkout/restore, no tracked file moved or deleted |
| BASE-13 | pass | temp dirs removed (`ls /tmp` shows no vr-telex-apt.*); proto/mut dirs in qa-artifacts deleted |
| BASE-14 | pass | all commands foreground, < 10 s |
| BASE-15 | pass | test trap kills only its own GNUPGHOMEs' agents; leader's agent left running |
| BASE-16 | pass | Reuse table |
| BASE-17 | pass | nothing installed; all tools present; cargo-deb install only inside CI |
| BASE-18 | pass | no agents started |
| BASE-19 | pass | notes created first, progress lines above |
| BASE-21 | pass | no secret in notes/artifacts; test passphrase random per run, never logged |
| BASE-22 | pass | tests/apt/run.sh mirrors tests/deb/run.sh (ok/FAIL/PASS, VR_TELEX_*_KEEP) |
| BASE-23 | pass | both entry paths tested: no argument (stand-in) and .deb argument (argpath.log) |
| BASE-24 | pass | nothing staged or committed (`git status`: ?? / M only) |
| BASE-25 | pass | guard `cargo fmt --check && clippy -D warnings` rc 0 |
| BASE-34 | pass | action SHAs from the official github.com/actions repos via git ls-remote |
| BASE-35 | pass | repo files in English |
| BASE-38 | pass | shellcheck only on my files; no formatter run on others |
| BASE-46 | pass | final.log taken after the last code change |
| COST-1 | pass | guard clippy via run-heavy.sh; apt test is light (~5 s) |
| COST-3 | pass | no polling |
| COST-5 | pass | temp dirs and agents cleaned by trap |
| COST-8 | pass | files written whole, edits batched |
| COST-9 | pass | nothing left running (agents of my test homes killed; only the leader's agent remains) |
| COST-10 | pass | related set: tests/apt/run.sh (the only test that uses build.sh); workflows have no local test |
| COST-13 | pass | scratch in qa-artifacts/A4 and the session scratchpad |

n-a: BASE-5 (no heavy test beyond the guard) · BASE-6 (all English) · BASE-7 (no commit) · BASE-8 (no Cargo dependency change) · BASE-12 (no other repos) · BASE-20 (nothing removed) · BASE-26 (no rewrite) · BASE-27, BASE-30 (no shared data) · BASE-28 (no third-party code edited) · BASE-29, BASE-40, BASE-41 (no browser, no outward writes, no credentials) · BASE-31 (no containers) · BASE-32 (decisions followed: real public key copied, URL mvanvu.github.io/vr-telex) · BASE-33 (no deploy target touched) · BASE-36, BASE-37 (no app runtime change, no defect) · BASE-39 (no schema) · BASE-42 (no test settings files) · BASE-43 (no access fix) · BASE-44 (no fakes of other systems) · BASE-45 (criteria from the spec) · BASE-47 (the fingerprint is read from packaging/apt/vr-telex.asc by release.yml; README states it for users) · BASE-48 (no state assumed) · COST-2, COST-4, COST-6, COST-7, COST-11, COST-12, COST-14, COST-15, COST-16, COST-17, COST-18, COST-19, COST-20 (no full suite, audit, browser, e2e, requests, CI wait, goldens, images)

## Fix round 1
Findings from .ai-dev-team/workspace/05_review_A4.md.

1. major (README key check runs after install): fixed. README.md Install > With apt is now two blocks. Block 1 creates /etc/apt/keyrings, downloads the key, then runs a check that stops on its own: `[ "$(gpg --show-keys --with-colons /etc/apt/keyrings/vr-telex.gpg 2>/dev/null | grep "^fpr")" = "fpr:::::::::2C30E91F97E5A566BEFF373736C30B9165329B85:" ] || { echo "vr-telex: wrong key, stopping" >&2; sudo rm -f /etc/apt/keyrings/vr-telex.gpg; false; }`. Block 2 adds the source line, then runs apt update, apt install and vr-telex-setup.
   - This differs from the reviewer's `grep -qx`: the whole fpr output must equal that single line, so a file holding the right key plus an attacker's key is also refused. With `grep -q`, apt would trust both keys.
   - After a refusal the keyring file is gone, so a pasted block 2 fails at `apt update` because the signed-by file is missing.
   - Proof: the README line was extracted as-is (qa-artifacts/A4/keycheck/readme-line.txt), with only the path changed to a copy and `sudo rm` changed to `rm`. It was run against the real key (packaging/apt/vr-telex.asc dearmored), a throwaway key, the real and throwaway keys combined, and a garbage file. Output (qa-artifacts/A4/keycheck/result.txt):
     ```
     right     rc=0 file-left=yes
     vr-telex: wrong key, stopping
     throwaway rc=1 file-left=no
     vr-telex: wrong key, stopping
     combined  rc=1 file-left=no
     vr-telex: wrong key, stopping
     garbage   rc=1 file-left=no
     ```
2. minor (same file name twice in one call): fixed. tools/apt-repo/build.sh checks every input in the validation loop against an associative array `SEEN` of names. The same name with different bytes stops the run with `given twice with different content` before anything is written. Identical duplicates are still accepted.
   - Red, then green. New check in tests/apt/run.sh: "build.sh refuses two different inputs with the same file name (site unchanged)".
     ```
     $ $TEAM_BIN/run-heavy.sh bash tests/apt/run.sh     # before the fix (qa-artifacts/A4/fix1-red.log)
     FAIL  build.sh refuses two different inputs with the same file name (site unchanged)
     FAIL: 1 check(s) failed                                                     rc=1
     $ $TEAM_BIN/run-heavy.sh bash tests/apt/run.sh     # after (qa-artifacts/A4/fix1-green.log)
     ok    build.sh refuses two different inputs with the same file name (site unchanged)
     PASS                                                     47 ok, rc=0
     ```
3. minor (no written key renewal procedure): fixed.
   - New maintainer doc tools/apt-repo/README.md covers build.sh usage, the layout, the signing key and "Renewing before it expires". The steps: extend the expiry in the key's GnuPG home (`--quick-set-expire <fpr> 3y`), re-export packaging/apt/vr-telex.asc, update the APT_GPG_PRIVATE_KEY secret through a pipe, publish a release, then users download the key again. The fingerprint does not change.
   - The top-level README Update paragraph says that `EXPKEYSIG` means the key was renewed: run the first block again.
   - User step 6 for the leader (a few months before 2029-11-26), with KEYHOME=/home/rainy/.local/share/vr-telex-apt-gnupg:
     ```
     gpg --homedir "$KEYHOME" --quick-set-expire 2C30E91F97E5A566BEFF373736C30B9165329B85 3y
     gpg --homedir "$KEYHOME" --armor --export 2C30E91F97E5A566BEFF373736C30B9165329B85 >packaging/apt/vr-telex.asc   # commit it
     gpg --homedir "$KEYHOME" --armor --export-secret-keys 2C30E91F97E5A566BEFF373736C30B9165329B85 | gh secret set APT_GPG_PRIVATE_KEY --repo mvanvu/vr-telex
     ```
     Then tag a release; the workflow republishes vr-telex.asc and vr-telex.gpg. Then tell users to rerun README block 1.
4. optional (HTTP round): done. tests/apt/run.sh starts a loopback-only `ThreadingHTTPServer` (python3 -I, port 0) through process substitution. It reads the port with `read -t 20` on the server's stdout, so there is no sleep or retry loop. Its pid is recorded, and `stop_http` (called after the round and from the trap) kills it, waits for it and closes the fd.
   - Proxy variables are removed from apt's environment, and apt.conf sets `Acquire::http::Proxy "DIRECT"`.
   - Four checks: update with keyring over HTTP, candidate, apt-get download identical, update without keyring refused. All are ok in fix1-green.log. After the run no python server is left (`pgrep` shows only my own shell).

Not changed: Valid-Until (goes to the user).

Commands (final code):
```
$ shellcheck tools/apt-repo/build.sh tests/apt/run.sh                 -> rc 0
$ $TEAM_BIN/run-heavy.sh bash tests/apt/run.sh                         -> 47 ok, PASS, rc 0 (fix1-green.log)
$ cargo fmt --check && $TEAM_BIN/run-heavy.sh cargo clippy --workspace --all-targets --locked -- -D warnings
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.03s       guard_rc=0
```
Files changed this round: README.md (Install > With apt split into two blocks + the EXPKEYSIG line), tools/apt-repo/build.sh (duplicate names), tools/apt-repo/README.md (new), tests/apt/run.sh (duplicate-name case, HTTP round). Nothing staged; nothing left running.

Rule rows touched: AC-5 pass (plus the HTTP round) · AC-7 pass (the check now runs before install and stops by itself) · SEC key handling pass (exact single-key check proven on 4 inputs) · BASE-3 pass (fix1-red then fix1-green) · BASE-4 pass (keycheck/result.txt, fix1-*.log) · BASE-25 pass (guard rc 0) · COST-9 pass (HTTP server stopped by stop_http/trap, test agents killed).

DONE
