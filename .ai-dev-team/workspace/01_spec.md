# Spec — APT: rename to vr-telex, Debian package, signed apt repository (APT)

has_ui: false
security_sensitive: true (installer touches the user's session, input sources, systemd units; release signing key)
route: new feature, user present

## User decisions (27 Nov 16:22–16:24)
- Distribution "cách 2": a signed apt repository of our own, so users run `sudo apt install vr-telex` and get updates by `apt upgrade`.
- Package name `vr-telex`, and rename EVERY `vr-talex` to `vr-telex` (binary, crate, systemd unit, IBus engine / input-source id, files, env vars, messages, docs, tests).
- amd64 only. A new GPG key made only for this repository; the user moves the private key to a GitHub secret himself.
- Hosted on GitHub Pages of mvanvu/vr-telex (branch `gh-pages`, https://mvanvu.github.io/vr-telex); a release is built when a tag `v*` is pushed; the .deb is also attached to the GitHub Release.
- The current machine-wide vr-talex installation is migrated automatically by the new installer: old service and binary stopped and removed; the VI/EN mode and the original pre-install backups kept, so uninstalling vr-telex still restores the machine as it was before the very first install.

## Acceptance criteria
- AC-1 Rename: no `vr-talex` / `VR_TALEX` / `vr_talex` left in tracked files except in migration code that must name the old install (and the team's archived history). Crate dir `crates/vr-telex`, binary `vr-telex`, unit `vr-telex.service`, IBus engine/source `('ibus','vr-telex')`, env file `90-vr-telex.conf`, data/state dirs `vr-telex`, env seams `VR_TELEX_*`. All suites green.
- AC-2 Migration (from-source installer and packaged setup alike): on a machine with the old vr-talex install, the new install stops and disables `vr-talex.service`, removes its unit, binary, env file and runtime address files; moves `~/.local/state/vr-talex/mode` and `~/.local/share/vr-talex/backup` to the vr-telex paths (no overwrite of existing newer data); replaces the input source `('ibus','vr-talex')` with `('ibus','vr-telex')` at the same position, keeping the current selection; is idempotent; uninstall afterwards restores the pre-first-install state from the migrated backups. Proven by tests/install scenarios with a fake old install.
- AC-3 Per-user setup for the package: the .deb installs files system-wide; each user enables it once with `vr-telex-setup` (and disables with `vr-telex-setup --remove`), which runs the same logic as install.sh / uninstall.sh but uses `/usr/bin/vr-telex` and the packaged unit (no cargo build, no files in ~/.local/bin). Running as root refuses (as today). The from-source `install.sh` / `uninstall.sh` keep working.
- AC-4 Debian package `vr-telex_<version>_amd64.deb` built by `cargo-deb` (or an equivalent documented tool) from the workspace: `/usr/bin/vr-telex`, `/usr/bin/vr-telex-setup`, `/usr/lib/systemd/user/vr-telex.service`, shared files under `/usr/share/vr-telex/`, docs + copyright (MIT + THIRD-PARTY-NOTICES); correct Depends (libc, systemd, dbus as needed), Description, Maintainer (no personal email unless the user gives one — use the GitHub project URL), version from Cargo. `postinst` does not touch user sessions; `prerm`/`postrm` tell users to run `vr-telex-setup --remove` before purge (or handle it safely). A test checks the package contents and control fields (`dpkg-deb -c / -f`).
- AC-5 Apt repository: a script (used by CI, runnable locally with a throwaway key) builds a flat or pool/dists repo with `apt-ftparchive`, signs `InRelease` and `Release.gpg` with the repository key, and includes the public key file. A local test serves the built repo from a temp dir and runs `apt-get` against it in a throwaway root (`apt-get -o Dir=… update` / `apt-cache policy vr-telex`, no sudo) and verifies the signature check passes with the keyring and fails without.
- AC-6 CI: `.github/workflows/release.yml` on tag `v*`: test, build the .deb, build and sign the repo with secret `APT_GPG_PRIVATE_KEY` (+ optional passphrase secret), publish to `gh-pages` (keeping older versions in the pool), attach the .deb to the GitHub Release. Pinned action versions; least permissions (`contents: write` only where needed); the secret never echoed. A second workflow or job runs the tests on push/PR (optional, cheap).
- AC-7 README: install via apt (keyring download to `/etc/apt/keyrings/vr-telex.gpg`, `signed-by` source line, `apt install vr-telex`, then `vr-telex-setup`), update, remove; from-source path kept; migration note for vr-talex users.
- AC-8 The user's machine ends on vr-telex installed from the final reviewed commit (from source, as today), migrated from vr-talex, typing working (service active, mode kept).

## Out of scope
arm64, PPA, other distributions, publishing the key or pushing tags (the leader prepares the commands; push / tag / Pages / secrets happen only on the user's go).
