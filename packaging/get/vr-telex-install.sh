#!/bin/sh
# Install or update vr-telex from the latest GitHub release (amd64).
#
#   Install: wget -qO- \
#              https://github.com/mvanvu/vr-telex/releases/latest/download/vr-telex-install.sh | sh
#   Update:  vr-telex-update   (this same script, installed by the package)
#
# Run it as your own user; it uses sudo only for `apt install`. It downloads
# SHA256SUMS, SHA256SUMS.asc and the .deb named in SHA256SUMS into a private
# temp dir (removed on every exit), checks the signature with gpgv against the
# release key embedded below (no key from your own GnuPG setup counts), checks
# the .deb's SHA-256, then runs `sudo apt install -y <deb>` and
# `vr-telex-setup`. Every check runs before sudo; a failed one stops the run.
# When the installed version already is the latest, it changes nothing.
#
# Test-only environment (tests/get/run.sh); a normal run sets neither:
#   VR_TELEX_RELEASE_URL  base URL of the release files; only the official URL
#                         below or http://127.0.0.1:<port>/... is accepted.
#   VR_TELEX_TEST_KEY     armored public key file used instead of the embedded
#                         key; refused unless VR_TELEX_RELEASE_URL is loopback,
#                         so it can never replace the key for a real download.
set -eu
umask 077

OFFICIAL_URL=https://github.com/mvanvu/vr-telex/releases/latest/download
PKG=vr-telex

say() { printf 'vr-telex: %s\n' "$*"; }
die() {
  printf 'vr-telex: error: %s\n' "$*" >&2
  exit 1
}

# The release signing key, fingerprint 2C30E91F97E5A566BEFF373736C30B9165329B85.
# A copy of packaging/apt/vr-telex.asc written by packaging/get/embed-key.sh;
# tests/get/run.sh fails when the two differ.
pinned_key() {
  cat <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBGsJX+kBEADQCOXCJjDX7EkHsstxSstx5ouBU85JeM69M069aDaUQlnRkiNi
FikIndSzXbcFmEwkgOGonoEzoYLDGKcjVuf8O9419JchID8fBiIxa2gElRnjkSmR
PZ6reZcDm1p/aZ3/irZZesO1dIWBRGzONg5e3Viq7rtigHMLS1SfPVUBq6PfKDW0
zZxeHThkDtGWYTLTbYMyuSdV1O/KByxQhJF+OCIlL57Hr0OJcMH2dSrzOdCYvQvQ
l4Bj1vmx+eJ4UARpXQXlFJQa9ZJbUkbjHAqAd+HJEnNxmlKgtu/gW+TjgBSzGAmS
PDpXNxZXVQLBTOcWVHJ4SjNxMFBBVZri2myTfTkJAPcqPuj0kiTcL1V3eFmfcC4G
bLGMc3ezwCHprrmcBuNIjw0yJI6nfHFcMSHU4kN0kwJ99Vdxw+ThBG7EpsY1rNv1
sSAbH5aPTBdOVC+e7pK8D0KzL2rJW06M1Xf2RJo+xPGBdNyGNir5vGVDvXAl34ZZ
N/AzPAU/DQrT2+F4+4+H4pcht5yTIFIMEF4YV8uHS30s1L2HIsbc2eTeKNArWDDS
pfBG8AKUWo8RJJSBKUIob8AT5Hpb2YJpdHirbYhYnx8Kb3Lx4hLQG3Y2zMbpPQDq
c3RvAC2SOWmWaU1Ro7zW0Xs0d5FXfd+/gkfxIbjDCFg9/uW20ThMh7FKiwARAQAB
tDx2ci10ZWxleCBhcHQgcmVwb3NpdG9yeSAoaHR0cHM6Ly9naXRodWIuY29tL212
YW52dS92ci10ZWxleCmJAlcEEwEKAEEWIQQsMOkfl+WlZr7/Nzc2wwuRZTKbhQUC
awlf6QIbAwUJBaOagAULCQgHAgIiAgYVCgkICwIEFgIDAQIeBwIXgAAKCRA2wwuR
ZTKbheecEADD2rzMCCP0/kqVQu7OzHCRNNK0DNybbJ5nPT6ikrOCOBsZmSEdTXKE
q0maN1asoWUzzSuCiPPLOVGdebqaTLlbz7uQQcDsmjmMMjy5OdmHxMaMMq0cv8Cs
HgkCJ7PnkocOl3ngPtwYnyXBk8KyYmtP4CppJ19OSKOGfRdPD71wvE94Ev2Dh1rV
dlUdVrTbyUJ/ixhqe7lCM9UyiavM/KmOt5VKG2wYJG1CsPc3AYI1nJ6/SMXDM+xb
fJQlIRB+QyaAQG8bjKWeDhhHzW8LUNNqPAlyatI9yzeMmM2dbkQquAo147hsc4jC
P03sx+8EW73V5pelY3hZP85+UfTIq/icLpiVYC82R94EjQrgq9McZdOKRCYebT6C
KfIPMn1QDKOD1rWSkn0HUm36Y3Gua5Nuyn+/j637m8q3lb4WqFqf4zHb3XGdVQSJ
2YZ6Zc4eFS+rzT+McXb0v7JN1aqmDrhLn5uvAAWHm0rFK1IsYSDCly21VrukF2ui
7UXbC4hqeaxzMC2MzPYMlN+mtgXhK+5gZO+dureFdCa8nU1Rm4qqn3ztEwvsq+1e
cGL8eKdqi+z/r2rQijtv1fWGLMfUCUqeSGr6EG6HDZFT6jQeIwu2Gt41ZAzTGC+i
QyL/iH+ga03tYJUH3HNM4Qq79G4tvMS/IOLS7b/6OJigty1FynTDbg==
=eT/k
-----END PGP PUBLIC KEY BLOCK-----
EOF
}

# Root is refused, as in vr-telex-setup: the per-user setup must run as the
# desktop user, and under `sudo sh` it would set up root instead while the
# package went in system-wide. sudo is asked for only for apt.
uid=$(id -u) || die "cannot tell the user id"
[ "$uid" != 0 ] ||
  die "do not run as root or with sudo; run it as your own user (it asks for sudo only to install the package)"

arch=$(dpkg --print-architecture 2>/dev/null) || die "dpkg not found; vr-telex needs Ubuntu 24.04 or newer on amd64"
[ "$arch" = amd64 ] || die "vr-telex is built for amd64 only; this system is $arch"

base=${VR_TELEX_RELEASE_URL:-$OFFICIAL_URL}
base=${base%/}
loopback=0
case $base in
"$OFFICIAL_URL") ;;
http://127.0.0.1:*)
  port=${base#http://127.0.0.1:}
  port=${port%%/*}
  case $port in
  '' | *[!0-9]*) die "VR_TELEX_RELEASE_URL ($base) is for tests only and is not a loopback URL; unset it" ;;
  esac
  loopback=1
  ;;
*) die "VR_TELEX_RELEASE_URL ($base) is for tests only; unset it to use $OFFICIAL_URL" ;;
esac

if [ -n "${VR_TELEX_TEST_KEY:-}" ]; then
  [ "$loopback" = 1 ] ||
    die "VR_TELEX_TEST_KEY is for tests only and works only with a loopback VR_TELEX_RELEASE_URL; unset it"
  key_text=$(cat -- "$VR_TELEX_TEST_KEY") || die "cannot read VR_TELEX_TEST_KEY"
else
  key_text=$(pinned_key)
fi

for tool in gpgv sha256sum base64 dpkg-deb dpkg-query sudo apt; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found; vr-telex needs Ubuntu 24.04 or newer"
done
# wget first: Ubuntu desktop installs it by default, curl not always.
if command -v wget >/dev/null 2>&1; then
  fetch() { wget -q --tries=2 --timeout=30 -O "$2" -- "$1"; }
elif command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL --retry 1 --connect-timeout 30 -o "$2" -- "$1"; }
else
  die "needs wget or curl to download the release"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/vr-telex-install.XXXXXX") || die "cannot create a temp dir"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

get() { # get <file>: download a release file into the temp dir
  fetch "$base/$1" "$TMP/$1" || die "download of $base/$1 failed (network down, or no release yet?)"
}

# --- the signed list of release files ------------------------------------
get SHA256SUMS
get SHA256SUMS.asc
# Dearmor without gpg: drop the armor header lines up to the blank line, the
# CRC line and the footer, then decode the base64 body.
printf '%s\n' "$key_text" | sed -e '1,/^$/d' -e '/^=/d' -e '/^-----END /d' |
  base64 -d >"$TMP/release-key.gpg" 2>/dev/null || die "the release key does not decode"
# With --keyring, gpgv uses only that key, not ~/.gnupg/trustedkeys.*; the
# empty home of its own also keeps it from reading or creating ~/.gnupg.
mkdir "$TMP/gnupg"
if ! GNUPGHOME=$TMP/gnupg gpgv --keyring "$TMP/release-key.gpg" \
  "$TMP/SHA256SUMS.asc" "$TMP/SHA256SUMS" >"$TMP/gpgv.log" 2>&1; then
  sed 's/^/  /' "$TMP/gpgv.log" >&2
  die "the signature of SHA256SUMS does not verify with the vr-telex release key; not installing"
fi

# The one amd64 .deb it lists; a plain file name, no path.
debs=$(sed -n "s/^[0-9a-f]\{64\}  \(${PKG}_[0-9][A-Za-z0-9.+~-]*_amd64\.deb\)\$/\1/p" "$TMP/SHA256SUMS")
case $debs in
'') die "SHA256SUMS lists no vr-telex .deb for amd64; not installing" ;;
*'
'*) die "SHA256SUMS lists more than one vr-telex .deb; not installing" ;;
esac
deb=$debs
want=$(awk -v n="$deb" 'NF == 2 && $2 == n { print $1 }' "$TMP/SHA256SUMS")
ver=${deb#"${PKG}_"}
ver=${ver%_amd64.deb}

# --- nothing to do when the installed version is the latest -----------------
installed=
# shellcheck disable=SC2016 # dpkg-query fields, not shell variables
if q=$(dpkg-query -W -f='${Status} ${Version}' "$PKG" 2>/dev/null); then
  case $q in
  "install ok installed "*) installed=${q#install ok installed } ;;
  esac
fi
if [ "$installed" = "$ver" ]; then
  say "vr-telex $ver is already up to date"
  say "to set it up (again) for your user, run: vr-telex-setup"
  exit 0
fi
if [ -n "$installed" ] && dpkg --compare-versions "$installed" gt "$ver"; then
  say "the installed vr-telex $installed is newer than the latest release $ver; nothing to do"
  exit 0
fi

# --- the package -------------------------------------------------------------
get "$deb"
got=$(sha256sum "$TMP/$deb" | cut -d' ' -f1)
if [ -z "$want" ] || [ "$got" != "$want" ]; then
  die "the sha256 of $deb does not match SHA256SUMS; not installing"
fi
if [ "$(dpkg-deb -f "$TMP/$deb" Package)" != "$PKG" ] ||
  [ "$(dpkg-deb -f "$TMP/$deb" Version)" != "$ver" ] ||
  [ "$(dpkg-deb -f "$TMP/$deb" Architecture)" != amd64 ]; then
  die "$deb is not vr-telex $ver for amd64; not installing"
fi

# apt fetches local files as the unprivileged _apt user; without read access
# it falls back to root and prints a "Download is performed unsandboxed"
# notice. Only the owner can write here, so the checked file stays as checked.
chmod 0755 "$TMP"
chmod 0644 "$TMP/$deb"
if [ -n "$installed" ]; then
  say "updating vr-telex $installed to $ver (sudo apt install; sudo may ask for your password)"
else
  say "installing vr-telex $ver (sudo apt install; sudo may ask for your password)"
fi
sudo apt install -y "$TMP/$deb" || die "apt could not install $deb; vr-telex-setup was not run"

vr-telex-setup ||
  die "vr-telex $ver is installed, but vr-telex-setup failed; run vr-telex-setup again (README: Troubleshooting)"

say "installed vr-telex $ver (release signature and sha256 checked) and set it up for your user"
say "update later with: vr-telex-update"
say "remove with: vr-telex-setup --remove, then sudo apt remove vr-telex"
