#!/usr/bin/env bash
# Build (or update) the signed apt repository for vr-telex.
#
# Usage: tools/apt-repo/build.sh <deb>... <out-dir>
#
# Environment:
#   APT_GPG_KEY         required: fingerprint (or key id) of the signing key
#   GNUPGHOME           keyring holding that secret key (gpg's default otherwise)
#   APT_GPG_PASSPHRASE  optional: passphrase of the key; passed to gpg on a
#                       pipe, never on a command line
#
# Layout written under <out-dir>:
#   pool/main/v/vr-telex/<deb>             every version ever added (kept)
#   dists/stable/main/binary-amd64/Packages{,.gz}
#   dists/stable/Release, InRelease, Release.gpg
#   vr-telex.asc, vr-telex.gpg             public key (armored, binary)
#
# Packages already in the pool stay there, so running this over a checkout of
# the published site adds a version without dropping the older ones. A .deb
# whose file name is already in the pool with different content is refused:
# a published version must never change under the same name.
#
# Never add `set -x` here: the signing steps run with the passphrase in scope.
set -euo pipefail

PKG=vr-telex
ARCH=amd64
SUITE=stable
COMPONENT=main
POOL="pool/$COMPONENT/${PKG:0:1}/$PKG"
BINDIR="dists/$SUITE/$COMPONENT/binary-$ARCH"

die() {
  printf 'apt-repo: error: %s\n' "$*" >&2
  exit 1
}
log() { printf 'apt-repo: %s\n' "$*"; }

[ "$#" -ge 2 ] || die "usage: $0 <deb>... <out-dir>"
OUT=${*: -1}
DEBS=("${@:1:$#-1}")
[ -n "${APT_GPG_KEY:-}" ] || die "APT_GPG_KEY is not set (fingerprint of the signing key)"

for tool in dpkg-deb apt-ftparchive gpg gzip cmp; do
  command -v "$tool" >/dev/null || die "$tool not found"
done

# Check every input before writing anything.
declare -A SEEN=()
for deb in "${DEBS[@]}"; do
  [ -f "$deb" ] || die "$deb: no such file"
  name=$(basename -- "$deb")
  case $name in
    "${PKG}"_*_"${ARCH}".deb) ;;
    *) die "$name: file name must be ${PKG}_<version>_${ARCH}.deb" ;;
  esac
  got_pkg=$(dpkg-deb -f "$deb" Package) || die "$name: not a Debian package"
  got_arch=$(dpkg-deb -f "$deb" Architecture)
  got_ver=$(dpkg-deb -f "$deb" Version)
  [ "$got_pkg" = "$PKG" ] || die "$name: Package is '$got_pkg', expected '$PKG'"
  [ "$got_arch" = "$ARCH" ] || die "$name: Architecture is '$got_arch', expected '$ARCH'"
  [ "$name" = "${PKG}_${got_ver/*:/}_${ARCH}.deb" ] ||
    die "$name: file name does not match Version $got_ver"
  if [ -e "$OUT/$POOL/$name" ] && ! cmp -s -- "$deb" "$OUT/$POOL/$name"; then
    die "$name: a different file with this name is already in the pool; bump the version"
  fi
  # A second input with the same name would silently replace the first.
  if [ -n "${SEEN[$name]:-}" ] && ! cmp -s -- "$deb" "${SEEN[$name]}"; then
    die "$name: given twice with different content (${SEEN[$name]}, $deb)"
  fi
  SEEN[$name]=$deb
done

# Signing. Loopback mode with the passphrase (empty when unset) on a pipe:
# gpg never opens a pinentry prompt, and a wrong or missing passphrase fails.
GPG=(gpg --batch --yes --no-tty --pinentry-mode loopback --passphrase-fd 0
  --local-user "$APT_GPG_KEY" --digest-algo SHA512)
sign() { printf '%s\n' "${APT_GPG_PASSPHRASE:-}" | "${GPG[@]}" "$@"; }
gpg --batch --list-secret-keys "$APT_GPG_KEY" >/dev/null 2>&1 ||
  die "no secret key for $APT_GPG_KEY in ${GNUPGHOME:-the default keyring}"

# Written outside dists/ so the index scan never sees a half-written file.
RELEASE_TMP=$(mktemp "${TMPDIR:-/tmp}/apt-repo-release.XXXXXX")
trap 'rm -f -- "$RELEASE_TMP"' EXIT
# Prove the key signs before the site is touched.
sign --clearsign --output /dev/null "$RELEASE_TMP" 2>/dev/null ||
  die "cannot sign with $APT_GPG_KEY (wrong or missing APT_GPG_PASSPHRASE?)"

mkdir -p -- "$OUT/$POOL" "$OUT/$BINDIR"
for deb in "${DEBS[@]}"; do
  cp -- "$deb" "$OUT/$POOL/"
  log "added $POOL/$(basename -- "$deb")"
done

cd -- "$OUT"
# Filename: fields are relative to the repository root, so run from there.
apt-ftparchive packages "pool/$COMPONENT" >"$BINDIR/Packages"
gzip -9nc "$BINDIR/Packages" >"$BINDIR/Packages.gz"

rm -f "dists/$SUITE/Release" "dists/$SUITE/InRelease" "dists/$SUITE/Release.gpg"
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin="$PKG" \
  -o APT::FTPArchive::Release::Label="$PKG" \
  -o APT::FTPArchive::Release::Suite="$SUITE" \
  -o APT::FTPArchive::Release::Codename="$SUITE" \
  -o APT::FTPArchive::Release::Architectures="$ARCH" \
  -o APT::FTPArchive::Release::Components="$COMPONENT" \
  -o APT::FTPArchive::Release::Description="vr-telex Vietnamese Telex input method" \
  release "dists/$SUITE" >"$RELEASE_TMP"
mv -- "$RELEASE_TMP" "dists/$SUITE/Release"
chmod 0644 "dists/$SUITE/Release"

sign --clearsign --output "dists/$SUITE/InRelease" "dists/$SUITE/Release" ||
  die "signing InRelease failed"
sign --armor --detach-sign --output "dists/$SUITE/Release.gpg" "dists/$SUITE/Release" ||
  die "signing Release.gpg failed"

gpg --batch --yes --armor --export "$APT_GPG_KEY" >"$PKG.asc"
gpg --batch --yes --export "$APT_GPG_KEY" >"$PKG.gpg"
[ -s "$PKG.asc" ] || die "exporting the public key failed"

count=$(grep -c '^Package: ' "$BINDIR/Packages" || true)
log "signed dists/$SUITE ($count package version(s) in the pool)"
