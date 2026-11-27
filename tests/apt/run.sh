#!/usr/bin/env bash
# Local test of the signed apt repository (AC-5). Needs no root and no network.
#
# Usage: bash tests/apt/run.sh [path/to/vr-telex_<version>_amd64.deb]
#
# It generates a throwaway signing key in a temp GNUPGHOME, builds the repo
# with tools/apt-repo/build.sh into a temp dir, and points apt-get at it
# (file: URI) from a throwaway apt root (`APT_CONFIG` + `Dir=`), so the host's
# apt state, sources and trusted keys are never read or written.
#
# The packages are minimal stand-ins built with dpkg-deb: what is under test is
# the repository (layout, indices, signatures, keyring, kept old versions),
# not the package contents (tests/deb/run.sh covers those). A .deb given as
# argument (CI: the real cargo-deb output) is published as the newest version
# instead of the stand-in.
#
#   VR_TELEX_APT_KEEP=1   keep the temp dir (path printed at the end)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
BUILD="$REPO/tools/apt-repo/build.sh"
PKG=vr-telex
POOL=pool/main/v/vr-telex

FAILS=0
ok() { printf 'ok    %s\n' "$*"; }
bad() {
  printf 'FAIL  %s\n' "$*"
  FAILS=$((FAILS + 1))
}
check() { # check <description> <command...>
  local what=$1
  shift
  if "$@"; then ok "$what"; else bad "$what"; fi
}
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

for tool in dpkg-deb apt-ftparchive apt-get apt-cache gpg gpgv gpgconf cmp; do
  command -v "$tool" >/dev/null || die "$tool not found"
done

# Short base path: gpg-agent socket paths have a length limit.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/vr-telex-apt.XXXXXX")
KEYS="$TMP/gnupg"
OTHER_KEYS="$TMP/gnupg-other"
HTTP_PID=
HTTP_FD=
stop_http() { # stops the test HTTP server, if this run started one
  if [ -n "$HTTP_PID" ]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
    HTTP_PID=
    exec {HTTP_FD}<&-
  fi
}
cleanup() {
  stop_http
  # Stop the agents this test started before their homes go away.
  GNUPGHOME="$KEYS" gpgconf --kill gpg-agent 2>/dev/null || true
  GNUPGHOME="$OTHER_KEYS" gpgconf --kill gpg-agent 2>/dev/null || true
  if [ "${VR_TELEX_APT_KEEP:-0}" = 1 ]; then
    echo "kept: $TMP"
  else
    rm -rf -- "$TMP"
  fi
}
trap cleanup EXIT

# --- throwaway keys (never the real repository key) -------------------------
PASSPHRASE="throwaway-$RANDOM$RANDOM-passphrase"
new_key() { # new_key <gnupghome> <passphrase or empty>; prints the fingerprint
  mkdir -p "$1"
  chmod 700 "$1"
  GNUPGHOME=$1 gpg --batch --pinentry-mode loopback --passphrase "$2" \
    --quick-gen-key "vr-telex apt test key <test@example.invalid>" ed25519 sign 1d \
    >/dev/null 2>&1
  GNUPGHOME=$1 gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr/ { print $10; exit }'
}
FPR=$(new_key "$KEYS" "$PASSPHRASE")
OTHER_FPR=$(new_key "$OTHER_KEYS" "")
if [ -z "$FPR" ] || [ -z "$OTHER_FPR" ]; then die "could not generate throwaway keys"; fi

# --- stand-in packages ------------------------------------------------------
fake_deb() { # fake_deb <version> <package> <out-file>
  local root="$TMP/pkgroot-$1-$2"
  mkdir -p "$root/DEBIAN" "$root/usr/share/doc/$2"
  printf 'Package: %s\nVersion: %s\nArchitecture: amd64\nMaintainer: test <https://example.invalid>\nDescription: apt repository test stand-in\n' \
    "$2" "$1" >"$root/DEBIAN/control"
  printf '%s %s\n' "$2" "$1" >"$root/usr/share/doc/$2/VERSION"
  dpkg-deb --root-owner-group -Zgzip -b "$root" "$3" >/dev/null
}
mkdir -p "$TMP/debs" "$TMP/debs2"
OLD_VER=0.0.0~test-1
OLD_DEB="$TMP/debs/${PKG}_${OLD_VER}_amd64.deb"
fake_deb "$OLD_VER" "$PKG" "$OLD_DEB"
if [ "$#" -ge 1 ]; then
  NEW_DEB=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
  [ -f "$NEW_DEB" ] || die "$1: no such file"
  NEW_VER=$(dpkg-deb -f "$NEW_DEB" Version)
  echo "newest version: $NEW_VER (from $1)"
else
  NEW_VER=0.0.1-1
  NEW_DEB="$TMP/debs/${PKG}_${NEW_VER}_amd64.deb"
  fake_deb "$NEW_VER" "$PKG" "$NEW_DEB"
fi

OUT="$TMP/site"
build() { # build <log> <deb>...; runs build.sh with the throwaway key
  local log=$1
  shift
  APT_GPG_KEY=$FPR APT_GPG_PASSPHRASE=$PASSPHRASE GNUPGHOME=$KEYS \
    bash "$BUILD" "$@" "$OUT" >"$log" 2>&1
}

# --- build: first release, then a second one over the same site -----------
check "build.sh publishes the first version" build "$TMP/build1.log" "$OLD_DEB"
check "build.sh adds a second version to the existing site" build "$TMP/build2.log" "$NEW_DEB"
check "old version is kept in the pool" test -f "$OUT/$POOL/$(basename "$OLD_DEB")"
check "new version is in the pool" cmp -s "$NEW_DEB" "$OUT/$POOL/$(basename "$NEW_DEB")"
for f in dists/stable/InRelease dists/stable/Release dists/stable/Release.gpg \
  dists/stable/main/binary-amd64/Packages dists/stable/main/binary-amd64/Packages.gz \
  vr-telex.asc vr-telex.gpg; do
  check "$f exists" test -s "$OUT/$f"
done
check "Packages lists both versions" \
  test "$(grep -c "^Package: $PKG\$" "$OUT/dists/stable/main/binary-amd64/Packages")" = 2
check "Packages paths point into $POOL" \
  test "$(grep -c "^Filename: $POOL/${PKG}_" "$OUT/dists/stable/main/binary-amd64/Packages")" = 2
release_has() { grep -qx "$1" "$OUT/dists/stable/Release"; }
check "Release: Suite stable" release_has "Suite: stable"
check "Release: Codename stable" release_has "Codename: stable"
check "Release: Components main" release_has "Components: main"
check "Release: Architectures amd64" release_has "Architectures: amd64"
check "Release has SHA256 sums" release_has "SHA256:"
no_secret_in() { # no_secret_in <text> <file>...
  local secret=$1
  shift
  ! grep -qF -- "$secret" "$@"
}
check "passphrase never appears in build output" \
  no_secret_in "$PASSPHRASE" "$TMP/build1.log" "$TMP/build2.log"

# --- signatures with gpgv ---------------------------------------------------
check "InRelease verifies with the published key" \
  gpgv --keyring "$OUT/vr-telex.gpg" "$OUT/dists/stable/InRelease" 2>/dev/null
check "Release.gpg verifies Release with the published key" \
  gpgv --keyring "$OUT/vr-telex.gpg" "$OUT/dists/stable/Release.gpg" "$OUT/dists/stable/Release" 2>/dev/null
inrelease_text_is_release() {
  gpgv --keyring "$OUT/vr-telex.gpg" --output - "$OUT/dists/stable/InRelease" 2>/dev/null |
    cmp -s - "$OUT/dists/stable/Release"
}
check "InRelease carries the same text as Release" inrelease_text_is_release
asc_fpr=$(GNUPGHOME=$OTHER_KEYS gpg --batch --show-keys --with-colons "$OUT/vr-telex.asc" 2>/dev/null | awk -F: '/^fpr/ { print $10; exit }')
check "vr-telex.asc is the signing key" test "$asc_fpr" = "$FPR"
check "vr-telex.asc holds no secret key" no_secret_in "PRIVATE KEY" "$OUT/vr-telex.asc"

# --- apt-get in a throwaway root -------------------------------------------
APTROOT="$TMP/aptroot"
mkdir -p "$APTROOT"/etc/apt/{apt.conf.d,sources.list.d,trusted.gpg.d,preferences.d,keyrings} \
  "$APTROOT"/var/lib/apt/lists/partial "$APTROOT"/var/cache/apt/archives/partial \
  "$APTROOT"/var/lib/dpkg "$APTROOT"/var/log/apt "$TMP/download"
: >"$APTROOT/var/lib/dpkg/status"
cat >"$APTROOT/etc/apt/apt.conf" <<EOF
Dir "$APTROOT/";
Dir::State::status "$APTROOT/var/lib/dpkg/status";
Dir::Etc::Parts "$APTROOT/etc/apt/apt.conf.d";
Dir::Bin::Methods "/usr/lib/apt/methods";
Debug::NoLocking "true";
APT::Sandbox::User "$(id -un)";
Acquire::http::Proxy "DIRECT";
EOF
# Same keyring path layout as the README, under the throwaway root.
KEYRING="$APTROOT/etc/apt/keyrings/vr-telex.gpg"
cp "$OUT/vr-telex.gpg" "$KEYRING"
OTHER_KEYRING="$TMP/other.gpg"
GNUPGHOME=$OTHER_KEYS gpg --batch --export "$OTHER_FPR" >"$OTHER_KEYRING"

# No proxy from the environment: the HTTP round talks to 127.0.0.1 only.
apt_() {
  env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
    APT_CONFIG="$APTROOT/etc/apt/apt.conf" "$@"
}
use_source() { # use_source <sources.list line>; forgets earlier indices
  printf '%s\n' "$1" >"$APTROOT/etc/apt/sources.list"
  rm -rf "$APTROOT/var/lib/apt/lists"
  mkdir -p "$APTROOT/var/lib/apt/lists/partial"
}
update_ok() { # update_ok <log>: rc 0 and no warning or error at all
  apt_ apt-get update >"$1" 2>&1 && ! grep -qE '^(W|E|Err):' "$1"
}
update_refused() { # update_refused <log> <pattern>: rc != 0 and the given reason
  ! apt_ apt-get update >"$1" 2>&1 && grep -qE "$2" "$1"
}
no_candidate() { ! apt_ apt-cache policy "$PKG" 2>/dev/null | grep -q "Candidate: [0-9]"; }

use_source "deb [signed-by=$KEYRING] file:$OUT stable main"
check "apt-get update with signed-by keyring passes the signature check" update_ok "$TMP/update-signed.log"
apt_ apt-cache policy "$PKG" >"$TMP/policy.log" 2>&1 || true
check "apt-cache policy: candidate is the newest version ($NEW_VER)" grep -qx "  Candidate: $NEW_VER" "$TMP/policy.log"
check "apt-cache policy: old version $OLD_VER still listed" grep -qE "^ +$OLD_VER 500\$" "$TMP/policy.log"
download_matches() { # apt-get download <pkg>=<ver> gives back exactly <deb>
  (cd "$TMP/download" && apt_ apt-get download "$PKG=$NEW_VER" >/dev/null 2>&1) &&
    cmp -s "$NEW_DEB" "$TMP/download/$(basename "$NEW_DEB")"
}
check "apt-get download fetches the newest .deb unchanged" download_matches

# --- the same over HTTP (apt's http method, as with GitHub Pages) -----------
# A loopback-only static server on a free port; it prints the port once bound,
# so the read below needs no retry loop. The trap stops it.
SERVE_PY='
import functools, http.server, sys
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass
handler = functools.partial(Quiet, directory=sys.argv[1])
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
print(server.server_address[1], flush=True)
server.serve_forever()
'
exec {HTTP_FD}< <(exec python3 -I -c "$SERVE_PY" "$OUT" 2>"$TMP/http.log")
HTTP_PID=$!
HTTP_PORT=
read -r -t 20 -u "$HTTP_FD" HTTP_PORT || true
[[ $HTTP_PORT =~ ^[0-9]+$ ]] || die "the test HTTP server did not start ($(cat "$TMP/http.log"))"
URL="http://127.0.0.1:$HTTP_PORT"

use_source "deb [signed-by=$KEYRING] $URL stable main"
check "HTTP: apt-get update with signed-by keyring passes the signature check" update_ok "$TMP/update-http.log"
candidate_is() { apt_ apt-cache policy "$PKG" 2>/dev/null | grep -qx "  Candidate: $1"; }
check "HTTP: candidate is the newest version ($NEW_VER)" candidate_is "$NEW_VER"
rm -f "$TMP/download/"*.deb
check "HTTP: apt-get download fetches the newest .deb unchanged" download_matches
use_source "deb $URL stable main"
check "HTTP: apt-get update without the keyring is refused" \
  update_refused "$TMP/update-http-nokey.log" 'NO_PUBKEY|is not signed'
stop_http

use_source "deb file:$OUT stable main"
check "apt-get update without the keyring is refused (NO_PUBKEY, not signed)" \
  update_refused "$TMP/update-nokey.log" 'NO_PUBKEY.*|is not signed'
check "  ... and apt offers no vr-telex" no_candidate

use_source "deb [signed-by=$OTHER_KEYRING] file:$OUT stable main"
check "apt-get update with another key is refused" \
  update_refused "$TMP/update-otherkey.log" 'NO_PUBKEY|is not signed'
check "  ... and apt offers no vr-telex" no_candidate

# Tampering: change one byte of the index after signing.
TAMPERED="$TMP/tampered"
cp -a "$OUT" "$TAMPERED"
printf '\n' >>"$TAMPERED/dists/stable/main/binary-amd64/Packages.gz"
printf '\n' >>"$TAMPERED/dists/stable/main/binary-amd64/Packages"
use_source "deb [signed-by=$KEYRING] file:$TAMPERED stable main"
check "a Packages index changed after signing is refused (hash mismatch)" \
  update_refused "$TMP/update-tampered.log" 'Hash Sum mismatch|File has unexpected size|Hashes of expected file'

cp -a "$OUT/dists/stable/InRelease" "$TMP/InRelease.orig"
sed 's/^Suite: stable$/Suite: stab1e/' "$TMP/InRelease.orig" >"$TAMPERED/dists/stable/InRelease"
rm -f "$TAMPERED/dists/stable/Release.gpg"
cp "$OUT/dists/stable/main/binary-amd64/Packages"* "$TAMPERED/dists/stable/main/binary-amd64/"
check "an InRelease changed after signing is refused (bad signature)" \
  update_refused "$TMP/update-badsig.log" 'BADSIG|signature.*(invalid|could not be verified|couldn.t be verified)|is not signed'

# --- refusals by build.sh ---------------------------------------------------
site_state() { find "$OUT" -type f -printf '%P\n' | sort | xargs -I{} sha256sum "$OUT/{}"; }
build_refused() { # build_refused <log> <reason pattern> <deb>...: fails, says why, site unchanged
  local log=$1 reason=$2 before
  shift 2
  before=$(site_state)
  ! build "$log" "$@" && grep -q -- "$reason" "$log" && [ "$(site_state)" = "$before" ]
}
build_env_refused() { # build_env_refused <env assignments...>: build.sh fails, site unchanged
  local before
  before=$(site_state)
  ! env "$@" timeout 60 bash "$BUILD" "$OLD_DEB" "$OUT" </dev/null >"$TMP/build-env.log" 2>&1 &&
    [ "$(site_state)" = "$before" ]
}

# Same name and version, different bytes.
printf 'x' >>"$TMP/pkgroot-$OLD_VER-$PKG/usr/share/doc/$PKG/VERSION"
dpkg-deb --root-owner-group -Zgzip -b "$TMP/pkgroot-$OLD_VER-$PKG" "$TMP/debs2/${PKG}_${OLD_VER}_amd64.deb" >/dev/null
check "build.sh refuses a changed file under a published name (site unchanged)" \
  build_refused "$TMP/build-changed.log" 'already in the pool' "$TMP/debs2/${PKG}_${OLD_VER}_amd64.deb"
check "build.sh accepts the identical file again (rerun of a release)" build "$TMP/build-same.log" "$OLD_DEB"

# Two inputs in one call with the same file name and different bytes.
mkdir -p "$TMP/debs3"
fake_deb 0.0.3-1 "$PKG" "$TMP/debs3/${PKG}_0.0.3-1_amd64.deb"
printf 'x' >>"$TMP/pkgroot-0.0.3-1-$PKG/usr/share/doc/$PKG/VERSION"
dpkg-deb --root-owner-group -Zgzip -b "$TMP/pkgroot-0.0.3-1-$PKG" "$TMP/debs2/${PKG}_0.0.3-1_amd64.deb" >/dev/null
check "build.sh refuses two different inputs with the same file name (site unchanged)" \
  build_refused "$TMP/build-dupname.log" 'given twice' \
  "$TMP/debs3/${PKG}_0.0.3-1_amd64.deb" "$TMP/debs2/${PKG}_0.0.3-1_amd64.deb"

fake_deb 0.0.2-1 other-pkg "$TMP/debs2/${PKG}_0.0.2-1_amd64.deb"
check "build.sh refuses a package that is not vr-telex (site unchanged)" \
  build_refused "$TMP/build-otherpkg.log" "expected 'vr-telex'" "$TMP/debs2/${PKG}_0.0.2-1_amd64.deb"
cp "$NEW_DEB" "$TMP/debs2/${PKG}_9.9.9-1_amd64.deb"
check "build.sh refuses a file name that does not match the version (site unchanged)" \
  build_refused "$TMP/build-badname.log" 'does not match Version' "$TMP/debs2/${PKG}_9.9.9-1_amd64.deb"
check "build.sh without APT_GPG_KEY fails (site unchanged)" \
  build_env_refused -u APT_GPG_KEY GNUPGHOME="$KEYS" APT_GPG_PASSPHRASE="$PASSPHRASE"
check "build.sh with a key that is not in GNUPGHOME fails (site unchanged)" \
  build_env_refused APT_GPG_KEY="$OTHER_FPR" GNUPGHOME="$KEYS"
# The agent caches the passphrase of the earlier builds; forget it first.
GNUPGHOME="$KEYS" gpgconf --kill gpg-agent
check "build.sh with a wrong passphrase fails without a prompt (site unchanged)" \
  build_env_refused APT_GPG_KEY="$FPR" GNUPGHOME="$KEYS" APT_GPG_PASSPHRASE=wrong-passphrase
check "build.sh with no passphrase for a protected key fails without a prompt (site unchanged)" \
  build_env_refused -u APT_GPG_PASSPHRASE APT_GPG_KEY="$FPR" GNUPGHOME="$KEYS"

if [ "$FAILS" -ne 0 ]; then
  echo "FAIL: $FAILS check(s) failed (logs under $TMP; rerun with VR_TELEX_APT_KEEP=1)"
  exit 1
fi
echo PASS
