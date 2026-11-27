# Plan — APT (spec 01_spec.md)

## Fixed paths (contract between A1, A2, A3, A4)
Package `vr-telex` (amd64), version = workspace crate version.
- /usr/bin/vr-telex — daemon (from crates/vr-telex)
- /usr/bin/vr-telex-setup — per-user setup (`vr-telex-setup`, `vr-telex-setup --remove`), a shell script
- /usr/share/vr-telex/ — shared files the setup uses: common.sh, 90-vr-telex.conf, xinputrc, org.fcitx.Fcitx5.desktop, org.fcitx.Fcitx5.service, install/uninstall logic as the setup needs them
- /usr/lib/systemd/user/vr-telex.service — packaged unit, ExecStart=/usr/bin/vr-telex (the from-source install keeps %h/.local/bin/vr-telex in ~/.config/systemd/user)
- /usr/share/doc/vr-telex/ — README, copyright (MIT + THIRD-PARTY-NOTICES)
Per-user data (both install kinds): ~/.local/share/vr-telex/backup, ~/.local/state/vr-telex/mode, ~/.config/environment.d/90-vr-telex.conf, input source ('ibus','vr-telex').
Env seams: VR_TELEX_BIN, VR_TELEX_TIMEOUT, VR_TELEX_OS_RELEASE (+ whatever A2 adds, e.g. VR_TELEX_SHARE for tests).

## Migration (A1)
Old names: unit vr-talex.service (~/.config/systemd/user), ~/.local/bin/vr-talex, ~/.config/environment.d/90-vr-talex.conf, ~/.local/share/vr-talex/backup, ~/.local/state/vr-talex/mode, source ('ibus','vr-talex'), runtime dir $XDG_RUNTIME_DIR/vr-talex, IBus address files pointing there. Done at the start of install (both kinds), idempotent, logged with `vr-telex:` messages; never deletes the old backup until it has been moved.

## Repo + CI (A4)
tools/apt-repo/build.sh <deb...> <out-dir> with GNUPGHOME/key id from env; layout `dists/stable/main/binary-amd64`, `pool/main/v/vr-telex/`; InRelease + Release.gpg; public key at `<out>/vr-telex.asc` (and committed at packaging/apt/vr-telex.asc once the real key exists — leader step).
Workflow: ubuntu-24.04 runner; actions pinned by commit SHA; publishes by checking out gh-pages, copying the new .deb into the pool (old ones kept), rebuilding indices, signing, pushing.

## Leader steps (not agents)
Generate the real repo key in a dedicated GNUPGHOME outside the repo, export the public key into the repo, hand the user the `gh secret set` command; enable Pages; tag — only on the user's go.
