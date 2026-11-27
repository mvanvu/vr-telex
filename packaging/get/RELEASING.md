# Releasing (maintainers)

Users install and update with `vr-telex-install.sh` (README > Install); the package ships
the same file as `/usr/bin/vr-telex-update`. It downloads from
`https://github.com/mvanvu/vr-telex/releases/latest/download/`:

- `vr-telex_<version>-1_amd64.deb`
- `vr-telex-install.sh`
- `SHA256SUMS` (both files above) and `SHA256SUMS.asc` (detached, armored signature)

and installs only when `SHA256SUMS.asc` verifies with the key embedded in the script.

The package also writes the apt source `/etc/apt/sources.list.d/vr-telex.sources` (from
`packaging/deb/vr-telex.sources`) with the key `/usr/share/keyrings/vr-telex.gpg`
(`packaging/deb/vr-telex.gpg`), so `apt update && apt upgrade` reads the flat apt
repository published with each release: `Packages`, `Packages.gz`, `Release`, `InRelease`
and `Release.gpg` (`packaging/apt/build-flat-repo.sh`), beside the .deb. apt asks for
`<base>/./InRelease`, `<base>/./Packages.gz` and `<base>/<deb name>`; GitHub redirects
each to the asset of the latest release. Only the latest version is offered.

## Publishing a release

1. Bump `[workspace.package] version` in `Cargo.toml` and refresh `Cargo.lock`
   (`cargo update -p vr-telex --offline` or any build), merge to `master`.
2. Tag that `master` commit `v<version>` and push the tag.
3. `.github/workflows/release.yml`: the `build` job refuses a tag that is not on `master`,
   tests, builds the .deb (its name must match the tag) and runs `tests/deb/run.sh` and
   `tests/get/run.sh` and `tests/apt/run.sh`. The `publish` job waits for the owner's approval (environment
   `apt-release`), writes `SHA256SUMS`, signs it with the release key (only the pinned
   fingerprint is accepted) in a temp GnuPG home removed on exit, checks the signature
   with gpgv against `packaging/apt/vr-telex.asc`, builds and signs the apt repository with
   the same key (`packaging/apt/build-flat-repo.sh`, which checks both signatures with the
   pinned key), and uploads the nine files to the GitHub Release (created as the latest
   release).
4. If the `publish` job fails, re-run only that job ("Re-run failed jobs"): it reuses the
   build job's .deb, so the files it replaces on the release keep the same hashes and apt
   clients never see an `InRelease` that does not match. A full re-run rebuilds the .deb,
   and the `publish` job refuses to replace a published .deb with different bytes; for a
   new build, bump the version and tag again. If the release was never published (still a
   draft, or no `InRelease` among its assets), delete it with `gh release delete <tag>`
   (the tag stays) and run the workflow again instead.

Local tests: `bash tests/get/run.sh` (throwaway keys, local HTTP server, stubbed sudo and
apt; no network, no root) and `bash tests/apt/run.sh` (throwaway key, a local server that
redirects like GitHub, apt-get in a throwaway apt root).

## Signing key

- Fingerprint `2C30E91F97E5A566BEFF373736C30B9165329B85` (RSA 4096, sign + certify, no
  subkeys), expires 2029-11-26. Public key: `packaging/apt/vr-telex.asc`; the same key is
  embedded in `packaging/get/vr-telex-install.sh` (`tests/get/run.sh` fails when the two
  differ).
- The secret key lives only in a dedicated GnuPG home outside the repository (below
  `$KEYHOME`) and in the secret `APT_GPG_PRIVATE_KEY` (+ `APT_GPG_PASSPHRASE` if it has
  one) of the GitHub environment `apt-release`.

### Renewing before it expires

Do this a few months before the expiry date. The fingerprint does not change.

1. Extend the expiry (here by 3 years):
   `gpg --homedir "$KEYHOME" --quick-set-expire 2C30E91F97E5A566BEFF373736C30B9165329B85 3y`
2. Re-export the public key into the repository:
   `gpg --homedir "$KEYHOME" --armor --export 2C30E91F97E5A566BEFF373736C30B9165329B85 >packaging/apt/vr-telex.asc`
3. Regenerate the embedded copy and the packaged keyring:
   `packaging/get/embed-key.sh` and
   `gpg --dearmor <packaging/apt/vr-telex.asc >packaging/deb/vr-telex.gpg`, then
   `bash tests/get/run.sh` and `bash tests/deb/run.sh`. Commit the three files.
4. Update the CI secret (piped, never written to a file):
   `gpg --homedir "$KEYHOME" --armor --export-secret-keys 2C30E91F97E5A566BEFF373736C30B9165329B85 | gh secret set APT_GPG_PRIVATE_KEY --env apt-release --repo mvanvu/vr-telex`
5. Publish a release. gpgv does not reject signatures made by an expired key, so old
   `vr-telex-update` copies keep working; the new script carries the renewed key. apt
   does reject them (EXPKEYSIG): the release with the renewed keyring must be published,
   and installed by `apt upgrade`, before the old expiry date, or users on apt updates
   have to run `vr-telex-update` once.

A new key (new fingerprint) is the same steps with the new key; installed copies of
`vr-telex-update` only trust the old key, so publish one last release signed with the old
key whose script embeds the new key, before switching the secret.

## Release gate (one-time setup by the owner)

The signing key is readable only by the `publish` job, which runs in the environment
`apt-release`; the `build` job refuses a tag whose commit is not on `master`. These steps
are done once, by the repository owner, with `gh` logged in as that owner.

1. Create the environment with the owner as required reviewer and only `v*` tags allowed
   to deploy to it:

   ```sh
   owner_id=$(gh api users/mvanvu --jq .id)
   gh api -X PUT repos/mvanvu/vr-telex/environments/apt-release --input - <<JSON
   {"reviewers": [{"type": "User", "id": $owner_id}],
    "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
   JSON
   gh api -X POST repos/mvanvu/vr-telex/environments/apt-release/deployment-branch-policies \
     -f name='v*' -f type=tag
   ```

2. Store the key in the environment (piped, never written to a file) and keep no
   repository-wide copy:

   ```sh
   gpg --homedir "$KEYHOME" --armor --export-secret-keys 2C30E91F97E5A566BEFF373736C30B9165329B85 |
     gh secret set APT_GPG_PRIVATE_KEY --env apt-release --repo mvanvu/vr-telex
   gh secret set APT_GPG_PASSPHRASE --env apt-release --repo mvanvu/vr-telex   # only if the key has one; prompts
   gh secret list --repo mvanvu/vr-telex                     # must not list APT_GPG_*
   gh secret list --env apt-release --repo mvanvu/vr-telex   # must list them
   ```

3. Let only repository admins (the owner) create, move or delete `v*` tags:

   ```sh
   gh api -X POST repos/mvanvu/vr-telex/rulesets --input - <<'JSON'
   {"name": "release tags", "target": "tag", "enforcement": "active",
    "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
    "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"}],
    "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]}
   JSON
   ```

   (`actor_id` 5 is the Admin role.)

4. After the move away from the apt repository: turn GitHub Pages off and delete the
   `gh-pages` branch and its ruleset ("gh-pages: release workflow only"), if present:

   ```sh
   gh api -X DELETE repos/mvanvu/vr-telex/pages
   gh api repos/mvanvu/vr-telex/rulesets --jq '.[] | select(.name | startswith("gh-pages")) | .id' |
     xargs -r -I{} gh api -X DELETE repos/mvanvu/vr-telex/rulesets/{}
   git push origin --delete gh-pages
   ```

5. Check: push a test tag on a commit that is not on `master` (for example
   `git tag v0.0.0-gate <branch commit> && git push origin v0.0.0-gate`): the `build` job
   fails at "Refuse a tag that is not on master" and nothing is published. Delete the tag
   afterwards (`git push origin :refs/tags/v0.0.0-gate`).
