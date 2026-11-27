# apt repository (maintainers)

The signed apt repository served from the `gh-pages` branch at
https://mvanvu.github.io/vr-telex is built by `build.sh`; `.github/workflows/release.yml`
runs it on every `v*` tag whose commit is on `master`. Users' install steps are in the
top-level README (Install).

```sh
APT_GPG_KEY=<fingerprint> GNUPGHOME=<keyring dir> [APT_GPG_PASSPHRASE=...] \
  tools/apt-repo/build.sh <vr-telex_<version>_amd64.deb>... <site dir>
bash tests/apt/run.sh [deb]   # local test: throwaway keys, throwaway apt root, no root
```

Layout: `pool/main/v/vr-telex/` (every published version is kept), `dists/stable/`
(`Release`, `InRelease`, `Release.gpg`, `main/binary-amd64/Packages{,.gz}`), and the
public key as `vr-telex.asc` and `vr-telex.gpg`. A published version never changes: a
different file under a name already in the pool is refused.

## What build.sh trusts

`gh-pages` is only storage: anyone who can push to it could add a file to the pool, and
build.sh signs the whole pool again. So before writing anything it checks the site against
the last signed index:

- `dists/stable/InRelease`, when present, must verify with the pinned key
  `packaging/apt/vr-telex.asc` of the release checkout (`APT_PINNED_KEY` overrides the
  path; only tests set it). The `vr-telex.gpg` published on the site is never used for
  this.
- `main/binary-amd64/Packages` must have the SHA256 that InRelease lists.
- Every file under `pool/` (any name, any depth) must be a regular file listed in that
  Packages with the same SHA256. Only the inputs of this run may be new. Symlinks and
  other non-regular files are refused.
- A non-empty pool without InRelease is refused unless `APT_REPO_BOOTSTRAP=1` is set
  (manual recovery only; release.yml never sets it).
- The signing key `APT_GPG_KEY` must be the pinned key.

`dists/stable` is then rebuilt from scratch, so nothing else there gets signed.

If a release stops with `not listed in the signed index` or `does not match`, someone
changed `gh-pages` outside a release: look at `git log gh-pages`, revert the commits that
were not made by `github-actions[bot]` for a release, and run the release job again.

## Signing key

- Fingerprint `2C30E91F97E5A566BEFF373736C30B9165329B85` (RSA 4096, sign + certify, no
  subkeys), expires 2029-11-26. Public key: `packaging/apt/vr-telex.asc`.
- The secret key lives only in a dedicated GnuPG home outside the repository (below
  `$KEYHOME`) and in the secret `APT_GPG_PRIVATE_KEY` (+ `APT_GPG_PASSPHRASE` if it has
  one) of the GitHub environment `apt-release`. release.yml signs only with the
  fingerprint of the committed public key.

### Renewing before it expires

Do this a few months before the expiry date. The fingerprint does not change, so the
README check line, release.yml and existing signatures stay valid.

1. Extend the expiry (here by 3 years):
   `gpg --homedir "$KEYHOME" --quick-set-expire 2C30E91F97E5A566BEFF373736C30B9165329B85 3y`
2. Re-export the public key into the repository and commit it:
   `gpg --homedir "$KEYHOME" --armor --export 2C30E91F97E5A566BEFF373736C30B9165329B85 >packaging/apt/vr-telex.asc`
3. Update the CI secret (piped, never written to a file):
   `gpg --homedir "$KEYHOME" --armor --export-secret-keys 2C30E91F97E5A566BEFF373736C30B9165329B85 | gh secret set APT_GPG_PRIVATE_KEY --env apt-release --repo mvanvu/vr-telex`
4. Publish a release (new `v*` tag). The workflow re-signs the repository and publishes
   the renewed `vr-telex.asc` / `vr-telex.gpg` on gh-pages.
5. Tell users to download the key again (the first block of README > Install > With apt):
   apt keeps the copy in `/etc/apt/keyrings/vr-telex.gpg`, and once the old expiry date
   passes it reports `EXPKEYSIG` for this repository until that copy is replaced.

### Changing the key (not renewing)

A new key has a new fingerprint, so the InRelease on the site no longer verifies with the
new pinned key and the next release is refused. Check the site by hand with the old key
(`gpgv --keyring <old vr-telex.gpg> dists/stable/InRelease`, then the Packages and pool
hashes), delete `dists/stable/InRelease` on `gh-pages`, and run build.sh once by hand with
`APT_REPO_BOOTSTRAP=1` and the new key. Users must then download the new key (README >
Install, first block, with the new fingerprint).

## Release gate (one-time setup by the owner)

The signing key is readable only by the `publish` job, which runs in the environment
`apt-release`; the `build` job refuses a tag whose commit is not on `master`. These steps
are done once, by the repository owner, with `gh` logged in as that owner. Nothing here is
done by the workflow.

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

   (Or in the web UI: Settings > Environments > New environment `apt-release`, Required
   reviewers: the owner, Deployment branches and tags: Selected, add tag rule `v*`.) Each
   release then waits on the owner's approval before it is signed and published.

2. Store the key in the environment (piped, never written to a file), then delete the old
   repository-wide secrets so no other workflow can read them:

   ```sh
   gpg --homedir "$KEYHOME" --armor --export-secret-keys 2C30E91F97E5A566BEFF373736C30B9165329B85 |
     gh secret set APT_GPG_PRIVATE_KEY --env apt-release --repo mvanvu/vr-telex
   gh secret set APT_GPG_PASSPHRASE --env apt-release --repo mvanvu/vr-telex   # only if the key has one; prompts
   gh secret delete APT_GPG_PRIVATE_KEY --repo mvanvu/vr-telex
   gh secret delete APT_GPG_PASSPHRASE --repo mvanvu/vr-telex                  # only if it exists
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

4. Let only the release workflow change `gh-pages` (the GitHub Actions app, id 15368,
   pushes with the workflow token; everyone else, admins included, is refused):

   ```sh
   gh api -X POST repos/mvanvu/vr-telex/rulesets --input - <<'JSON'
   {"name": "gh-pages: release workflow only", "target": "branch", "enforcement": "active",
    "conditions": {"ref_name": {"include": ["refs/heads/gh-pages"], "exclude": []}},
    "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"},
              {"type": "non_fast_forward"}],
    "bypass_actors": [{"actor_id": 15368, "actor_type": "Integration", "bypass_mode": "always"}]}
   JSON
   ```

   Any workflow token with `contents: write` can still push there; build.sh's check of
   the pool against the signed index (above) covers that case. To repair `gh-pages` by
   hand, set this ruleset's enforcement to `disabled` for the change and back to
   `active` afterwards.

5. Check: push a test tag on a commit that is not on `master` (for example
   `git tag v0.0.0-gate <branch commit> && git push origin v0.0.0-gate`): the `build` job
   fails at "Refuse a tag that is not on master" and nothing is published. Delete the tag
   afterwards (`git push origin :refs/tags/v0.0.0-gate`).
