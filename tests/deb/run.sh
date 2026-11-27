#!/usr/bin/env bash
# Contents and control-field test for the Debian package (AC-4).
#
# Usage: bash tests/deb/run.sh [path/to/vr-telex_<version>_amd64.deb]
#
# With no argument it builds the package with cargo-deb into a temp dir.
# Some asset sources are written by another task (A2: packaging/vr-telex-setup).
# While one is missing the package is built from a temp copy of the sources
# with a placeholder in its place, the run says so in a PLACEHOLDER banner,
# and the result line reads "PASS with placeholders" — such a package is not
# a release package. VR_TELEX_DEB_STRICT=1 (CI) turns that case into a failure.
# A .deb given as argument is always checked strictly against the repo.
#
#   VR_TELEX_DEB_KEEP=1   keep the temp dir (path printed at the end)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
STRICT=${VR_TELEX_DEB_STRICT:-0}

PKG=vr-telex
REVISION=1
MAINTAINER="vr-telex project <https://github.com/mvanvu/vr-telex>"
SHARE_FILES=(common.sh 90-vr-telex.conf xinputrc org.fcitx.Fcitx5.desktop org.fcitx.Fcitx5.service)
# Asset sources that task A2 writes; everything else must already exist.
A2_SOURCES=(packaging/vr-telex-setup)
SCRIPTS=(postinst prerm postrm)

FAILS=0
PLACEHOLDERS=()

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

for tool in dpkg-deb cmp gpg; do
  command -v "$tool" >/dev/null || die "$tool not found"
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/vr-telex-deb-test.XXXXXX")
cleanup() {
  if [ "${VR_TELEX_DEB_KEEP:-0}" = 1 ]; then
    echo "kept: $TMP"
  else
    rm -rf -- "$TMP"
  fi
}
trap cleanup EXIT

VERSION=$(sed -n '/^\[workspace.package\]/,/^\[/ s/^version = "\(.*\)"$/\1/p' "$REPO/Cargo.toml")
[ -n "$VERSION" ] || die "no [workspace.package] version in Cargo.toml"
DEB_VERSION=$VERSION-$REVISION

# ------------------------------------------------------------------ build --

build_deb() {
  local missing=() src
  for src in "${A2_SOURCES[@]}"; do
    [ -e "$REPO/$src" ] || missing+=("$src")
  done
  command -v cargo >/dev/null || die "cargo not found"
  cargo deb --version >/dev/null 2>&1 || die "cargo-deb not found (cargo deb --version)"
  mkdir -p "$TMP/out"

  if [ ${#missing[@]} -eq 0 ]; then
    echo "building: cargo deb -p $PKG (repo sources)"
    (cd "$REPO" && cargo deb -p "$PKG" --locked --output "$TMP/out") >"$TMP/build.log" 2>&1 ||
      { cat "$TMP/build.log" >&2; die "cargo deb failed"; }
  else
    PLACEHOLDERS=("${missing[@]}")
    echo "=================================================================="
    echo "PLACEHOLDER: missing A2 sources: ${missing[*]}"
    echo "PLACEHOLDER: building from a temp copy with placeholder files;"
    echo "PLACEHOLDER: this package is NOT a release package."
    echo "=================================================================="
    [ "$STRICT" = 1 ] && die "VR_TELEX_DEB_STRICT=1 and A2 sources are missing"
    # The binary comes from the repo's own target dir, so only sources are copied.
    (cd "$REPO" && cargo build --release --locked -p "$PKG") >"$TMP/build.log" 2>&1 ||
      { cat "$TMP/build.log" >&2; die "cargo build failed"; }
    mkdir -p "$TMP/src"
    (cd "$REPO" && cp -a Cargo.toml Cargo.lock rust-toolchain.toml LICENSE README.md \
      THIRD-PARTY-NOTICES.md crates packaging "$TMP/src/")
    for src in "${missing[@]}"; do
      printf '#!/bin/sh\necho "placeholder from tests/deb/run.sh" >&2\nexit 1\n' >"$TMP/src/$src"
    done
    (cd "$TMP/src" && CARGO_TARGET_DIR=$REPO/target CARGO_NET_OFFLINE=true \
      cargo deb --manifest-path crates/$PKG/Cargo.toml --no-build --output "$TMP/out") \
      >>"$TMP/build.log" 2>&1 || { cat "$TMP/build.log" >&2; die "cargo deb failed"; }
  fi
  local debs=("$TMP"/out/*.deb)
  if [ ${#debs[@]} -ne 1 ] || [ ! -f "${debs[0]}" ]; then die "expected one .deb in $TMP/out"; fi
  DEB=${debs[0]}
}

if [ $# -ge 1 ]; then
  DEB=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
  [ -f "$DEB" ] || die "no such file: $1"
  for src in "${A2_SOURCES[@]}"; do
    [ -e "$REPO/$src" ] || die "cannot compare $src: missing in the repo"
  done
else
  build_deb
  # cargo-deb only warns about a missing description or two assets with the
  # same target path (the first one silently wins), so warnings fail here.
  no_build_warnings() { ! grep -i '^warning' "$TMP/build.log"; }
  check "cargo deb printed no warnings" no_build_warnings
fi
echo "package: $DEB"

is_placeholder() { # is_placeholder <repo-relative source>
  local p
  for p in "${PLACEHOLDERS[@]}"; do [ "$p" = "$1" ] && return 0; done
  return 1
}

# ---------------------------------------------------------- control fields --

field() { dpkg-deb -f "$DEB" "$1"; }

check "file name is ${PKG}_${DEB_VERSION}_amd64.deb" \
  test "$(basename "$DEB")" = "${PKG}_${DEB_VERSION}_amd64.deb"
check "Package: $PKG" test "$(field Package)" = "$PKG"
check "Version: $DEB_VERSION (workspace version $VERSION)" test "$(field Version)" = "$DEB_VERSION"
check "Architecture: amd64" test "$(field Architecture)" = amd64
check "Maintainer is the project URL" test "$(field Maintainer)" = "$MAINTAINER"
# Output is captured before grep reads it: with pipefail, `cmd | grep -q` can
# fail (or, negated, pass) at random when grep exits before cmd has written
# everything (SIGPIPE).
no_at_maintainer() {
  local m
  m=$(field Maintainer) && [[ $m != *@* ]]
}
check "Maintainer has no e-mail address" no_at_maintainer
check "Section: utils" test "$(field Section)" = utils
check "Priority: optional" test "$(field Priority)" = optional

DEPENDS=$(field Depends)
echo "      Depends: $DEPENDS"
DEP_NAMES=$(printf "%s\n" "$DEPENDS" | tr "," "\n" | sed "s/^ *//; s/ .*//")
has_dep() { grep -qx "$1" <<<"$DEP_NAMES"; }
for dep in libc6 systemd dbus-user-session libglib2.0-bin; do
  check "Depends lists $dep" has_dep "$dep"
done

DESCRIPTION=$(field Description)
summary_ok() { [[ ${DESCRIPTION%%$'\n'*} == *Vietnamese* ]]; }
extended_ok() {
  [ "$(printf "%s\n" "$DESCRIPTION" | wc -l)" -gt 1 ] &&
    grep -q "vr-telex-setup --remove" <<<"$DESCRIPTION"
}
check "Description summary names the input method" summary_ok
check "Description has an extended part naming vr-telex-setup --remove" extended_ok

# ---------------------------------------------------------------- contents --

EXPECTED="$TMP/expected"
{
  echo "-rwxr-xr-x 0/0 ./usr/bin/vr-telex"
  echo "-rwxr-xr-x 0/0 ./usr/bin/vr-telex-setup"
  echo "-rwxr-xr-x 0/0 ./usr/bin/vr-telex-update"
  echo "-rw-r--r-- 0/0 ./usr/lib/systemd/user/vr-telex.service"
  echo "-rw-r--r-- 0/0 ./usr/share/vr-telex/vr-telex.sources"
  echo "-rw-r--r-- 0/0 ./usr/share/keyrings/vr-telex.gpg"
  for f in "${SHARE_FILES[@]}"; do echo "-rw-r--r-- 0/0 ./usr/share/vr-telex/$f"; done
  for f in README.md THIRD-PARTY-NOTICES.md copyright; do
    echo "-rw-r--r-- 0/0 ./usr/share/doc/vr-telex/$f"
  done
} | sort >"$EXPECTED"
dpkg-deb -c "$DEB" | awk '$1 !~ /^d/ { print $1, $2, $6 }' | sort >"$TMP/actual"
if diff -u "$EXPECTED" "$TMP/actual" >"$TMP/contents.diff"; then
  ok "dpkg-deb -c: exactly the expected files, modes and owners (0/0 = root)"
else
  bad "dpkg-deb -c differs from the expected file list:"
  sed 's/^/      /' "$TMP/contents.diff"
fi
CONTENTS=$(dpkg-deb -c "$DEB")
dirs_root_owned() { [ -z "$(awk '$1 ~ /^d/ && $2 != "0/0"' <<<"$CONTENTS")" ]; }
check "dpkg-deb -c: every directory is owned by 0/0 (root)" dirs_root_owned

X="$TMP/x"
dpkg-deb -x "$DEB" "$X"

same() { # same <packaged path> <repo-relative source>
  if is_placeholder "$2"; then
    printf 'skip  %s matches %s (PLACEHOLDER: A2 has not written it yet)\n' "$1" "$2"
    return 0
  fi
  check "$1 matches $2" cmp -s -- "$X/$1" "$REPO/$2"
}

is_x86_64_elf() {
  [ "$(od -An -tx1 -N5 "$1" | tr -d " ")" = 7f454c4602 ] &&
    [ "$(od -An -tx1 -j18 -N2 "$1" | tr -d " ")" = 3e00 ]
}
check "usr/bin/vr-telex is an x86-64 ELF executable" is_x86_64_elf "$X/usr/bin/vr-telex"
same usr/bin/vr-telex-setup packaging/vr-telex-setup
same usr/bin/vr-telex-update packaging/get/vr-telex-install.sh
for f in "${SHARE_FILES[@]}"; do same "usr/share/vr-telex/$f" "packaging/$f"; done
same usr/share/doc/vr-telex/README.md README.md
same usr/share/doc/vr-telex/THIRD-PARTY-NOTICES.md THIRD-PARTY-NOTICES.md
same usr/share/doc/vr-telex/copyright packaging/deb/copyright
same usr/lib/systemd/user/vr-telex.service packaging/deb/vr-telex.service
same usr/share/vr-telex/vr-telex.sources packaging/deb/vr-telex.sources
same usr/share/keyrings/vr-telex.gpg packaging/deb/vr-telex.gpg

# ------------------------------------------------- apt source and keyring --

RELEASE_FPR=2C30E91F97E5A566BEFF373736C30B9165329B85
KEYRING="$X/usr/share/keyrings/vr-telex.gpg"
mkdir -m 700 "$TMP/gnupg"
gpg_() { gpg --homedir "$TMP/gnupg" --batch "$@" 2>/dev/null; }
keyring_is_asc() { gpg_ --dearmor <"$REPO/packaging/apt/vr-telex.asc" | cmp -s - "$KEYRING"; }
check "keyring is packaging/apt/vr-telex.asc dearmored (to refresh it: gpg --dearmor <packaging/apt/vr-telex.asc >packaging/deb/vr-telex.gpg)" \
  keyring_is_asc
keyring_fprs() { gpg_ --show-keys --with-colons "$KEYRING" | awk -F: '/^pub/ { p = 1; next } p && /^fpr/ { print $10; p = 0 }'; }
check "keyring holds one key, the release key $RELEASE_FPR" test "$(keyring_fprs)" = "$RELEASE_FPR"
keyring_binary() {
  local packets
  packets=$(gpg_ --list-packets "$KEYRING") || return 1
  ! grep -q -- '-----BEGIN' "$KEYRING" && grep -q 'public key packet' <<<"$packets" &&
    ! grep -q 'secret key packet' <<<"$packets"
}
check "keyring is binary (not armored) and holds no secret key" keyring_binary
no_etc() { [ -z "$(awk '$6 ~ /^\.\/etc\// { print $6 }' <<<"$CONTENTS")" ]; }
check "package ships nothing under /etc (the apt source is written by postinst)" no_etc
no_conffiles() { [ ! -s "$CTL/conffiles" ]; }
SOURCES_FILE="$X/usr/share/vr-telex/vr-telex.sources"
sources_fields() { grep -v '^#' "$SOURCES_FILE"; }
EXPECTED_SOURCES='Types: deb
URIs: https://github.com/mvanvu/vr-telex/releases/latest/download/
Suites: ./
Architectures: amd64
Signed-By: /usr/share/keyrings/vr-telex.gpg'
check "apt source: deb822, flat repo at releases/latest/download, Signed-By the packaged keyring only" \
  test "$(sources_fields)" = "$EXPECTED_SOURCES"

UNIT="$X/usr/lib/systemd/user/vr-telex.service"
check "packaged unit runs ExecStart=/usr/bin/vr-telex" grep -qx 'ExecStart=/usr/bin/vr-telex' "$UNIT"
check "packaged unit has a single ExecStart" test "$(grep -c '^ExecStart=' "$UNIT")" = 1
# The packaged unit must not drift from the from-source one: same file except ExecStart.
unit_same_but_exec() { diff <(grep -v "^ExecStart=" "$REPO/packaging/vr-telex.service") <(grep -v "^ExecStart=" "$UNIT") >/dev/null; }
check "packaged unit equals packaging/vr-telex.service except ExecStart" unit_same_but_exec

COPYRIGHT="$X/usr/share/doc/vr-telex/copyright"
check "copyright states License: MIT" grep -qx 'License: MIT' "$COPYRIGHT"
has_mit_text() {
  local line
  while IFS= read -r line; do
    [ -z "$line" ] || grep -qxF " $line" "$COPYRIGHT" || return 1
  done < <(sed -n "/^Permission/,\$p" "$REPO/LICENSE")
}
check "copyright carries the full MIT text of LICENSE" has_mit_text
check "copyright points to THIRD-PARTY-NOTICES.md" grep -q 'THIRD-PARTY-NOTICES.md' "$COPYRIGHT"
no_at_copyright() { ! grep -q @ "$COPYRIGHT"; }
check "copyright has no e-mail address" no_at_copyright

# -------------------------------------------------------- maintainer scripts --

CTL="$TMP/control"
dpkg-deb -e "$DEB" "$CTL"
for s in "${SCRIPTS[@]}"; do
  check "control has executable $s" test -x "$CTL/$s"
  same_script() { cmp -s -- "$CTL/$s" "$REPO/packaging/deb/$s"; }
  check "$s matches packaging/deb/$s" same_script
  check "$s parses with sh -n" sh -n "$CTL/$s"
done
if command -v shellcheck >/dev/null; then
  check "shellcheck maintainer scripts" shellcheck "${SCRIPTS[@]/#/$CTL/}"
fi
check "control has no conffiles" no_conffiles

# Run every script with every dpkg action under env -i, an empty HOME and
# stubs that log any call to a tool that could reach a user session.
STUBS="$TMP/stubs"
CALLS="$TMP/calls.log"
mkdir -p "$STUBS" "$TMP/home"
: >"$CALLS"
for t in systemctl loginctl machinectl su runuser sudo gsettings gdbus dbus-send busctl \
  pkill killall fcitx5 fcitx5-remote ibus vr-telex vr-telex-setup; do
  printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 1\n' "$t" "$CALLS" >"$STUBS/$t"
  chmod 755 "$STUBS/$t"
done
# DPKG_ROOT is a copy of the unpacked package, so the scripts' system files
# land there and never in this machine's /etc.
ROOT="$TMP/root"
new_root() { rm -rf -- "$ROOT" && cp -a "$X" "$ROOT" && mkdir -p "$ROOT/etc/apt/sources.list.d"; }
new_root
run_script() { # run_script <script> <args...>; output in $TMP/script.out
  env -i HOME="$TMP/home" PATH="$STUBS:/usr/bin:/bin" DPKG_MAINTSCRIPT_PACKAGE=$PKG DPKG_ROOT="$ROOT" \
    sh "$CTL/$1" "${@:2}" >"$TMP/script.out" 2>&1
}
for action in "postinst configure" "postinst configure $DEB_VERSION" \
  "postinst abort-upgrade $DEB_VERSION" "prerm remove" "prerm upgrade $DEB_VERSION" \
  "prerm deconfigure" "postrm remove" "postrm purge" "postrm upgrade $DEB_VERSION" \
  "postrm abort-install"; do
  # shellcheck disable=SC2086 # the action string is split on purpose
  check "$action exits 0" run_script $action
  case $action in
  "prerm remove" | "postrm purge")
    check "$action tells users to run vr-telex-setup --remove" \
      grep -q "vr-telex-setup --remove" "$TMP/script.out"
    ;;
  "postinst configure")
    check "$action points users to vr-telex-setup" grep -q "vr-telex-setup" "$TMP/script.out"
    # Same wording as README and the setup: no logout needed to start typing.
    check "$action says it works at once" grep -q "works at once" "$TMP/script.out"
    check "$action says Qt/X11 apps follow after the next login" \
      grep -q "Qt and X11 apps pick it up after the next login" "$TMP/script.out"
    ;;
  esac
  case $action in
  "postrm purge")
    # What a user notices when the per-user setup was not undone first.
    # shellcheck disable=SC2088 # a literal ~ in the message, not a path
    for left in "input method settings still point at vr-telex" \
      "~/.local/share/dbus-1/services/org.fcitx.Fcitx5.service" "~/.xinputrc" \
      "~/.config/autostart/org.fcitx.Fcitx5.desktop" "enable link" "reinstall vr-telex"; do
      check "$action names: $left" grep -qF -- "$left" "$TMP/script.out"
    done
    ;;
  "prerm upgrade"* | "postrm upgrade"*)
    check "$action prints nothing" test ! -s "$TMP/script.out"
    ;;
  esac
done
check "maintainer scripts call no session tool (systemctl, gsettings, su, ...)" test ! -s "$CALLS"
[ -s "$CALLS" ] && sed 's/^/      /' "$CALLS"
check "maintainer scripts leave HOME untouched" test -z "$(ls -A "$TMP/home")"

# The apt source over the package's life (postinst writes, postrm removes).
APT_SOURCE="$ROOT/etc/apt/sources.list.d/vr-telex.sources"
source_is_packaged() {
  cmp -s "$APT_SOURCE" "$SOURCES_FILE" && [ "$(stat -c '%a %u' "$APT_SOURCE")" = "644 $(id -u)" ] &&
    [ ! -e "$APT_SOURCE.dpkg-new" ]
}
new_root
check "install: postinst configure exits 0" run_script postinst configure
check "install: postinst writes /etc/apt/sources.list.d/vr-telex.sources (packaged copy, 0644)" source_is_packaged
check "install: postinst says apt upgrade installs new releases" \
  grep -qF "'sudo apt update && sudo apt upgrade' installs new releases" "$TMP/script.out"
nothing_else_in_etc() { [ "$(find "$ROOT/etc" -type f | wc -l)" = 1 ]; }
check "install: postinst writes nothing else under /etc" nothing_else_in_etc
upgrade_runs() {
  run_script prerm upgrade "$DEB_VERSION" && run_script postrm upgrade "$DEB_VERSION" &&
    run_script postinst configure "$DEB_VERSION"
}
check "upgrade: prerm upgrade, postrm upgrade, postinst configure exit 0" upgrade_runs
check "upgrade: the source is still the packaged one" source_is_packaged
printf 'Enabled: no\n' >>"$APT_SOURCE"
cp "$APT_SOURCE" "$TMP/edited.sources"
check "upgrade over an edited source: postinst configure exits 0" run_script postinst configure "$DEB_VERSION"
check "upgrade over an edited source: the edit is kept" cmp -s "$APT_SOURCE" "$TMP/edited.sources"
check "upgrade over an edited source: postinst says so" grep -q "kept your /etc/apt/sources.list.d/vr-telex.sources" "$TMP/script.out"
runs_then() { # runs_then <test expression...> -- <script> <args...>: script exits 0, then test holds
  local t=()
  while [ "$1" != -- ]; do
    t+=("$1")
    shift
  done
  shift
  run_script "$@" && test "${t[@]}"
}
check "remove: prerm remove leaves the source (postrm removes it)" runs_then -f "$APT_SOURCE" -- prerm remove
check "remove: postrm remove deletes the source, even an edited one" runs_then ! -e "$APT_SOURCE" -- postrm remove
check "purge after remove: postrm purge exits 0" run_script postrm purge
new_root
run_script postinst configure
check "purge: postrm purge deletes the source" runs_then ! -e "$APT_SOURCE" -- postrm purge
new_root
ln -s /nonexistent "$APT_SOURCE"
symlink_kept() { run_script postinst configure && [ "$(readlink "$APT_SOURCE")" = /nonexistent ]; }
check "postinst leaves an existing symlink in place" symlink_kept
# A planted vr-telex.sources.dpkg-new symlink must not make postinst write
# through it (CWE-59).
new_root
printf 'victim\n' >"$TMP/victim"
ln -s "$TMP/victim" "$APT_SOURCE.dpkg-new"
check "postinst over a planted .dpkg-new symlink exits 0" run_script postinst configure
check "  ... writes nothing through the symlink" test "$(cat "$TMP/victim")" = victim
check "  ... and still writes the packaged source" source_is_packaged

# ------------------------------------------------------------------ result --

echo
if [ "$FAILS" -ne 0 ]; then
  echo "FAIL: $FAILS check(s) failed"
  exit 1
fi
if [ ${#PLACEHOLDERS[@]} -ne 0 ]; then
  echo "PASS with placeholders (missing A2 sources: ${PLACEHOLDERS[*]})"
else
  echo "PASS"
fi
