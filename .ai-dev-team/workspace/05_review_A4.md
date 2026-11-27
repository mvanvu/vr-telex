# Review A4 — signed apt repo, local apt test, workflows, README apt section

Verdict: CHANGES_REQUESTED (1 major, 4 minor/low)

Tools used: Read, Bash (git diff, cat, grep, gpg --show-keys, shellcheck, git ls-remote), Write (this file only).

## Findings

[major / security medium] README.md:24-35 — CWE-494 the key fingerprint check does not take effect
Scenario: the apt code block runs `wget` of the key, `gpg --show-keys`, the source line, `apt update` **and** `apt install vr-telex` + `vr-telex-setup` as one paste. The text "check that `gpg --show-keys` prints this fingerprint, and stop if it does not" comes *after* the block. A user who pastes the block (the normal case) has installed and run the package before reading it. If mvanvu.github.io is compromised (key and repo served from the same origin), the check is the only defence, and it never applies.
Fix: split the block. Block 1: `install -d`, `wget`, then a check that stops by itself, e.g.
`gpg --show-keys --with-colons /etc/apt/keyrings/vr-telex.gpg | grep -qx 'fpr:::::::::2C30E91F97E5A566BEFF373736C30B9165329B85:' || { echo "vr-telex: wrong key, stopping" >&2; sudo rm -f /etc/apt/keyrings/vr-telex.gpg; false; }`
(or put the fingerprint text before a first block that ends at `gpg --show-keys`). Block 2: source line, `apt update`, `apt install`, `vr-telex-setup`.

[minor] tests/apt/run.sh:184 — `file:` source instead of a served repo (AC-5 wording)
Scenario: apt's `file` method reads the repo in place; the HTTP path (compressed index selection, Content-Length/redirect handling) is not exercised. Signature checking (InRelease via gpgv, signed-by, NO_PUBKEY, BADSIG, hash mismatch) runs the same for `file:` and the tests prove it, so the AC's intent — signature passes with the keyring, fails without — is met.
Judgement: acceptable evidence. Optional: `python3 -m http.server --bind 127.0.0.1 0` in the temp dir, killed by the trap, for one `apt-get update` round.

[low] tools/apt-repo/build.sh:95-103 — no `Valid-Until` in Release (CWE-294 freeze/replay)
Scenario: a mirror or MITM that can serve old signed metadata could hold users on an old version indefinitely. HTTPS on GitHub Pages limits this to a compromise of the origin. Releases are rare, so a Valid-Until would need a scheduled re-sign job; acceptable to leave as is — noted for the user's decision, not blocking.

[minor] packaging/apt/vr-telex.asc — key expires 2029-11-26; nothing documents renewal
Scenario: after that date `apt update` fails with EXPKEYSIG for every user. Fix: one line in the leader's user-steps / a maintainer note: extend expiry (`gpg --quick-set-expire`), re-export the public key to packaging/apt/vr-telex.asc, update the secret, publish a release (the fingerprint does not change).

[minor] tools/apt-repo/build.sh:49-66,84-85 — two inputs with the same file name in one call
Scenario: `build.sh a/vr-telex_1_amd64.deb b/vr-telex_1_amd64.deb out` with different bytes: both pass the pool check (the name is not yet in the pool), the second `cp` overwrites the first. Not reachable from release.yml (one .deb). Fix: reject duplicate basenames in the validation loop.

## Deviations judged
- Binary `vr-telex.gpg` beside `.asc`: acceptable. apt reads a binary keyring in `signed-by`, it avoids a `gpg --dearmor` step, and both are exported from the same key; the test verifies with the published `.gpg` and checks the `.asc` fingerprint.
- `file:` source: acceptable (see minor above).
- Two extra README lines (one install kind per user; vr-talex note mentions vr-telex-setup): acceptable, accurate, consistent with AC-2; `vr-telex-setup --remove` exists in packaging/vr-telex-setup:40.

## Security checks done (no finding)
- packaging/apt/vr-telex.asc: public key only (no PRIVATE block), fpr 2C30E91F97E5A566BEFF373736C30B9165329B85, RSA 4096 [SC], no subkeys.
- Action SHAs checked with `git ls-remote` against github.com/actions: checkout v6.1.0 = d23441a4…, upload-artifact v7.0.2 = cf430e03…, download-artifact v8.0.2 = 9000827c… (lightweight tags, commit SHAs) — all match.
- No `${{ }}` in any `run:` block; tag validated by regex before reaching `$GITHUB_OUTPUT`.
- Permissions: top level and build `contents: read`; `contents: write` only in `publish`; secrets only in the publish signing step; build job checkout `persist-credentials: false`.
- Secret: imported via builtin `printf |` (no argv), unset after import; passphrase on fd 0 via builtin printf; no `set -x`; GNUPGHOME mktemp -d under RUNNER_TEMP with umask 077, trap kills agent and removes it.
- Signing key forced to the committed fingerprint (release.yml:119), so a wrong secret fails.
- Older .debs kept (gh-pages worktree, pool not cleaned); a changed file under a published name refused before any write (build.sh:63); `gh release upload --clobber` is reached only after build.sh accepted the .deb, so it cannot replace a published version with different bytes.
- shellcheck on build.sh and run.sh: clean.

## Files read
- tools/apt-repo/build.sh — read
- tests/apt/run.sh — read
- .github/workflows/release.yml — read
- .github/workflows/test.yml — read
- packaging/apt/vr-telex.asc — read (gpg --show-keys)
- README.md (diff) — read
- .ai-dev-team/capabilities.md (diff) — read
- packaging/vr-telex-setup — grep for `--remove` only (contract the README uses; A2's file)

## Rule check A4
| Rule | Status | Evidence |
|---|---|---|
| AC-5 script builds pool/dists repo with apt-ftparchive | pass | build.sh:91-103 |
| AC-5 signs InRelease + Release.gpg, includes public key | pass | build.sh:107-114; run.sh:137-148 |
| AC-5 runnable locally with throwaway key | pass | run.sh:63-74 |
| AC-5 apt-get in throwaway root, no sudo, policy | pass | run.sh:151-193 (APT_CONFIG + Dir) |
| AC-5 passes with keyring, fails without | pass | run.sh:185, 196-203 |
| AC-5 "serves" the repo | pass (deviation accepted) | `file:` source; see minor |
| AC-6 tag v*, test, build .deb | pass | release.yml:11-60 |
| AC-6 sign with APT_GPG_PRIVATE_KEY (+passphrase) | pass | release.yml:99-131 |
| AC-6 gh-pages keeps older versions | pass | release.yml:125-131, build.sh pool kept |
| AC-6 attach .deb to Release | pass | release.yml:143-155 |
| AC-6 pinned actions (full SHA, verified) | pass | ls-remote match |
| AC-6 least permissions | pass | release.yml:15-25,80-81 |
| AC-6 secret never echoed | pass | no echo/set -x; pipe only |
| AC-6 test workflow on push/PR | pass | test.yml |
| AC-7 keyring path, signed-by, apt install, vr-telex-setup | pass | README.md:24-31 |
| AC-7 update, remove, from source, vr-talex note | pass | README.md:52-66, 67+, 91-99 |
| SEC README safe for users (fingerprint check) | fail | major finding above |
| SEC no `${{ }}` in run | pass | grep |
| SEC temp GNUPGHOME trap | pass | release.yml:109-115; run.sh:50-60 |
| SEC refuse overwrite of published file | pass | build.sh:63-65; run.sh:239 |
| SEC no private key in repo | pass | .asc public only, fpr matches |

REVIEW_FAIL

## Re-check round 1

Verdict: APPROVED. All earlier findings are fixed or accepted, and the fix opened nothing new. Valid-Until (low) stays with the user, as agreed.

Read: README.md diff, tools/apt-repo/README.md (new), tools/apt-repo/build.sh (validation loop), tests/apt/run.sh (HTTP round, trap, duplicate-name case), notes `## Fix round 1`, qa-artifacts/A4/keycheck/result.txt, fix1-red.log, fix1-green.log (47 ok, PASS). shellcheck on both scripts: clean.

1. **README key check (README.md:24-31): fixed.**
   - The whole `fpr` output must equal the single expected line. A keyring holding the right key plus another key gives two `fpr` lines, so it is refused. keycheck/result.txt shows `combined rc=1 file-left=no`, and the same for a throwaway key and a garbage file.
   - A failed download (empty or missing file) is refused the same way.
   - After a refusal the keyring file is deleted, so a later `apt update` on block 2 has no key for a signed-by source and refuses the repo ("not signed"). `apt install vr-telex` then has no candidate, so block 2 cannot succeed.
   - The two blocks are separate and the stop text comes before block 1.
   - Note (not a finding): the check expects exactly one fingerprint. A future signing subkey would need this line updated. The renewal doc only extends the expiry, so it adds no subkey.
2. **Duplicate file names (build.sh:49-71): fixed.**
   - The `SEEN` map is checked inside the validation loop, before any write, so the same name with different bytes is refused. Identical duplicates are still accepted.
   - Red then green: fix1-red.log FAIL, fix1-green.log ok. The test also checks that the site is unchanged.
3. **Renewal doc (tools/apt-repo/README.md:26-41): correct.**
   - `--quick-set-expire <fpr> 3y` extends the primary key without changing the fingerprint, so release.yml and the README check still pass.
   - The steps re-export the .asc, update the secret through a pipe, and republish the key on gh-pages through a release.
   - Users must fetch the key again, because apt's copy keeps the old expiry and gives EXPKEYSIG. The top-level README says this in Update.
4. **HTTP round (tests/apt/run.sh:211-240): fixed, safe.**
   - Only localhost: `ThreadingHTTPServer(("127.0.0.1", 0))` runs with `python3 -I`. Proxy variables are removed from apt's environment and `Acquire::http::Proxy "DIRECT"` is set.
   - No sleep loops: the port is read once with `read -t 20`.
   - No leaked process: the server's pid comes from `$!` of the process substitution, and `exec` makes it python itself. `stop_http` kills it, waits for it and closes the fd, both after the round and in the EXIT trap (cleanup:61), so the `die` path is covered too.
   - The four HTTP checks are ok in fix1-green.log.

## Rule check A4 (round 1)
| Rule | Status | Evidence |
|---|---|---|
| AC-5 (serves repo, keyring passes / fails without) | pass | run.sh:211-240 HTTP round + file: round; fix1-green.log |
| AC-6 | pass | unchanged this round |
| AC-7 | pass | README.md two blocks, update/remove, from source |
| SEC README safe for users (fingerprint check) | pass | exact single-fpr comparison; keycheck/result.txt (4 inputs) |
| SEC refuse overwrite / duplicate inputs | pass | build.sh:63-71; fix1-red → fix1-green |
| SEC key renewal documented | pass | tools/apt-repo/README.md:26-41 |
| SEC no process leak, localhost only, no sleep loop | pass | run.sh:50-71, 174-185, 224-228 |
| SEC no private key in repo / no `${{ }}` / trap cleanup | pass | unchanged |

REVIEW_PASS
