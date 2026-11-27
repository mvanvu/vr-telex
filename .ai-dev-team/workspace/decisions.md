# Decisions — APT

D1 (user, 27 Nov 16:22) — Own signed apt repository on GitHub Pages of mvanvu/vr-telex (gh-pages), release on tag v*, .deb also attached to the GitHub Release; amd64 only.
D2 (user, 16:24) — Package name vr-telex and rename every vr-talex to vr-telex; the new installer migrates an existing vr-talex install automatically (keeps mode and original backups).
D3 (user, 16:24) — A new GPG key only for this repository; the user puts the private key into the GitHub secret himself.

## D-APT-2 (19:38, user) — install by script from the latest release, no apt repo
- Question: "apt install trực tiếp" is impossible outside the Ubuntu archive; user chose: wget a script from the latest release into /tmp and run it with sh; the script downloads the latest .deb to a temp dir, installs it (sudo apt install ./…deb), runs vr-telex-setup, cleans up; a command updates to the latest release.
- GitHub Pages / apt repo dropped entirely (user picked "Bỏ hẳn repo apt"): disable Pages, delete gh-pages, remove tools/apt-repo, tests/apt, gh-pages publish, README apt section.
- Download check (user did not pick an option; leader took the recommended one, confirm-on-return not needed — user present, told in the message): SHA256SUMS signed with the existing release key (fpr 2C30E91F…5329B85), public key embedded in the script, verified with gpgv before sudo.
- Supersedes AC-5 (apt repo) and the apt parts of AC-6/AC-7 of 01_spec.md.
- D-APT-2 update (20:25, user): README install line is the pipe form `wget -qO- https://github.com/mvanvu/vr-telex/releases/latest/download/vr-telex-install.sh | sh`.

## D-APT-3 (20:28, user: "Làm cách 1") — apt upgrade updates vr-telex
- The package adds its own apt source and keyring on install (Chrome / VS Code pattern), so `sudo apt update && sudo apt upgrade` picks up new releases. Install line stays `wget -qO- …/vr-telex-install.sh | sh`.
- Hosting (leader's reading, stated to the user): no GitHub Pages (user dropped it in D-APT-2). A flat apt repository is published as assets of each GitHub Release (InRelease, Release, Release.gpg, Packages, Packages.gz beside the .deb); the source line points at https://github.com/mvanvu/vr-telex/releases/latest/download ./ — apt follows GitHub's redirect to the asset. Only the latest version is offered, which is what apt upgrade needs.
- Key: same release key (fpr 2C30E91F…5329B85), shipped as /usr/share/keyrings/vr-telex.gpg, used only via signed-by.
- D-APT-3 note (20:43, leader): apt source is written by postinst (template /usr/share/vr-telex/vr-telex.sources) and removed by postrm on remove/purge, not a conffile — a conffile left after remove points at a deleted keyring and makes every apt update fail.
