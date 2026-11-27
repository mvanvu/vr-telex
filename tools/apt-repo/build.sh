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
#   APT_PINNED_KEY      public key the published site must be signed with and
#                       APT_GPG_KEY must belong to (default: packaging/apt/
#                       vr-telex.asc of the checkout this script is in; tests
#                       point it at a throwaway key, release.yml leaves it)
#   APT_REPO_BOOTSTRAP  1: sign a non-empty pool that has no InRelease to check
#                       it against (manual recovery only; release.yml never
#                       sets it)
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
# The site is storage anyone with push access to gh-pages can change, and
# everything in the pool gets signed again here. So before writing, an
# existing dists/stable/InRelease must verify with the pinned key (never the
# key published on the site), the Packages it hashes must be unchanged, and
# every file under pool/ must be listed there with the same SHA256, apart
# from the inputs of this run. dists/stable is then rebuilt from scratch, so
# no extra file there gets into the signed Release either.
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
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PINNED_KEY=${APT_PINNED_KEY:-$HERE/../../packaging/apt/vr-telex.asc}

for tool in dpkg-deb apt-ftparchive gpg gpgv gzip cmp sha256sum find; do
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

WORK=$(mktemp -d "${TMPDIR:-/tmp}/apt-repo.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

# The pinned key as a gpgv keyring, and the signing key must be in it: a
# site signed with any other key would be refused by the next release.
[ -f "$PINNED_KEY" ] || die "pinned public key $PINNED_KEY not found"
if grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$PINNED_KEY"; then
  gpg --batch --yes --dearmor --output "$WORK/pinned.gpg" "$PINNED_KEY" 2>/dev/null ||
    die "cannot read the pinned public key $PINNED_KEY"
else
  cp -- "$PINNED_KEY" "$WORK/pinned.gpg"
fi
PINNED_FPRS=$(gpg --batch --show-keys --with-colons "$WORK/pinned.gpg" 2>/dev/null | awk -F: '/^fpr/ { print $10 }')
[ -n "$PINNED_FPRS" ] || die "no public key in $PINNED_KEY"
SIGNING_FPR=$(gpg --batch --with-colons --list-secret-keys -- "$APT_GPG_KEY" 2>/dev/null |
  awk -F: '/^sec/ { s = 1; next } s && /^fpr/ { print $10; exit }') ||
  true
[ -n "$SIGNING_FPR" ] || die "no secret key for $APT_GPG_KEY in ${GNUPGHOME:-the default keyring}"
grep -qxF -- "$SIGNING_FPR" <<<"$PINNED_FPRS" ||
  die "the signing key $SIGNING_FPR is not the pinned key ($PINNED_KEY)"

# Check the published site before anything is written (see the header).
if [ -L "$OUT/dists" ] || [ -L "$OUT/dists/$SUITE" ]; then die "dists/ or dists/$SUITE is a symlink; refusing"; fi
POOL_FILES=()
if [ -e "$OUT/pool" ] || [ -L "$OUT/pool" ]; then
  while IFS= read -r -d '' f; do
    rel=${f#"$OUT"/}
    if [ -L "$f" ]; then
      die "$rel: not a regular file (symlink) in the pool; refusing"
    elif [ -d "$f" ]; then
      continue
    elif [ ! -f "$f" ]; then
      die "$rel: not a regular file in the pool; refusing"
    fi
    POOL_FILES+=("$rel")
  done < <(find "$OUT/pool" -print0)
fi

declare -A LISTED=()
INRELEASE="$OUT/dists/$SUITE/InRelease"
HAVE_INDEX=0
if [ -e "$INRELEASE" ] || [ -L "$INRELEASE" ]; then
  if [ ! -f "$INRELEASE" ] || [ -L "$INRELEASE" ]; then die "dists/$SUITE/InRelease is not a regular file"; fi
  gpgv --keyring "$WORK/pinned.gpg" --output "$WORK/Release" "$INRELEASE" >/dev/null 2>&1 ||
    die "dists/$SUITE/InRelease does not verify with the pinned key $PINNED_KEY; refusing to sign this pool"
  want=$(awk -v p="$COMPONENT/binary-$ARCH/Packages" \
    '/^[^ ]/ { s = ($1 == "SHA256:") } s && NF == 3 && $3 == p { print $1; exit }' "$WORK/Release")
  [ -n "$want" ] || die "the signed InRelease lists no $COMPONENT/binary-$ARCH/Packages"
  if [ ! -f "$OUT/$BINDIR/Packages" ] || [ -L "$OUT/$BINDIR/Packages" ]; then
    die "$BINDIR/Packages is missing or not a regular file"
  fi
  # Hash the copy that is parsed below, not the file on the site.
  cp -- "$OUT/$BINDIR/Packages" "$WORK/Packages"
  got=$(sha256sum <"$WORK/Packages")
  [ "${got%% *}" = "$want" ] || die "$BINDIR/Packages does not match the signed InRelease; refusing"
  while read -r sha fn; do
    LISTED[$fn]=$sha
  done < <(awk '/^Filename: / { fn = $2 } /^SHA256: / { sh = $2 }
    /^$/ { if (fn != "" && sh != "") print sh, fn; fn = ""; sh = "" }
    END { if (fn != "" && sh != "") print sh, fn }' "$WORK/Packages")
  HAVE_INDEX=1
fi

for rel in "${POOL_FILES[@]}"; do
  if [ -n "${LISTED[$rel]:-}" ]; then
    got=$(sha256sum <"$OUT/$rel")
    [ "${got%% *}" = "${LISTED[$rel]}" ] ||
      die "$rel: does not match the signed index (SHA256 differs); refusing"
    continue
  fi
  # An input of this run already copied there (a rerun after a failure).
  name=${rel##*/}
  if [ "$rel" = "$POOL/$name" ] && [ -n "${SEEN[$name]:-}" ] && cmp -s -- "${SEEN[$name]}" "$OUT/$rel"; then
    continue
  fi
  if [ "$HAVE_INDEX" = 1 ]; then
    die "$rel: not listed in the signed index (dists/$SUITE/InRelease); remove it from the site"
  fi
  [ "${APT_REPO_BOOTSTRAP:-0}" = 1 ] ||
    die "$rel is in the pool but there is no signed InRelease to check it against; refusing (APT_REPO_BOOTSTRAP=1 signs it anyway)"
  log "bootstrap: signing unchecked $rel"
done

# Signing. Loopback mode with the passphrase (empty when unset) on a pipe:
# gpg never opens a pinentry prompt, and a wrong or missing passphrase fails.
GPG=(gpg --batch --yes --no-tty --pinentry-mode loopback --passphrase-fd 0
  --local-user "$APT_GPG_KEY" --digest-algo SHA512)
sign() { printf '%s\n' "${APT_GPG_PASSPHRASE:-}" | "${GPG[@]}" "$@"; }

# Written outside dists/ so the index scan never sees a half-written file.
RELEASE_TMP=$WORK/Release.new
: >"$RELEASE_TMP"
# Prove the key signs before the site is touched.
sign --clearsign --output /dev/null "$RELEASE_TMP" 2>/dev/null ||
  die "cannot sign with $APT_GPG_KEY (wrong or missing APT_GPG_PASSPHRASE?)"

# Rebuilt from scratch: only what this run writes is in the signed Release.
rm -rf -- "${OUT:?}/dists/$SUITE"
mkdir -p -- "$OUT/$POOL" "$OUT/$BINDIR"
for deb in "${DEBS[@]}"; do
  cp -- "$deb" "$OUT/$POOL/"
  log "added $POOL/$(basename -- "$deb")"
done

cd -- "$OUT"
# Filename: fields are relative to the repository root, so run from there.
apt-ftparchive packages "pool/$COMPONENT" >"$BINDIR/Packages"
gzip -9nc "$BINDIR/Packages" >"$BINDIR/Packages.gz"

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
