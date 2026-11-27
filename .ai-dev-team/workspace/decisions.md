# Decisions — APT

D1 (user, 27 Nov 16:22) — Own signed apt repository on GitHub Pages of mvanvu/vr-telex (gh-pages), release on tag v*, .deb also attached to the GitHub Release; amd64 only.
D2 (user, 16:24) — Package name vr-telex and rename every vr-talex to vr-telex; the new installer migrates an existing vr-talex install automatically (keeps mode and original backups).
D3 (user, 16:24) — A new GPG key only for this repository; the user puts the private key into the GitHub secret himself.
