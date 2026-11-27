# Review B1 (code + security) — APPROVED / SECURE with low notes

Tools available: Bash, Read, Write (this report only), Skill, SendMessage, SubagentHandback.

## Files read
- packaging/get/vr-telex-install.sh — read (line by line)
- packaging/get/embed-key.sh — read
- packaging/get/RELEASING.md — read
- tests/get/run.sh — read (harness, key/README checks; case list via notes + grep)
- .github/workflows/release.yml, .github/workflows/test.yml — read (diff + surrounding gate)
- README.md, Cargo.toml, crates/vr-telex/Cargo.toml, tests/deb/run.sh — read
- .ai-dev-team/capabilities.md, decisions.md (D-APT-2) — read
- tools/apt-repo/**, tests/apt/run.sh — deleted; references grepped (only RELEASING.md step 4, the intended one-time gh-pages cleanup)
- Cargo.lock — skipped (generated; 6 workspace crates 0.1.0 -> 0.1.1 per notes/diff stat)

Probes (qa-artifacts/B1-review/, throwaway key, removed): gpgv given an inline-signed or clear-signed message as the "detached" signature: `not a detached signature`, rc 2 — a signed message of other content cannot stand in. `shellcheck packaging/get/vr-telex-install.sh` rc 0. Host sysctl: fs.protected_regular=2, fs.protected_symlinks=1.

Checked and fine: root refused before any download; arch check before download; seams (`http://127.0.0.1:8080@evil/` -> port `8080@evil` -> refused; test key only with loopback); gpgv `--keyring` + empty GNUPGHOME; SHA256SUMS parsing (strict 64-hex, two spaces, no path, one entry, duplicates refused); sha256 before `dpkg-deb -f`; temp dir 0700 until the last checks, owner-only writable at sudo time, absolute path to apt; dpkg replaces /usr/bin/vr-telex-update by rename, so the running update is not corrupted; traps clean up on HUP/INT/TERM; publish: environment apt-release + master-ancestor gate kept, persist-credentials false, secret piped then unset, pinned fingerprint and secret-key presence checked, `--local-user "$FPR!"`, self-verify with gpgv + `sha256sum --strict -c`; no `${{ }}` in run blocks; test.yml runs tests/get; README/workflows/capabilities.md free of apt repo / gh-pages.

## Findings

[low] README.md (install line) — CWE-377 fixed name in /tmp (user-mandated line)
Data path: `wget -qO /tmp/vr-telex-install.sh` -> `sh /tmp/vr-telex-install.sh`.
Exploit: another local user pre-creates /tmp/vr-telex-install.sh. On Ubuntu defaults (protected_regular=2) wget's open fails, `&&` stops: silent failure (`-q`, no message) = local DoS only. On a host with protected_regular=0 and a planted 0666 file, wget writes into the attacker's file, which the attacker can rewrite before `sh` runs -> code as the user, who then types the sudo password.
Fix (user decides; the line is the user's choice in D-APT-2): `f=$(mktemp) && wget -qO "$f" <url> && sh "$f"`, or keep the line and accept (multi-user host + non-default sysctl).

[low] README.md:27-32 — CWE-494 first install trusts the bootstrap script by TLS only
Exploit: whoever can replace release assets (a leaked token with contents:write) without the signing key replaces vr-telex-install.sh itself; the fresh-install command runs it unverified. The signature protects only `vr-telex-update` (installed copy with the pinned key) and the .deb hop. The README text ("checks the signature against the release key built into the script") reads as if the first run were covered.
Fix: one README sentence on what is and is not checked on the first run, optionally an opt-in verify recipe (`gpg --verify SHA256SUMS.asc SHA256SUMS` with packaging/apt/vr-telex.asc, then `sha256sum -c --ignore-missing`).

[low] packaging/get/vr-telex-install.sh:165-173 — CWE-294 replay of an older signed set (freeze)
Exploit: same asset-write attacker serves an older, validly signed SHA256SUMS/.asc/.deb as "latest". Updates print "installed ... is newer ... nothing to do" (no downgrade), but users silently stop getting newer, possibly security, releases; fresh installs get the old version (already dominated by the finding above). Today no older release uses this flow (0.1.1 is the first), so impact is nil now. Rated low; accepting as residual is reasonable.
Fix (optional): sign a release date or a monotonic serial into SHA256SUMS and warn when it is older than N days or than the serial seen last.

[minor] .github/workflows/release.yml:197 — `--latest` forces "Latest" regardless of version
Scenario: an owner-approved run for an older tag on master (e.g. a re-cut v0.1.1 after v0.2.0 exists) is created with `--latest` -> releases/latest now serves 0.1.1: fresh installs get the old version, updates report "nothing to do". gh's default (no flag) is automatic by date and semver and would keep v0.2.0 latest.
Fix: drop `--latest` (default automatic) or pass `--latest=false` when `${TAG#v}` is lower than the current latest.

## Rule check B1
| Rule | Status | Evidence |
|---|---|---|
| D-APT-2 | pass | README install/update/remove lines exactly as asked (tests/get checks them); script: latest release -> temp dir -> gpgv + sha256 -> `sudo apt install -y <abs deb>` -> vr-telex-setup -> trap cleanup; `vr-telex-update` asset in deb; tools/apt-repo, tests/apt, gh-pages publish removed |
| AC-3 | pass | script refuses root before download (same wording as vr-telex-setup); setup runs once after apt |
| AC-4 | pass | crates/vr-telex/Cargo.toml asset 755; tests/deb expects `./usr/bin/vr-telex-update` and byte-equality with the script |
| AC-6 (as revised by D-APT-2) | pass | tag v*, pinned SHAs, contents: write only in publish, env apt-release + master gate, secret piped/unset, never echoed; test.yml runs tests/get |
| AC-7 (as revised) | pass | README install/update/remove; from-source + vr-talex note kept; no apt-repo text left |
| BASE-9 | pass | all checks before sudo; seams cannot reach a non-loopback download with a swapped key (lines 82-104) |
| BASE-16 | pass | no duplicate helper; capabilities.md line replaced |
| BASE-20 | pass | grep: only RELEASING.md step 4 (intended cleanup) mentions gh-pages |
| BASE-21 | pass | no secret in repo/team files; throwaway keys only |
| BASE-3/BASE-4 | pass | red.log/run2.log, mutation log, final runs in notes |

No blocker or major. Low/minor items above are for the user to accept or schedule.

REVIEW_PASS

## Re-check quick pass 1
Read only this round's diff (release.yml, README.md) and 04_dev_B1.md `## Quick pass 1`.

- Finding 4 (`--latest`): fixed. release.yml:197 `gh release create ... --verify-tag --title ...` has no `--latest` (grep count 0), so gh picks Latest by date and version. The `upload --clobber` branch is unchanged and does not touch Latest. Nothing new.
- Finding 2 (bootstrap trusted on TLS alone): fixed. README now says the first run does not check the script, and gives the recipe. File names match what the release publishes (`vr-telex-install.sh`, `SHA256SUMS`, `SHA256SUMS.asc`; key `packaging/apt/vr-telex.asc` saved as `vr-telex.asc`). Commands are correct: `gpg --import vr-telex.asc`, `gpg --verify SHA256SUMS.asc SHA256SUMS`, `sha256sum -c --ignore-missing SHA256SUMS`. With only the script downloaded, it checks that line, and coreutils 9.4 exits non-zero when it checks no file at all. The install line is unchanged and tests/get still checks it.
- New, [low] README.md (recipe): `gpg --verify` exits 0 for a good signature from any key in the user's keyring, not only the release key. The recipe does not ask the user to compare the fingerprint in the output with `2C30E91F97E5A566BEFF373736C30B9165329B85`, which the README prints a few lines above. Scenario: a user whose keyring already holds another key (or who imports a swapped `vr-telex.asc`) gets "Good signature" for a set signed by that key. Fix: add "check that gpg reports the key 2C30E91F97E5A566BEFF373736C30B9165329B85". Optional, does not block.

REVIEW_PASS
