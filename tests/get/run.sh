#!/usr/bin/env bash
# Test of the release install/update script packaging/get/vr-telex-install.sh
# (D-APT-2). Needs no network, no root and no real apt.
#
# Usage: bash tests/get/run.sh
#
# Fake releases (a stand-in .deb built with dpkg-deb, SHA256SUMS signed with a
# throwaway key) are served from a temp dir over 127.0.0.1 by python3's
# http.server, which the trap stops. sudo, apt, vr-telex-setup, dpkg-query,
# and for some cases dpkg and id, are stubs on PATH that log their calls, so
# nothing is installed and no session is touched. The script runs under
# /bin/sh (dash on Ubuntu) with env -i, a throwaway HOME and TMPDIR.
#
#   VR_TELEX_GET_KEEP=1   keep the temp dir (path printed at the end)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
SCRIPT="$REPO/packaging/get/vr-telex-install.sh"
EMBED="$REPO/packaging/get/embed-key.sh"
PINNED_ASC="$REPO/packaging/apt/vr-telex.asc"
PINNED_FPR=2C30E91F97E5A566BEFF373736C30B9165329B85
OFFICIAL_URL=https://github.com/mvanvu/vr-telex/releases/latest/download
PKG=vr-telex
VER=0.9.0-1
DEB_NAME="${PKG}_${VER}_amd64.deb"

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

for tool in dpkg-deb gpg gpgconf gpgv sha256sum python3 wget curl cmp; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
[ -f "$SCRIPT" ] || die "missing $SCRIPT"

# Short base path: gpg-agent socket paths have a length limit.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/vr-telex-get.XXXXXX")
KEYS="$TMP/gnupg"
OTHER_KEYS="$TMP/gnupg-other"
HTTP_PID=
HTTP_FD=
stop_http() {
  if [ -n "$HTTP_PID" ]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
    HTTP_PID=
    exec {HTTP_FD}<&-
  fi
}
cleanup() {
  stop_http
  GNUPGHOME="$KEYS" gpgconf --kill gpg-agent 2>/dev/null || true
  GNUPGHOME="$OTHER_KEYS" gpgconf --kill gpg-agent 2>/dev/null || true
  if [ "${VR_TELEX_GET_KEEP:-0}" = 1 ]; then
    echo "kept: $TMP"
  else
    rm -rf -- "$TMP"
  fi
}
trap cleanup EXIT

# --- the embedded key -------------------------------------------------------
embedded_key() { sed -n '/^-----BEGIN PGP PUBLIC KEY BLOCK-----$/,/^-----END PGP PUBLIC KEY BLOCK-----$/p' "$SCRIPT"; }
check "the script embeds exactly packaging/apt/vr-telex.asc" cmp -s <(embedded_key) "$PINNED_ASC"
mkdir -m 700 "$TMP/show"
asc_fpr=$(GNUPGHOME=$TMP/show gpg --batch --show-keys --with-colons "$PINNED_ASC" 2>/dev/null | awk -F: '/^fpr/ { print $10 }')
check "packaging/apt/vr-telex.asc holds one key, fingerprint $PINNED_FPR" test "$asc_fpr" = "$PINNED_FPR"
# The script dearmors without gpg (sed + base64); on the real key that must
# give exactly what gpg --dearmor gives. Tests only reach the decode with the
# throwaway key, so the real one is checked here with the script's own line.
DEARMOR="sed -e '1,/^\$/d' -e '/^=/d' -e '/^-----END /d'"
check "the script dearmors with: $DEARMOR | base64 -d" grep -qF "$DEARMOR |" "$SCRIPT"
real_key_decodes() {
  GNUPGHOME=$TMP/show gpg --batch --dearmor <"$PINNED_ASC" >"$TMP/pinned.gpg" 2>/dev/null &&
    embedded_key | sed -e '1,/^$/d' -e '/^=/d' -e '/^-----END /d' | base64 -d | cmp -s - "$TMP/pinned.gpg"
}
check "the embedded key decodes to the same bytes as gpg --dearmor" real_key_decodes
GNUPGHOME="$TMP/show" gpgconf --kill gpg-agent 2>/dev/null || true
check "embed-key.sh --check passes on the committed script" bash "$EMBED" --check
cp "$SCRIPT" "$TMP/stale.sh"
perl -pi -e 's/^mQINB/mQINC/' "$TMP/stale.sh"
embed_check_fails_on_stale() { ! bash "$EMBED" --check "$TMP/stale.sh" "$PINNED_ASC" >/dev/null 2>&1; }
check "embed-key.sh --check fails on a script with a changed key" embed_check_fails_on_stale
embed_regenerates() { bash "$EMBED" "$TMP/stale.sh" "$PINNED_ASC" >/dev/null && cmp -s "$TMP/stale.sh" "$SCRIPT"; }
check "embed-key.sh writes the key back (result equals the committed script)" embed_regenerates

readme_has() { grep -qxF -- "$1" "$REPO/README.md"; }
check "README: install line" readme_has \
  "wget -qO /tmp/vr-telex-install.sh $OFFICIAL_URL/vr-telex-install.sh && sh /tmp/vr-telex-install.sh"
check "README: update command" readme_has "vr-telex-update"
check "README: remove commands" readme_has "vr-telex-setup --remove"
no_apt_repo_left() { ! grep -qE 'github\.io|gh-pages|sources\.list|keyrings' "$REPO/README.md"; }
check "README: no apt repository left" no_apt_repo_left

# --- throwaway keys (never the real release key) -----------------------------
new_key() { # new_key <gnupghome>; prints the fingerprint
  mkdir -p "$1"
  chmod 700 "$1"
  GNUPGHOME=$1 gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "vr-telex get test key <test@example.invalid>" ed25519 sign 1d >/dev/null 2>&1
  GNUPGHOME=$1 gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr/ { print $10; exit }'
}
FPR=$(new_key "$KEYS")
OTHER_FPR=$(new_key "$OTHER_KEYS")
if [ -z "$FPR" ] || [ -z "$OTHER_FPR" ]; then die "could not generate throwaway keys"; fi
TEST_KEY="$TMP/test-key.asc"
GNUPGHOME=$KEYS gpg --batch --armor --export "$FPR" >"$TEST_KEY"

# --- fake releases ----------------------------------------------------------
fake_deb() { # fake_deb <version> <out-file>
  local root="$TMP/pkgroot-$1"
  mkdir -p "$root/DEBIAN" "$root/usr/share/doc/$PKG"
  printf 'Package: %s\nVersion: %s\nArchitecture: amd64\nMaintainer: test <https://example.invalid>\nDescription: install script test stand-in\n' \
    "$PKG" "$1" >"$root/DEBIAN/control"
  printf '%s %s\n' "$PKG" "$1" >"$root/usr/share/doc/$PKG/VERSION"
  dpkg-deb --root-owner-group -Zgzip -b "$root" "$2" >/dev/null
}
SRV="$TMP/srv"
mkdir -p "$SRV"
DEB="$TMP/$DEB_NAME"
fake_deb "$VER" "$DEB"
DEB_SHA=$(sha256sum "$DEB" | cut -d' ' -f1)

sign() { # sign <gnupghome> <dir>: SHA256SUMS.asc as the release workflow makes it
  GNUPGHOME=$1 gpg --batch --yes --pinentry-mode loopback --passphrase '' \
    --armor --detach-sign --output "$2/SHA256SUMS.asc" "$2/SHA256SUMS" 2>/dev/null
}
release() { # release <name> <mode>
  local d="$SRV/$1"
  mkdir -p "$d"
  cp "$DEB" "$SCRIPT" "$d/"
  (cd "$d" && sha256sum "$DEB_NAME" vr-telex-install.sh >SHA256SUMS)
  case $2 in
  good) sign "$KEYS" "$d" ;;
  badsig) # changed after signing
    sign "$KEYS" "$d"
    printf '%s  extra.txt\n' "$DEB_SHA" >>"$d/SHA256SUMS"
    ;;
  otherkey) sign "$OTHER_KEYS" "$d" ;;
  badsum) # signed, but the listed hash is not the file's
    sed -i "s/^$DEB_SHA /$(printf '%064d' 0) /" "$d/SHA256SUMS"
    sign "$KEYS" "$d"
    ;;
  nodeb) # signed list without the .deb
    sed -i "/ $DEB_NAME\$/d" "$d/SHA256SUMS"
    sign "$KEYS" "$d"
    ;;
  twodebs) # signed list naming two packages
    printf '%s  %s\n' "$DEB_SHA" "${PKG}_9.9.9-1_amd64.deb" >>"$d/SHA256SUMS"
    sign "$KEYS" "$d"
    ;;
  pathdeb) # a .deb name with a path in it
    printf '%s  ../%s\n' "$DEB_SHA" "$DEB_NAME" >"$d/SHA256SUMS"
    sign "$KEYS" "$d"
    ;;
  nosig) ;;
  missingdeb) # listed and signed, but the file is not on the server
    sign "$KEYS" "$d"
    rm -f "$d/$DEB_NAME"
    ;;
  empty) rm -f "$d"/* ;;
  *) die "unknown release mode $2" ;;
  esac
}
for m in good badsig otherkey badsum nodeb twodebs pathdeb nosig missingdeb empty; do release "$m" "$m"; done

# Loopback-only static server on a free port; it prints the port once bound.
# Requests are logged (stderr) so the test can tell which files were fetched.
SERVE_PY='
import functools, http.server, sys
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
print(server.server_address[1], flush=True)
server.serve_forever()
'
HTTP_LOG="$TMP/http.log"
exec {HTTP_FD}< <(exec python3 -I -c "$SERVE_PY" "$SRV" 2>"$HTTP_LOG")
HTTP_PID=$!
HTTP_PORT=
read -r -t 20 -u "$HTTP_FD" HTTP_PORT || true
[[ $HTTP_PORT =~ ^[0-9]+$ ]] || die "the test HTTP server did not start ($(cat "$HTTP_LOG"))"
URL="http://127.0.0.1:$HTTP_PORT"

# --- stubs ------------------------------------------------------------------
STUBS="$TMP/stubs"
NONET="$TMP/stubs-nonet"
CALLS="$TMP/calls.log"
mkdir -p "$STUBS" "$NONET" "$TMP/home"
: >"$CALLS"
cat >"$STUBS/sudo" <<EOF
#!/bin/sh
echo "sudo \$*" >>"$CALLS"
for last; do :; done
if [ -f "\$last" ]; then
  echo "deb-at-call \$(sha256sum "\$last" | cut -d' ' -f1) file=\$(stat -c %a "\$last") dir=\$(stat -c %a "\$(dirname "\$last")")" >>"$CALLS"
fi
exit "\${FAKE_SUDO_RC:-0}"
EOF
cat >"$STUBS/apt" <<EOF
#!/bin/sh
echo "apt \$*" >>"$CALLS"
exit 1
EOF
cat >"$STUBS/vr-telex-setup" <<EOF
#!/bin/sh
echo "vr-telex-setup \$*" >>"$CALLS"
exit "\${FAKE_SETUP_RC:-0}"
EOF
# What dpkg-query -W -f '\${Status} \${Version}' prints for vr-telex.
cat >"$STUBS/dpkg-query" <<EOF
#!/bin/sh
if [ -n "\${FAKE_INSTALLED:-}" ]; then
  printf 'install ok installed %s' "\$FAKE_INSTALLED"
  exit 0
fi
echo "dpkg-query: no packages found matching vr-telex" >&2
exit 1
EOF
cat >"$STUBS/dpkg" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --print-architecture ] && [ -n "${FAKE_ARCH:-}" ]; then
  echo "$FAKE_ARCH"
  exit 0
fi
exec /usr/bin/dpkg "$@"
EOF
cat >"$STUBS/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -u ] && [ -n "${FAKE_UID:-}" ]; then
  echo "$FAKE_UID"
  exit 0
fi
exec /usr/bin/id "$@"
EOF
for t in wget curl; do
  printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 1\n' "$t" "$CALLS" >"$NONET/$t"
done
chmod 755 "$STUBS"/* "$NONET"/*
# A PATH without wget, so the curl branch runs.
NOWGET="$TMP/bin-nowget"
mkdir -p "$NOWGET"
for f in /usr/bin/* /usr/sbin/*; do
  n=${f##*/}
  [ "$n" = wget ] || [ -e "$NOWGET/$n" ] || ln -s "$f" "$NOWGET/$n"
done
SYS_PATH=/usr/sbin:/usr/bin:/sbin:/bin

# A key the user's own GnuPG trusts must not count: plant the other key in
# the throwaway HOME's default gpgv keyring.
mkdir -p "$TMP/home/.gnupg"
chmod 700 "$TMP/home/.gnupg"
GNUPGHOME=$OTHER_KEYS gpg --batch --export "$OTHER_FPR" >"$TMP/home/.gnupg/trustedkeys.gpg"

RUN_TMP="$TMP/run-tmp"
OUT="$TMP/out"
mkdir -p "$OUT"
# run_get <log name> <path dirs> <env assignments...>; rc in $RC, output in $OUT/<name>.log
run_get() {
  local name=$1 path=$2
  shift 2
  : >"$CALLS"
  rm -rf -- "$RUN_TMP"
  mkdir -p "$RUN_TMP"
  REQ_BEFORE=$(wc -l <"$HTTP_LOG")
  RC=0
  env -i PATH="$path" HOME="$TMP/home" TMPDIR="$RUN_TMP" LANG=C.UTF-8 "$@" \
    sh "$SCRIPT" </dev/null >"$OUT/$name.log" 2>&1 || RC=$?
  LOG="$OUT/$name.log"
}
run_local() { # run_local <name> <release dir> <env...>: loopback release + test key
  local name=$1 rel=$2
  shift 2
  run_get "$name" "$STUBS:$SYS_PATH" VR_TELEX_RELEASE_URL="$URL/$rel" VR_TELEX_TEST_KEY="$TEST_KEY" "$@"
}
no_sudo() { ! grep -qE '^(sudo|apt) ' "$CALLS"; }
no_setup() { ! grep -q '^vr-telex-setup' "$CALLS"; }
tmp_clean() { [ -z "$(ls -A "$RUN_TMP")" ]; }
failed() { [ "$RC" -ne 0 ]; }
said() { grep -qE -- "$1" "$LOG"; }
fetched() { tail -n +"$((REQ_BEFORE + 1))" "$HTTP_LOG" | grep -q "GET /$1 "; }
fetched_nothing() { [ "$(wc -l <"$HTTP_LOG")" -eq "$REQ_BEFORE" ]; }
refused() { # refused <case> <reason pattern>: failed, said why, no sudo, no setup, temp dir gone
  check "$1: exits non-zero" failed
  check "$1: says why ($2)" said "$2"
  check "$1: no sudo / apt call" no_sudo
  check "$1: vr-telex-setup not run" no_setup
  check "$1: temp dir removed" tmp_clean
  if failed && said "$2" && no_sudo && no_setup && tmp_clean; then :; else sed 's/^/      | /' "$LOG"; fi
}

# --- happy path (wget) ----------------------------------------------------------
run_local happy good
check "happy (wget): exits 0" test "$RC" -eq 0
[ "$RC" -eq 0 ] || sed 's/^/      | /' "$LOG"
sudo_line=$(grep '^sudo ' "$CALLS" || true)
abs_deb_call() { [[ $sudo_line =~ ^sudo\ apt\ install\ -y\ $RUN_TMP/[^/\ ]+/$DEB_NAME$ ]]; }
check "happy: one call 'sudo apt install -y <abs temp path>/$DEB_NAME'" abs_deb_call
check "happy: exactly one sudo call" test "$(grep -c '^sudo ' "$CALLS")" = 1
check "happy: the .deb apt gets is the released one (sha256)" grep -q "^deb-at-call $DEB_SHA " "$CALLS"
check "happy: _apt can read it (file 644, dir 755)" grep -q "^deb-at-call $DEB_SHA file=644 dir=755\$" "$CALLS"
setup_after_sudo() { [ "$(grep -E '^(sudo|vr-telex-setup)' "$CALLS" | cut -d' ' -f1 | tr '\n' ' ')" = "sudo vr-telex-setup " ]; }
check "happy: vr-telex-setup runs once, after apt, with no arguments" setup_after_sudo
check "happy: vr-telex-setup gets no arguments" grep -qx 'vr-telex-setup ' "$CALLS"
check "happy: temp dir removed" tmp_clean
check "happy: says what it installed" said "installed vr-telex $VER"
check "happy: names the update command" said "vr-telex-update"
check "happy: fetched SHA256SUMS, SHA256SUMS.asc and the .deb" \
  eval 'fetched good/SHA256SUMS && fetched good/SHA256SUMS.asc && fetched good/'"$DEB_NAME"

# --- happy path (curl, no wget on PATH) ---------------------------------------
run_get happy-curl "$STUBS:$NOWGET" VR_TELEX_RELEASE_URL="$URL/good" VR_TELEX_TEST_KEY="$TEST_KEY"
check "happy (curl only): exits 0" test "$RC" -eq 0
[ "$RC" -eq 0 ] || sed 's/^/      | /' "$LOG"
check "happy (curl only): apt gets the released .deb" grep -q "^deb-at-call $DEB_SHA " "$CALLS"
check "happy (curl only): fetched the .deb" fetched "good/$DEB_NAME"
check "happy (curl only): temp dir removed" tmp_clean

# --- update paths -------------------------------------------------------------
run_local uptodate good FAKE_INSTALLED="$VER"
check "up to date: exits 0" test "$RC" -eq 0
check "up to date: says already up to date" said "already up to date"
check "up to date: no sudo / apt call" no_sudo
check "up to date: vr-telex-setup not run" no_setup
not_fetched_deb() { ! fetched "good/$DEB_NAME"; }
check "up to date: the .deb is not downloaded" not_fetched_deb
check "up to date: temp dir removed" tmp_clean

run_local older good FAKE_INSTALLED=0.8.0-1
check "older installed: exits 0" test "$RC" -eq 0
abs_deb_call_now() { sudo_line=$(grep '^sudo ' "$CALLS" || true) && abs_deb_call; }
check "older installed: installs the latest (sudo apt install)" abs_deb_call_now
check "older installed: runs vr-telex-setup" grep -qx 'vr-telex-setup ' "$CALLS"

run_local newer good FAKE_INSTALLED=1.0.0-1
check "newer installed: exits 0" test "$RC" -eq 0
check "newer installed: says the installed one is newer" said "newer"
check "newer installed: no sudo / apt call" no_sudo
check "newer installed: temp dir removed" tmp_clean

# --- refusals: nothing reaches sudo -------------------------------------------
run_local badsig badsig
refused "SHA256SUMS changed after signing" "signature"
run_local otherkey otherkey
refused "signed by another key (also in ~/.gnupg/trustedkeys.gpg)" "signature"
run_local nosig nosig
refused "no SHA256SUMS.asc" "download"
run_local badsum badsum
refused "wrong sha256 for the .deb" "sha256"
run_local nodeb nodeb
refused ".deb missing from SHA256SUMS" "no vr-telex .deb"
run_local twodebs twodebs
refused "two .deb files in SHA256SUMS" "more than one"
run_local pathdeb pathdeb
refused ".deb name with a path in SHA256SUMS" "no vr-telex .deb"
run_local missingdeb missingdeb
refused ".deb download fails" "download"
run_local empty empty
refused "release without files (download fails)" "download"
run_local apt-fails good FAKE_SUDO_RC=100
check "apt fails: exits non-zero" failed
check "apt fails: vr-telex-setup not run" no_setup
check "apt fails: temp dir removed" tmp_clean
run_local setup-fails good FAKE_SETUP_RC=1
check "setup fails: exits non-zero" failed
check "setup fails: says the package is installed and to rerun vr-telex-setup" said "vr-telex-setup"

run_local arm64 good FAKE_ARCH=arm64
refused "non-amd64 system" "amd64"
check "non-amd64 system: nothing downloaded" fetched_nothing

run_local root good FAKE_UID=0
refused "run as root" "root"
check "run as root: nothing downloaded" fetched_nothing

# --- seams ------------------------------------------------------------------
# The test key is honoured only for a loopback base URL: with the official URL
# (the default) it is refused before any download, so it can never replace the
# pinned key on a real run. The wget/curl stubs fail if anything is fetched.
run_get key-seam-official "$NONET:$STUBS:$SYS_PATH" VR_TELEX_TEST_KEY="$TEST_KEY"
refused "test key with the official URL" "VR_TELEX_TEST_KEY"
no_download() { ! grep -qE '^(wget|curl) ' "$CALLS"; }
check "test key with the official URL: no download attempted" no_download
run_get key-seam-official-explicit "$NONET:$STUBS:$SYS_PATH" \
  VR_TELEX_RELEASE_URL="$OFFICIAL_URL" VR_TELEX_TEST_KEY="$TEST_KEY"
refused "test key with the official URL given explicitly" "VR_TELEX_TEST_KEY"
check "  ... no download attempted" no_download
run_get other-url "$NONET:$STUBS:$SYS_PATH" VR_TELEX_RELEASE_URL=https://example.invalid/x
refused "base URL that is neither official nor loopback" "VR_TELEX_RELEASE_URL"
check "  ... no download attempted" no_download
run_get other-url-key "$NONET:$STUBS:$SYS_PATH" \
  VR_TELEX_RELEASE_URL=http://127.0.0.1.example.invalid/x VR_TELEX_TEST_KEY="$TEST_KEY"
refused "look-alike loopback URL with a test key" "VR_TELEX_RELEASE_URL"
check "  ... no download attempted" no_download
# Without the test key, the pinned (real) key is used even for a loopback URL:
# a release signed by the throwaway key is refused.
run_get pinned-default "$STUBS:$SYS_PATH" VR_TELEX_RELEASE_URL="$URL/good"
refused "loopback release without the test key (pinned key used)" "signature"

stop_http

echo
if [ "$FAILS" -ne 0 ]; then
  echo "FAIL: $FAILS check(s) failed (rerun with VR_TELEX_GET_KEEP=1 to keep logs)"
  exit 1
fi
echo "PASS"
