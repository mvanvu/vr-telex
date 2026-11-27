#!/usr/bin/env bash
# Local test of the flat apt repository published with each GitHub Release
# (D-APT-3). Needs no root and no network.
#
# Usage: bash tests/apt/run.sh [path/to/vr-telex_<version>_amd64.deb]
#
# The repository is built with packaging/apt/build-flat-repo.sh, the script
# release.yml runs, signed with a throwaway key generated in a temp GNUPGHOME.
# A loopback HTTP server imitates GitHub: every file is requested as
#   /mvanvu/vr-telex/releases/latest/download/<name>
# (apt asks for <base>/./<name>, which GitHub answers the same way) and
# answered, like GitHub, with a 302 to /mvanvu/vr-telex/releases/download/
# <release>/<name>, then a 302 to /release-assets/<release>/<name>, where the
# bytes are; any other path is a 404. apt-get runs from a throwaway apt
# root (APT_CONFIG + Dir), so the host's apt state, sources and trusted keys
# are never read or written, with a source file made from the packaged
# packaging/deb/vr-telex.sources where only the host and the keyring path are
# swapped.
#
# The packages are stand-ins built with dpkg-deb; a .deb given as argument
# (CI: the real cargo-deb output) is published as the newest version instead.
# "apt upgrade picks up the new release" is shown with apt-get -s upgrade
# against a dpkg status file in the throwaway root that lists the older
# version as installed (and the newest version's dependencies as present).
#
#   VR_TELEX_APT_KEEP=1   keep the temp dir (path printed at the end)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
BUILD="$REPO/packaging/apt/build-flat-repo.sh"
SOURCES="$REPO/packaging/deb/vr-telex.sources"
PKG=vr-telex
GITHUB_BASE=https://github.com
DOWNLOAD_PATH=/mvanvu/vr-telex/releases/latest/download/

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

for tool in dpkg-deb apt-ftparchive apt-get apt-cache gpg gpgv gpgconf gzip cmp python3; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
[ -f "$BUILD" ] || die "missing $BUILD"
[ -f "$SOURCES" ] || die "missing $SOURCES"

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

# --- throwaway keys (never the real release key) ----------------------------
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
# The build script signs only with the pinned key (packaging/apt/vr-telex.asc
# in a release); here that is the throwaway one.
PINNED="$TMP/pinned.asc"
GNUPGHOME=$KEYS gpg --batch --armor --export "$FPR" >"$PINNED"
KEYRING="$TMP/vr-telex.gpg"
GNUPGHOME=$KEYS gpg --batch --export "$FPR" >"$KEYRING"
OTHER_KEYRING="$TMP/other.gpg"
GNUPGHOME=$OTHER_KEYS gpg --batch --export "$OTHER_FPR" >"$OTHER_KEYRING"

# --- stand-in packages ------------------------------------------------------
fake_deb() { # fake_deb <version> <package> <out-file>
  local root="$TMP/pkgroot-$1-$2"
  mkdir -p "$root/DEBIAN" "$root/usr/share/doc/$2"
  printf 'Package: %s\nVersion: %s\nArchitecture: amd64\nMaintainer: test <https://example.invalid>\nDescription: apt repository test stand-in\n' \
    "$2" "$1" >"$root/DEBIAN/control"
  printf '%s %s\n' "$2" "$1" >"$root/usr/share/doc/$2/VERSION"
  dpkg-deb --root-owner-group -Zgzip -b "$root" "$3" >/dev/null
}
mkdir -p "$TMP/debs" "$TMP/bad"
OLD_VER=0.0.1~test-1
OLD_DEB="$TMP/debs/${PKG}_${OLD_VER}_amd64.deb"
fake_deb "$OLD_VER" "$PKG" "$OLD_DEB"
if [ "$#" -ge 1 ]; then
  NEW_DEB=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
  [ -f "$NEW_DEB" ] || die "$1: no such file"
  NEW_VER=$(dpkg-deb -f "$NEW_DEB" Version)
  echo "newest version: $NEW_VER (from $1)"
else
  NEW_VER=0.0.2-1
  NEW_DEB="$TMP/debs/${PKG}_${NEW_VER}_amd64.deb"
  fake_deb "$NEW_VER" "$PKG" "$NEW_DEB"
fi
NEW_NAME=$(basename "$NEW_DEB")

# --- the build script -------------------------------------------------------
# Two GitHub Releases: rel-old holds the old version, rel-new the newest. As
# in the release workflow, the .deb sits in the directory the repo is written
# to, beside other release files.
WWW="$TMP/www"
mkdir -p "$WWW/rel-old" "$WWW/rel-new"
cp "$OLD_DEB" "$WWW/rel-old/"
cp "$NEW_DEB" "$WWW/rel-new/"
printf 'other release file\n' >"$WWW/rel-new/SHA256SUMS"
build() { # build <log> <deb> <out-dir>: the build script with the throwaway key
  APT_GPG_KEY=$FPR APT_GPG_PASSPHRASE=$PASSPHRASE GNUPGHOME=$KEYS APT_PINNED_KEY=$PINNED \
    bash "$BUILD" "$2" "$3" </dev/null >"$1" 2>&1
}
check "build script writes the repository for the old release" \
  build "$TMP/build-old.log" "$WWW/rel-old/$(basename "$OLD_DEB")" "$WWW/rel-old"
check "build script writes the repository for the newest release" \
  build "$TMP/build-new.log" "$WWW/rel-new/$NEW_NAME" "$WWW/rel-new"
REL="$WWW/rel-new"
for f in Packages Packages.gz Release InRelease Release.gpg; do
  check "$f written" test -s "$REL/$f"
done
check "the .deb and other release files are left as they were" \
  test "$(find "$REL" -type f | wc -l)" = 7 -a "$(cat "$REL/SHA256SUMS")" = "other release file"
check "build script copies no .deb" cmp -s "$NEW_DEB" "$REL/$NEW_NAME"
check "Packages has exactly one package" test "$(grep -c '^Package: ' "$REL/Packages")" = 1
check "Packages: Package $PKG, Version $NEW_VER" \
  grep -qxF "Version: $NEW_VER" "$REL/Packages"
check "Packages: Filename is the bare .deb name (the asset name)" grep -qxF "Filename: $NEW_NAME" "$REL/Packages"
deb_sha=$(sha256sum <"$NEW_DEB")
check "Packages: SHA256 of the .deb" grep -qxF "SHA256: ${deb_sha%% *}" "$REL/Packages"
check "Packages.gz unpacks to Packages" cmp -s <(gzip -dc "$REL/Packages.gz") "$REL/Packages"
release_lists() { # release_lists <file>: the Release SHA256 section holds that file's hash and size
  local sha size
  sha=$(sha256sum <"$REL/$1")
  size=$(stat -c %s "$REL/$1")
  awk -v h="${sha%% *}" -v s="$size" -v f="$1" \
    '/^[^ ]/ { in256 = ($1 == "SHA256:") } in256 && $1 == h && $2 == s && $3 == f { found = 1 } END { exit !found }' \
    "$REL/Release"
}
check "Release: SHA256 of Packages" release_lists Packages
check "Release: SHA256 of Packages.gz" release_lists Packages.gz
no_valid_until() { ! grep -q '^Valid-Until:' "$REL/Release"; }
check "Release: no Valid-Until (an old release keeps working)" no_valid_until
lists_only_indexes() {
  local listed
  listed=$(awk '/^[^ ]/ { in256 = ($1 == "SHA256:"); next } in256 { print $3 }' "$REL/Release")
  [ -n "$listed" ] && ! grep -vqxE 'Packages|Packages\.gz' <<<"$listed"
}
check "Release lists only Packages and Packages.gz" lists_only_indexes
check "Release: Architectures amd64" grep -qx 'Architectures: amd64' "$REL/Release"
check "Release has a Date" grep -q '^Date: ' "$REL/Release"
mkdir -m 700 "$TMP/gpgv-home"
gpgv_() { GNUPGHOME="$TMP/gpgv-home" gpgv "$@"; }
check "InRelease verifies with the key" gpgv_ --keyring "$KEYRING" "$REL/InRelease" 2>/dev/null
check "Release.gpg verifies Release with the key" \
  gpgv_ --keyring "$KEYRING" "$REL/Release.gpg" "$REL/Release" 2>/dev/null
inrelease_text_is_release() {
  gpgv_ --keyring "$KEYRING" --output - "$REL/InRelease" 2>/dev/null | cmp -s - "$REL/Release"
}
check "InRelease carries the same text as Release" inrelease_text_is_release
check "Release.gpg is armored" grep -q -- '-----BEGIN PGP SIGNATURE-----' "$REL/Release.gpg"
no_secret_in() { # no_secret_in <text> <file>...
  local secret=$1
  shift
  ! grep -qF -- "$secret" "$@"
}
check "passphrase never appears in build output" \
  no_secret_in "$PASSPHRASE" "$TMP/build-old.log" "$TMP/build-new.log"

# --- the build script refuses ------------------------------------------------
REFUSE="$TMP/refuse"
mkdir -p "$REFUSE"
cp "$OLD_DEB" "$REFUSE/"
dir_state() { find "$1" -type f -printf '%P\n' | sort | while IFS= read -r f; do sha256sum "$1/$f"; done; }
refused() { # refused <log> <reason pattern> <env assignments...> -- <deb>: fails, says why, dir unchanged
  local log=$1 reason=$2 before args=()
  shift 2
  while [ "$1" != -- ]; do
    args+=("$1")
    shift
  done
  shift
  before=$(dir_state "$REFUSE")
  ! env "${args[@]}" timeout 60 bash "$BUILD" "$1" "$REFUSE" </dev/null >"$log" 2>&1 &&
    grep -qE -- "$reason" "$log" && [ "$(dir_state "$REFUSE")" = "$before" ]
}
GOOD_ENV=(APT_GPG_KEY="$FPR" APT_GPG_PASSPHRASE="$PASSPHRASE" GNUPGHOME="$KEYS" APT_PINNED_KEY="$PINNED")
fake_deb 0.0.3-1 other-pkg "$TMP/bad/${PKG}_0.0.3-1_amd64.deb"
check "refuses a package that is not $PKG (nothing written)" \
  refused "$TMP/r-otherpkg.log" "expected '$PKG'" "${GOOD_ENV[@]}" -- "$TMP/bad/${PKG}_0.0.3-1_amd64.deb"
cp "$OLD_DEB" "$TMP/bad/${PKG}_9.9.9-1_amd64.deb"
check "refuses a file name that does not match the version (nothing written)" \
  refused "$TMP/r-name.log" 'does not match Version' "${GOOD_ENV[@]}" -- "$TMP/bad/${PKG}_9.9.9-1_amd64.deb"
check "refuses a missing .deb (nothing written)" \
  refused "$TMP/r-missing.log" 'no such file' "${GOOD_ENV[@]}" -- "$TMP/bad/${PKG}_1.0.0-1_amd64.deb"
check "refuses without APT_GPG_KEY (nothing written)" \
  refused "$TMP/r-nokey.log" 'APT_GPG_KEY' -u APT_GPG_KEY GNUPGHOME="$KEYS" APT_PINNED_KEY="$PINNED" -- "$REFUSE/$(basename "$OLD_DEB")"
check "refuses a signing key that is not the pinned one (nothing written)" \
  refused "$TMP/r-unpinned.log" 'is not the pinned key' \
  APT_GPG_KEY="$OTHER_FPR" GNUPGHOME="$OTHER_KEYS" APT_PINNED_KEY="$PINNED" -- "$REFUSE/$(basename "$OLD_DEB")"
check "refuses a key that is not in GNUPGHOME (nothing written)" \
  refused "$TMP/r-absent.log" 'no secret key' \
  APT_GPG_KEY="$OTHER_FPR" GNUPGHOME="$KEYS" APT_PINNED_KEY="$PINNED" -- "$REFUSE/$(basename "$OLD_DEB")"
# The agent caches the passphrase of the earlier builds; forget it first.
GNUPGHOME="$KEYS" gpgconf --kill gpg-agent
check "a wrong passphrase fails without a prompt (nothing written)" \
  refused "$TMP/r-wrongpass.log" 'cannot sign' \
  APT_GPG_KEY="$FPR" APT_GPG_PASSPHRASE=wrong-passphrase GNUPGHOME="$KEYS" APT_PINNED_KEY="$PINNED" -- "$REFUSE/$(basename "$OLD_DEB")"
check "no passphrase for a protected key fails without a prompt (nothing written)" \
  refused "$TMP/r-nopass.log" 'cannot sign' \
  -u APT_GPG_PASSPHRASE APT_GPG_KEY="$FPR" GNUPGHOME="$KEYS" APT_PINNED_KEY="$PINNED" -- "$REFUSE/$(basename "$OLD_DEB")"
check "  ... and the wrong passphrase is not printed" no_secret_in wrong-passphrase "$TMP/r-wrongpass.log"

# --- a GitHub-like server over loopback -------------------------------------
# $WWW/latest is a symlink to the release that is "latest"; the test moves it
# to publish a new release. The server prints its port once bound, so the
# read below needs no retry loop; the trap stops it.
SERVE_PY='
import http.server, os, sys, urllib.parse
root, log = sys.argv[1], sys.argv[2]
LATEST = "/mvanvu/vr-telex/releases/latest/download/"
TAGGED = "/mvanvu/vr-telex/releases/download/"
ASSETS = "/release-assets/"
def simple(name):
    return name not in ("", ".", "..") and "/" not in name
class GitHubLike(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args):
        pass
    def answer(self, body):
        path = urllib.parse.urlsplit(self.path).path
        status, headers, data = 404, {}, b"Not Found"
        if path.startswith(LATEST):
            name = path[len(LATEST):]
            # GitHub answers <base>/./<name> like <base>/<name>; apt asks for
            # the former with Suites: ./
            if name.startswith("./"):
                name = name[2:]
            release = os.path.basename(os.path.realpath(os.path.join(root, "latest")))
            if simple(name) and os.path.isfile(os.path.join(root, release, name)):
                status, data = 302, b""
                headers["Location"] = "http://%s%s%s/%s" % (self.headers["Host"], TAGGED, release, name)
        elif path.startswith(TAGGED):
            parts = path[len(TAGGED):].split("/")
            if len(parts) == 2 and all(simple(p) for p in parts) and parts[0] != "latest":
                if os.path.isfile(os.path.join(root, *parts)):
                    status, data = 302, b""
                    headers["Location"] = "http://%s%s%s/%s?token=t" % (self.headers["Host"], ASSETS, parts[0], parts[1])
        elif path.startswith(ASSETS):
            parts = path[len(ASSETS):].split("/")
            if len(parts) == 2 and all(simple(p) for p in parts) and parts[0] != "latest":
                file = os.path.join(root, *parts)
                if os.path.isfile(file):
                    with open(file, "rb") as f:
                        status, data = 200, f.read()
                    headers["Content-Type"] = "application/octet-stream"
        with open(log, "a") as f:
            f.write("%s %s %d\n" % (self.command, path, status))
        self.send_response(status)
        for k, v in headers.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if body:
            self.wfile.write(data)
    def do_GET(self):
        self.answer(True)
    def do_HEAD(self):
        self.answer(False)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), GitHubLike)
print(server.server_address[1], flush=True)
server.serve_forever()
'
publish() { ln -sfn "$1" "$WWW/latest"; } # publish <release dir name>
publish rel-old
HTTP_LOG="$TMP/http.log"
: >"$HTTP_LOG"
exec {HTTP_FD}< <(exec python3 -I -c "$SERVE_PY" "$WWW" "$HTTP_LOG" 2>"$TMP/http.err")
HTTP_PID=$!
HTTP_PORT=
read -r -t 20 -u "$HTTP_FD" HTTP_PORT || true
[[ $HTTP_PORT =~ ^[0-9]+$ ]] || die "the test HTTP server did not start ($(cat "$TMP/http.err"))"
LOCAL_BASE="http://127.0.0.1:$HTTP_PORT"

# --- apt-get in a throwaway root ----------------------------------------------
APTROOT="$TMP/aptroot"
mkdir -p "$APTROOT"/etc/apt/{apt.conf.d,sources.list.d,trusted.gpg.d,preferences.d} \
  "$APTROOT"/var/lib/apt/lists/partial "$APTROOT"/var/cache/apt/archives/partial \
  "$APTROOT"/var/lib/dpkg "$APTROOT"/var/log/apt "$TMP/download"
: >"$APTROOT/etc/apt/sources.list"
: >"$APTROOT/var/lib/dpkg/status"
cat >"$APTROOT/etc/apt/apt.conf" <<EOF
Dir "$APTROOT/";
Dir::State::status "$APTROOT/var/lib/dpkg/status";
Dir::Etc::Parts "$APTROOT/etc/apt/apt.conf.d";
Dir::Bin::Methods "/usr/lib/apt/methods";
APT::Architecture "amd64";
APT::Architectures { "amd64"; };
Debug::NoLocking "true";
APT::Sandbox::User "$(id -un)";
Acquire::http::Proxy "DIRECT";
Acquire::Retries "0";
EOF
# No proxy from the environment: the server is on 127.0.0.1.
apt_() {
  env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
    APT_CONFIG="$APTROOT/etc/apt/apt.conf" "$@"
}

# The packaged source with the host and the keyring swapped, nothing else.
grep -qxF "URIs: $GITHUB_BASE$DOWNLOAD_PATH" "$SOURCES" ||
  die "$SOURCES: URIs is not $GITHUB_BASE$DOWNLOAD_PATH"
grep -qx 'Signed-By: /usr/share/keyrings/vr-telex.gpg' "$SOURCES" ||
  die "$SOURCES: Signed-By is not /usr/share/keyrings/vr-telex.gpg"
use_source() { # use_source <keyring path, or - for no Signed-By line>; forgets earlier indices
  if [ "$1" = - ]; then
    sed -e "s|^URIs: $GITHUB_BASE/|URIs: $LOCAL_BASE/|" -e '/^Signed-By:/d' "$SOURCES"
  else
    sed -e "s|^URIs: $GITHUB_BASE/|URIs: $LOCAL_BASE/|" -e "s|^Signed-By: .*|Signed-By: $1|" "$SOURCES"
  fi >"$APTROOT/etc/apt/sources.list.d/vr-telex.sources"
  rm -rf "$APTROOT/var/lib/apt/lists" "$APTROOT"/var/cache/apt/*.bin
  mkdir -p "$APTROOT/var/lib/apt/lists/partial"
}
update_ok() { # update_ok <log>: rc 0 and no warning or error at all
  apt_ apt-get update >"$1" 2>&1 && ! grep -qE '^(W|E|Err):' "$1"
}
update_refused() { # update_refused <log> <pattern>: rc != 0 and the given reason
  ! apt_ apt-get update >"$1" 2>&1 && grep -qE "$2" "$1"
}
# Command output is captured before grep reads it: with pipefail, `cmd | grep -q`
# fails at random when grep exits before cmd has written everything (SIGPIPE).
policy() { apt_ apt-cache policy "$PKG" 2>/dev/null; }
policy_has() { # policy_has <grep options and pattern...>: apt-cache ran and its output matches
  local out
  out=$(policy) || return 1
  grep "$@" <<<"$out"
}
candidate_is() { policy_has -qx "  Candidate: $1"; }
no_candidate() { # no version from the repository
  local out
  out=$(policy) || return 1
  ! grep -qF "$LOCAL_BASE" <<<"$out"
}
served() { grep -qxE "$1" "$HTTP_LOG"; } # served "<METHOD> <path> <status>" (ERE)

use_source "$KEYRING"
check "source file: same form as packaging/deb/vr-telex.sources (only host and keyring differ)" \
  test "$(grep -c . "$APTROOT/etc/apt/sources.list.d/vr-telex.sources")" = "$(grep -c . "$SOURCES")"
check "apt-get update with the Signed-By keyring passes the signature check" update_ok "$TMP/update-old.log"
check "InRelease was fetched through the latest/download redirect" \
  served "GET ${DOWNLOAD_PATH}(\./)?InRelease 302"
check "  ... then the tagged release URL redirected" \
  served "GET /mvanvu/vr-telex/releases/download/rel-old/InRelease 302"
check "  ... and the asset was served" served "GET /release-assets/rel-old/InRelease 200"
check "apt-cache policy: candidate is the latest release's version ($OLD_VER)" candidate_is "$OLD_VER"

# The older version is installed (dpkg status of the throwaway root) together
# with whatever the newest version depends on, so apt can plan the upgrade.
{
  printf 'Package: %s\nStatus: install ok installed\nPriority: optional\nSection: utils\nArchitecture: amd64\nVersion: %s\nMaintainer: test\nDescription: stand-in\n\n' \
    "$PKG" "$OLD_VER"
  dpkg-deb -f "$NEW_DEB" Depends | tr ',' '\n' | sed -E 's/\|.*//; s/\(.*//; s/:any//; s/^ +//; s/ +$//' |
    { grep . || true; } | sort -u | while IFS= read -r dep; do
    printf 'Package: %s\nStatus: install ok installed\nPriority: optional\nArchitecture: amd64\nMulti-Arch: same\nVersion: 999:0\nMaintainer: test\nDescription: stand-in dependency\n\n' "$dep"
  done
} >"$APTROOT/var/lib/dpkg/status"
upgrade_plan() { apt_ apt-get -s -o Debug::NoLocking=true upgrade 2>&1; }
plans_upgrade() {
  local out
  out=$(upgrade_plan) || return 1
  grep -q "^Inst $PKG \[$OLD_VER\] ($NEW_VER " <<<"$out"
}
nothing_to_upgrade() {
  local out
  out=$(upgrade_plan) || return 1
  ! grep -q "^Inst $PKG" <<<"$out" && grep -q '^0 upgraded' <<<"$out"
}
check "installed = latest release: apt-get -s upgrade has nothing to do" nothing_to_upgrade

publish rel-new
check "after a new release: apt-get update passes" update_ok "$TMP/update-new.log"
installed_old_candidate_new() { policy_has -qx "  Installed: $OLD_VER" && candidate_is "$NEW_VER"; }
check "apt-cache policy: installed $OLD_VER, candidate $NEW_VER" installed_old_candidate_new
check "apt-get -s upgrade upgrades $PKG $OLD_VER -> $NEW_VER" plans_upgrade
download_matches() { # apt-get download gives back exactly the newest .deb
  rm -f "$TMP/download/"*.deb
  (cd "$TMP/download" && apt_ apt-get download "$PKG=$NEW_VER" >"$TMP/download.log" 2>&1) &&
    cmp -s "$NEW_DEB" "$TMP/download/$NEW_NAME"
}
check "apt-get download fetches the newest .deb unchanged" download_matches
check "  ... through the latest/download redirect" served "GET $DOWNLOAD_PATH(\./)?${NEW_NAME//./\\.} 302"
check "  ... from the newest release's assets" served "GET /release-assets/rel-new/${NEW_NAME//./\\.} 200"

# --- refusals -------------------------------------------------------------------
# A source without its keyring: what `apt remove vr-telex` leaves behind when
# the source file stays (see packaging/deb/postrm).
use_source /nonexistent/vr-telex.gpg
check "keyring file missing: apt-get update is refused" \
  update_refused "$TMP/update-nokeyring.log" 'NO_PUBKEY|is not signed|not readable|not exist'
check "  ... and apt offers no $PKG" no_candidate
use_source -
check "no Signed-By and no trusted key: apt-get update is refused" \
  update_refused "$TMP/update-nosignedby.log" 'NO_PUBKEY|is not signed'
check "  ... and apt offers no $PKG" no_candidate
use_source "$OTHER_KEYRING"
check "another key: apt-get update is refused" \
  update_refused "$TMP/update-otherkey.log" 'NO_PUBKEY|is not signed'
check "  ... and apt offers no $PKG" no_candidate

# Tampered copies of the newest release, published as latest.
tampered() { # tampered <name>: a copy of rel-new, published
  rm -rf "${WWW:?}/$1"
  cp -a "$WWW/rel-new" "$WWW/$1"
  publish "$1"
}
tampered rel-packages
printf 'Description: planted\n' >>"$WWW/rel-packages/Packages"
gzip -9nc "$WWW/rel-packages/Packages" >"$WWW/rel-packages/Packages.gz"
use_source "$KEYRING"
check "a Packages changed after signing is refused (hash mismatch)" \
  update_refused "$TMP/update-tampered.log" 'Hash Sum mismatch|File has unexpected size|Hashes of expected file'
check "  ... and apt offers no $PKG" no_candidate

tampered rel-inrelease
sed -i 's/^Architectures: amd64$/Architectures: amd64 i386/' "$WWW/rel-inrelease/InRelease"
rm -f "$WWW/rel-inrelease/Release.gpg"
use_source "$KEYRING"
check "an InRelease changed after signing is refused (bad signature)" \
  update_refused "$TMP/update-badsig.log" 'BADSIG|signature.*(invalid|could not be verified|couldn.t be verified)|is not signed'

tampered rel-unsigned
rm -f "$WWW/rel-unsigned/InRelease" "$WWW/rel-unsigned/Release.gpg"
use_source "$KEYRING"
check "a release without signatures is refused" \
  update_refused "$TMP/update-unsigned.log" 'is not signed|does not have a Release file|no longer signed'

tampered rel-deb
printf 'x' >>"$WWW/rel-deb/$NEW_NAME"
use_source "$KEYRING"
deb_refused() {
  rm -f "$TMP/download/"*.deb
  update_ok "$TMP/update-deb.log" &&
    ! (cd "$TMP/download" && apt_ apt-get download "$PKG=$NEW_VER" >"$TMP/download-bad.log" 2>&1) &&
    grep -qE 'Hash Sum mismatch|File has unexpected size|Hashes of expected file|Size mismatch' "$TMP/download-bad.log" &&
    [ ! -e "$TMP/download/$NEW_NAME" ]
}
check "a .deb changed after signing is refused at download (hash mismatch)" deb_refused
stop_http

# --- the release workflow uses this script and publishes its files -------------
WF="$REPO/.github/workflows/release.yml"
check "release.yml runs packaging/apt/build-flat-repo.sh" grep -q 'packaging/apt/build-flat-repo.sh' "$WF"
uploads_repo() { grep -qE '^ +files=\(.*Packages Packages\.gz Release InRelease Release\.gpg' "$WF"; }
check "release.yml uploads Packages Packages.gz Release InRelease Release.gpg" uploads_repo

echo
if [ "$FAILS" -ne 0 ]; then
  echo "FAIL: $FAILS check(s) failed (logs under $TMP; rerun with VR_TELEX_APT_KEEP=1)"
  exit 1
fi
echo PASS
