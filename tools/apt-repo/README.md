# apt repository (maintainers)

The signed apt repository served from the `gh-pages` branch at
https://mvanvu.github.io/vr-telex is built by `build.sh`; `.github/workflows/release.yml`
runs it on every `v*` tag. Users' install steps are in the top-level README (Install).

```sh
APT_GPG_KEY=<fingerprint> GNUPGHOME=<keyring dir> [APT_GPG_PASSPHRASE=...] \
  tools/apt-repo/build.sh <vr-telex_<version>_amd64.deb>... <site dir>
bash tests/apt/run.sh [deb]   # local test: throwaway keys, throwaway apt root, no root
```

Layout: `pool/main/v/vr-telex/` (every published version is kept), `dists/stable/`
(`Release`, `InRelease`, `Release.gpg`, `main/binary-amd64/Packages{,.gz}`), and the
public key as `vr-telex.asc` and `vr-telex.gpg`. A published version never changes: a
different file under a name already in the pool is refused.

## Signing key

- Fingerprint `2C30E91F97E5A566BEFF373736C30B9165329B85` (RSA 4096, sign + certify, no
  subkeys), expires 2029-11-26. Public key: `packaging/apt/vr-telex.asc`.
- The secret key lives only in a dedicated GnuPG home outside the repository (below
  `$KEYHOME`) and in the repository secret `APT_GPG_PRIVATE_KEY` (+ `APT_GPG_PASSPHRASE` if
  it has one). release.yml signs only with the fingerprint of the committed public key.

### Renewing before it expires

Do this a few months before the expiry date. The fingerprint does not change, so the
README check line, release.yml and existing signatures stay valid.

1. Extend the expiry (here by 3 years):
   `gpg --homedir "$KEYHOME" --quick-set-expire 2C30E91F97E5A566BEFF373736C30B9165329B85 3y`
2. Re-export the public key into the repository and commit it:
   `gpg --homedir "$KEYHOME" --armor --export 2C30E91F97E5A566BEFF373736C30B9165329B85 >packaging/apt/vr-telex.asc`
3. Update the CI secret (piped, never written to a file):
   `gpg --homedir "$KEYHOME" --armor --export-secret-keys 2C30E91F97E5A566BEFF373736C30B9165329B85 | gh secret set APT_GPG_PRIVATE_KEY --repo mvanvu/vr-telex`
4. Publish a release (new `v*` tag). The workflow re-signs the repository and publishes
   the renewed `vr-telex.asc` / `vr-telex.gpg` on gh-pages.
5. Tell users to download the key again (the first block of README > Install > With apt):
   apt keeps the copy in `/etc/apt/keyrings/vr-telex.gpg`, and once the old expiry date
   passes it reports `EXPKEYSIG` for this repository until that copy is replaced.
