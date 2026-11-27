#!/usr/bin/env bash
# Write the signed flat apt repository that is published beside the .deb as
# assets of a GitHub Release (D-APT-3).
#
# Usage: packaging/apt/build-flat-repo.sh <deb> <out-dir>
#
# Writes Packages, Packages.gz, Release, InRelease (clearsigned) and
# Release.gpg (detached, armored) into <out-dir>; other files there are left
# alone and the .deb is not copied: publish it beside them under its own name.
#
# The package's apt source (packaging/deb/vr-telex.sources) is the flat
# repository https://github.com/mvanvu/vr-telex/releases/latest/download/ ./
# so apt asks for <base>/InRelease, <base>/Packages.gz and <base>/<Filename>.
# GitHub answers each with a redirect to that asset of the latest release, so
# Filename is the bare .deb name and only the latest version is offered.
# Release has no Valid-Until: a release that stays the latest for a long time
# must keep verifying.
#
# Environment:
#   APT_GPG_KEY         required: fingerprint of the signing key
#   GNUPGHOME           keyring holding that secret key (gpg's default otherwise)
#   APT_GPG_PASSPHRASE  optional: passphrase of the key; given to gpg on a pipe,
#                       never on a command line
#   APT_PINNED_KEY      public key APT_GPG_KEY must be and the result must
#                       verify with (default: packaging/apt/vr-telex.asc of
#                       this checkout; tests point it at a throwaway key)
#
# Used by .github/workflows/release.yml (publish job) and tests/apt/run.sh.
# Never add `set -x` here: the signing steps run with the passphrase in scope.
set -euo pipefail

PKG=vr-telex
ARCH=amd64
INDEXES=(Packages Packages.gz Release InRelease Release.gpg)

die() {
  printf 'flat-repo: error: %s\n' "$*" >&2
  exit 1
}
log() { printf 'flat-repo: %s\n' "$*"; }

[ "$#" -eq 2 ] || die "usage: $0 <deb> <out-dir>"
DEB=$1
OUT=$2
[ -n "${APT_GPG_KEY:-}" ] || die "APT_GPG_KEY is not set (fingerprint of the signing key)"
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PINNED_KEY=${APT_PINNED_KEY:-$HERE/vr-telex.asc}

for tool in dpkg-deb apt-ftparchive gpg gpgv gzip cmp sed awk; do
  command -v "$tool" >/dev/null || die "$tool not found"
done

# Check every input before anything is written.
[ -f "$DEB" ] || die "$DEB: no such file"
[ -d "$OUT" ] || die "$OUT: no such directory"
NAME=$(basename -- "$DEB")
[[ $NAME =~ ^${PKG}_[0-9][A-Za-z0-9.+~-]*_${ARCH}\.deb$ ]] ||
  die "$NAME: file name must be ${PKG}_<version>_${ARCH}.deb"
got_pkg=$(dpkg-deb -f "$DEB" Package 2>/dev/null) || die "$NAME: not a Debian package"
got_arch=$(dpkg-deb -f "$DEB" Architecture)
got_ver=$(dpkg-deb -f "$DEB" Version)
[ "$got_pkg" = "$PKG" ] || die "$NAME: Package is '$got_pkg', expected '$PKG'"
[ "$got_arch" = "$ARCH" ] || die "$NAME: Architecture is '$got_arch', expected '$ARCH'"
[ "$NAME" = "${PKG}_${got_ver}_${ARCH}.deb" ] || die "$NAME: file name does not match Version $got_ver"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/flat-repo.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
mkdir -m 700 "$WORK/scratch" "$WORK/verify"

# Sign only with the pinned key: the packaged keyring is that key, so a repo
# signed with any other key would be refused by every installed copy.
[ -f "$PINNED_KEY" ] || die "pinned public key $PINNED_KEY not found"
if grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$PINNED_KEY"; then
  gpg --homedir "$WORK/scratch" --batch --yes --dearmor --output "$WORK/pinned.gpg" "$PINNED_KEY" 2>/dev/null ||
    die "cannot read the pinned public key $PINNED_KEY"
else
  cp -- "$PINNED_KEY" "$WORK/pinned.gpg"
fi
PINNED_FPRS=$(gpg --homedir "$WORK/scratch" --batch --show-keys --with-colons "$WORK/pinned.gpg" 2>/dev/null |
  awk -F: '/^fpr/ { print $10 }')
[ -n "$PINNED_FPRS" ] || die "no public key in $PINNED_KEY"
SIGNING_FPR=$(gpg --batch --with-colons --list-secret-keys -- "$APT_GPG_KEY" 2>/dev/null |
  awk -F: '/^sec/ { s = 1; next } s && /^fpr/ { print $10; exit }') || true
[ -n "$SIGNING_FPR" ] || die "no secret key for $APT_GPG_KEY in ${GNUPGHOME:-the default keyring}"
grep -qxF -- "$SIGNING_FPR" <<<"$PINNED_FPRS" ||
  die "the signing key $SIGNING_FPR is not the pinned key ($PINNED_KEY)"

# Loopback mode with the passphrase (empty when unset) on a pipe: gpg never
# opens a pinentry prompt, and a wrong or missing passphrase fails.
GPG=(gpg --batch --yes --no-tty --pinentry-mode loopback --passphrase-fd 0
  --local-user "$SIGNING_FPR!" --digest-algo SHA512)
sign() { printf '%s\n' "${APT_GPG_PASSPHRASE:-}" | "${GPG[@]}" "$@"; }
: >"$WORK/probe"
sign --clearsign --output /dev/null "$WORK/probe" 2>/dev/null ||
  die "cannot sign with $APT_GPG_KEY (wrong or missing APT_GPG_PASSPHRASE?)"

# Packages from this one .deb. apt-ftparchive writes Filename relative to the
# scanned directory ("./<name>"); the asset is served as <base>/<name>.
mkdir "$WORK/scan" "$WORK/repo"
cp -- "$DEB" "$WORK/scan/$NAME"
(cd "$WORK/scan" && apt-ftparchive packages .) >"$WORK/Packages.raw"
sed 's|^Filename: \./|Filename: |' "$WORK/Packages.raw" >"$WORK/repo/Packages"
[ "$(grep -c '^Package: ' "$WORK/repo/Packages")" = 1 ] || die "Packages does not hold exactly one package"
grep -qxF "Filename: $NAME" "$WORK/repo/Packages" || die "Packages: Filename is not $NAME"
gzip -9nc "$WORK/repo/Packages" >"$WORK/repo/Packages.gz"

# Release hashes what is in repo/ now: Packages and Packages.gz only.
(cd "$WORK/repo" && apt-ftparchive \
  -o APT::FTPArchive::Release::Origin="$PKG" \
  -o APT::FTPArchive::Release::Label="$PKG" \
  -o APT::FTPArchive::Release::Architectures="$ARCH" \
  -o APT::FTPArchive::Release::Description="vr-telex Vietnamese Telex input method (latest GitHub release)" \
  release .) >"$WORK/Release"
mv -- "$WORK/Release" "$WORK/repo/Release"
sign --clearsign --output "$WORK/repo/InRelease" "$WORK/repo/Release" 2>/dev/null || die "signing InRelease failed"
sign --armor --detach-sign --output "$WORK/repo/Release.gpg" "$WORK/repo/Release" 2>/dev/null ||
  die "signing Release.gpg failed"

# What apt will check: both signatures with the pinned key alone.
GNUPGHOME="$WORK/verify" gpgv --keyring "$WORK/pinned.gpg" --output "$WORK/InRelease.text" \
  "$WORK/repo/InRelease" 2>/dev/null || die "InRelease does not verify with the pinned key"
cmp -s "$WORK/InRelease.text" "$WORK/repo/Release" || die "InRelease does not carry Release"
GNUPGHOME="$WORK/verify" gpgv --keyring "$WORK/pinned.gpg" "$WORK/repo/Release.gpg" "$WORK/repo/Release" \
  2>/dev/null || die "Release.gpg does not verify with the pinned key"

for f in "${INDEXES[@]}"; do
  install -m 0644 -- "$WORK/repo/$f" "$OUT/$f"
done
log "signed flat repository for $NAME in $OUT (${INDEXES[*]})"
