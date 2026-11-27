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
