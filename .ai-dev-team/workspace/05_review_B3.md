# Review B3 — apt upgrade updates vr-telex (D-APT-3)

Verdict: CHANGES_REQUESTED (one major, a README line). Security: SECURE for the scope asked (two low items).

Tools available: Read, Bash, Write, Skill, SendMessage, SubagentHandback.

## Findings

[major] README.md:55-60 — Update text does not tell 0.1.1 users that `apt upgrade` cannot reach them yet
Scenario: a user on 0.1.1 (installed with the script, no apt source) reads Update and runs `sudo apt update && sudo apt upgrade`. apt has no vr-telex source, so it reports nothing to upgrade. The user thinks they are up to date and never gets 0.1.2 or any later release. Only `vr-telex-update` (now shown as an "alternative") installs 0.1.2, and its postinst writes the source.
Fix: add one sentence before the apt command, e.g. "If you installed 0.1.1 or older, run `vr-telex-update` once; from 0.1.2 on, apt updates vr-telex." Optionally add the same line to the release notes in release.yml.

[minor] packaging/apt/build-flat-repo.sh:102 (design) — a candidate seen by `apt update` returns 404 once a newer release is published
Scenario: `apt update` sees 0.1.2 (Filename `vr-telex_0.1.2-1_amd64.deb`). 0.1.3 is published. A later `apt upgrade` without a new `apt update` asks for `latest/download/vr-telex_0.1.2-1_amd64.deb`. GitHub redirects that to the v0.1.3 assets, which do not hold that file, so apt fails with 404. The same thing happens if publishing switches "latest" between apt's InRelease fetch and its Packages.gz fetch (hash or size mismatch). Running `apt update` again fixes it, and the README command runs both steps together.
Fix: write one sentence in RELEASING.md (or README) saying "a failed fetch right after a release: run `sudo apt update` again". A versioned Filename (`../../download/v<ver>/<deb>`) would avoid the 404. That form is not verified with apt, so test it before using it.

[low] packaging/deb/postinst:24-26 — CWE-59: `cp` writes through a `.dpkg-new` that already exists as a symlink
Data path: an existing `/etc/apt/sources.list.d/vr-telex.sources.dpkg-new` symlink → `cp` (as root) writes the template into the link's target → `mv` installs the symlink as the source.
Exploit: only root can create entries in `sources.list.d`, so an attacker cannot set this up. This is hardening only.
Fix: `rm -f "$SOURCE_FILE.dpkg-new"` before the `cp`, or `install -m 0644 "$SOURCE_TEMPLATE" "$SOURCE_FILE.dpkg-new"` after that `rm`.

[low] .github/workflows/release.yml:207 — CWE-362: a full re-run with `upload --clobber` uploads a rebuilt .deb before its InRelease
Scenario: a full re-run of an already published tag rebuilds the .deb, and cargo-deb output is not byte-reproducible. The assets are replaced one at a time: the .deb first, InRelease last. In that window, `apt upgrade` gets a hash mismatch. It is transient and cannot install unverified bytes. Re-running only the publish job uses the same artifact, and then only Release, InRelease and Release.gpg change, which is harmless. B1 rated the clobber path; this only adds the apt side.
Fix: none required. Optionally, put the five index files in `files` before the .deb, or have RELEASING.md say to re-run only the publish job.

Checked and found no problem:
- postinst: only on `configure`. It does nothing on abort-*. It refuses an existing file or symlink (`-e`/`-L`), writes `.dpkg-new` and then `mv`, sets 0644, and keeps an edit (with a note). Every path is under `$DPKG_ROOT`.
- postrm: deletes on remove and purge (a symlink is unlinked, its target is left alone). Nothing happens on upgrade, failed-upgrade or abort-*.
- Upgrade from 0.1.1 to 0.1.2: the old postrm upgrade does nothing, then the new postinst configure writes the source.
- Keyring: used only through Signed-By, nothing in trusted.gpg.d, no `./etc` and no conffiles (tests/deb). The keyring equals the dearmored .asc.
- Publishing: gates are unchanged (environment apt-release, tag on master, pinned FPR). The script re-pins the key itself, keeps the passphrase on a pipe, has no `set -x`, verifies both signatures with the pinned key alone, and the job requires exactly 9 files. No new secret reaches the build job.
- Redirects: apt sends no credentials to the asset host. Freeze and replay (no Valid-Until) stay low, as already settled in A4/B1. apt never downgrades.
- tests/apt covers refusals for a missing keyring, another key, no Signed-By, and tampered Packages, InRelease and .deb.
- Key expiry (EXPKEYSIG) is documented in RELEASING.md.
- `vr-telex-update` and the install script are unchanged; SHA256SUMS still covers only the .deb and the script.

## Rule check B3
| Rule | Status | Evidence |
|---|---|---|
| D-APT-2 | pass | install line and SHA256SUMS flow unchanged; no Pages (tests/get "no GitHub Pages apt repository left") |
| D-APT-3 | pass | keyring /usr/share/keyrings/vr-telex.gpg + Signed-By; flat repo at releases/latest/download `./`; 5 signed assets; version 0.1.2 |
| D-APT-3 note (postinst, not conffile) | pass | postinst:19-30, postrm:52-56, tests/deb lifecycle + "control has no conffiles" |
| AC-4 | pass | contents list + control checks extended (tests/deb); postinst touches no session (stub calls empty) |
| AC-6 | pass | release.yml signs in publish job only, pinned actions, `contents: write` only in publish, secret not echoed |
| AC-7 (as amended by D-APT-2/3) | fail | Update/Remove match the maintainer scripts and vr-telex-setup; missing the 0.1.1 note (major above) |
| BASE-1 | pass | tests/get change narrowed to one assertion, declared |
| BASE-2 | pass | source fields exactly as in D-APT-3 |
| BASE-3 | pass | red.log; mutation 8/9, survivor equivalent |
| BASE-4 | pass | notes list final runs of apt/deb/get + guard |
| BASE-9 | pass | pin, passphrase pipe, signature refusals tested |
| BASE-16 | pass | reuse table; capabilities.md line |
| BASE-23 | pass | entry paths: script install, apt upgrade, vr-telex-update, remove/purge |

## Files read
- .github/workflows/release.yml — read
- .github/workflows/test.yml — read
- Cargo.toml, crates/vr-telex/Cargo.toml — read
- Cargo.lock — skipped (lockfile; diff is 6 workspace version bumps only)
- README.md — read
- packaging/deb/postinst, postrm, vr-telex.sources — read
- packaging/deb/vr-telex.gpg — skipped (binary; tests/deb proves equality with .asc)
- packaging/apt/build-flat-repo.sh — read
- packaging/get/RELEASING.md — read
- tests/deb/run.sh (diff), tests/get/run.sh (diff) — read
- tests/apt/run.sh — read (header, checks, server, source rewrite)
- .ai-dev-team/* (capabilities, tasks, decisions) — skipped (team files)

REVIEW_FAIL

## Re-check round 1

Scope: the round-1 diff of README.md, packaging/deb/postinst, .github/workflows/release.yml (publish step), packaging/get/RELEASING.md, tests/deb/run.sh, tests/get/run.sh, tests/apt/run.sh (rewritten checks); notes `## Fix round 1`; evidence in qa-artifacts/B3/fix1/.

Earlier findings:
- [major] README for 0.1.1 users: fixed. The Update section says "If you installed vr-telex 0.1.1 or older, run `vr-telex-update` once ... From 0.1.2 on, apt updates vr-telex." tests/get checks for that sentence.
- [minor] stale package lists give a 404: fixed as documentation. README now says "Run `sudo apt update` right before `sudo apt upgrade` ... another `sudo apt update` fixes that." tests/get checks for that sentence. Keeping the bare Filename is acceptable.
- [low] CWE-59 `.dpkg-new` symlink: fixed. postinst runs `rm -f "$SOURCE_FILE.dpkg-new"` before `cp`. The new tests/deb case plants a symlink to a victim file. It checks that the victim is unchanged and that the packaged source is still written. The red log shows that case failing before the fix.
- [low] CWE-362 re-run clobber: fixed. Can a client still see a mismatch?
  - With the same .deb bytes (the publish step enforces this with `cmp` against the downloaded asset), Packages and Packages.gz come out byte-identical: apt-ftparchive gives the same output for the same file, and the step uses `gzip -9n`. So the old and new InRelease list the same hashes, and any mix of old and new indexes verifies. Only the Date changes.
  - `--clobber` deletes an asset before uploading it again. While InRelease is missing, apt falls back to Release with Release.gpg, and those two were already uploaded as a matching pair. While Release or Release.gpg is being replaced, apt reads the old InRelease, which is still valid.
  - While the .deb or Packages.gz is missing, a client gets a 404 for a moment and can never install unverified bytes. The README sentence above covers that case.
  - A rebuilt .deb is refused before anything is uploaded.
  - So the remaining client effect is a transient fetch failure at most, never a verification failure.

Can the refusal wrongly block a legitimate re-run?
- A publish-only re-run reuses the artifact, so it is never refused.
- A full re-run with a rebuilt .deb is refused on purpose. RELEASING.md says to re-run only the publish job or to bump the version.

[minor] packaging/get/RELEASING.md (step 4) — the refusal also hits a release no user can see
Scenario: the first `gh release create` fails after the .deb was uploaded to its draft, and the build artifact expires (7 days) before anyone re-runs. The next full re-run is refused because the draft holds different .deb bytes, so the owner must bump the version even though nothing was ever published. (I have not checked that `gh release view <tag>` lists a draft; gh normally does.)
Fix: one line in RELEASING.md: "if the release is still a draft, or holds no InRelease yet, delete it with `gh release delete <tag>` (keep the tag) and re-run." This does not block.

Test changes (pipefail and `grep -q` capture):
- Every rewritten check keeps its producer's exit status (`out=$(cmd) || return 1`) and then greps a here-string. That is equal or stricter:
  - `no_at_maintainer` now fails when the field lookup fails.
  - `no_candidate` now fails when apt-cache policy fails; before, a failure counted as "no candidate".
  - `lists_only_indexes` now requires a non-empty list.
  - `keyring_binary` now also requires a public key packet.
- `dirs_root_owned` and `no_etc` read `dpkg-deb -c` once into CONTENTS, so the false pass under SIGPIPE is gone.
- `fetched` in tests/get keeps its meaning.
- No `cmd | grep -q` remains in the three test files.
- No check was dropped. tests/get only gained checks: it replaces the old "no apt repository left" assertion with the narrower one already accepted in round 0.

No new issue opened by the fix.

## Rule check B3 (round 1)
| Rule | Status | Evidence |
|---|---|---|
| AC-7 (as amended by D-APT-2/3) | pass | README Update: 0.1.1 note + apt update before upgrade; tests/get checks both sentences |
| D-APT-3 | pass | unchanged design; postinst hardening only |
| D-APT-3 note (postinst, not conffile) | pass | postinst rm-before-cp; tests/deb planted-symlink case |
| AC-6 | pass | publish gates unchanged; re-run refuses a different .deb; InRelease uploaded last |
| BASE-3 | pass | fix1-deb-red.log (2 FAIL before the fix); HEAD README grep 0 |
| BASE-4 | pass | fix1 logs: apt x11 PASS, deb 96 ok, get 132 ok, guard rc 0 |
| BASE-9 | pass | CWE-59 and CWE-362 closed |
| BASE-46 | pass | final runs after the last edit (apt-final-1..5) |

REVIEW_PASS
