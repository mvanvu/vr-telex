#!/usr/bin/env bash
# Sandbox tests for install.sh / uninstall.sh (AC-5, AC-6, SEC-19..24).
#
# Every scenario runs under `env -i` with a throwaway HOME, XDG dirs and
# XDG_RUNTIME_DIR, on a private bus from `dbus-run-session` whose config
# lists only the sandbox's own D-Bus service dir (the system fcitx5 service
# file can never be activated), with GSETTINGS_BACKEND=keyfile and stubs for
# systemctl, fcitx5 and fcitx5-remote first on PATH. The real HOME, the real
# session bus and the running fcitx5 are never touched (D2, SEC-29).
#
# Usage: bash tests/install/run.sh [scenario...]
#   VR_TALEX_TEST_DIR  where sandboxes and logs go (default: a new temp dir,
#                      removed when every scenario passes)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
STUBS=$HERE/stubs
SCENARIOS=(fresh_fcitx5 fresh_no_fcitx5 empty_sources broken_daemon root_refused
  no_cargo ibus_refused activation_shadow uninstall_without_backup uninstall_not_installed
  edited_after_install failed_restore symlinked_config fcitx5_unit fcitx5_stuck
  reinstall_backup_deleted special_home rerun_failure bad_xdg edited_then_reinstall
  record_write_fails)
# A HOME with a space, an ampersand and a quote (special_home scenario).
SPECIAL_HOME_NAME="h o&m'e"

# ---------------------------------------------------------------- outside --

run_all() {
  local root keep=1 failed=0 name sb log rc
  if [ -n "${VR_TALEX_TEST_DIR:-}" ]; then
    root=$VR_TALEX_TEST_DIR
    mkdir -p "$root"
  else
    root=$(mktemp -d "${TMPDIR:-/tmp}/vr-talex-install-test.XXXXXX")
    keep=0
  fi
  root=$(cd "$root" && pwd -P)
  local list=("$@")
  [ ${#list[@]} -gt 0 ] || list=("${SCENARIOS[@]}")
  local i=0
  for name in "${list[@]}"; do
    i=$((i + 1))
    # Short directory names keep the bus socket path under the 108-byte limit.
    sb=$root/s$i
    log=$root/$name.log
    if [ -e "$sb" ]; then rm -rf -- "${sb:?}"; fi
    mkdir -p "$sb/home" "$sb/r" "$sb/run"
    chmod 0700 "$sb/run"
    write_bus_conf "$sb"
    rc=0
    env -i \
      HOME="$sb/home" \
      USER="${USER:-tester}" LOGNAME="${LOGNAME:-tester}" \
      PATH="$STUBS:/usr/bin:/bin" \
      LANG=C.UTF-8 \
      XDG_CONFIG_HOME="$sb/home/.config" \
      XDG_DATA_HOME="$sb/home/.local/share" \
      XDG_STATE_HOME="$sb/home/.local/state" \
      XDG_RUNTIME_DIR="$sb/run" \
      XDG_CURRENT_DESKTOP=ubuntu:GNOME \
      GSETTINGS_BACKEND=keyfile \
      VR_TALEX_BIN="$STUBS/fake-ime" \
      VR_TALEX_TIMEOUT=5 \
      T8_SANDBOX="$sb" T8_REPO="$REPO" T8_STUBS="$STUBS" \
      dbus-run-session --config-file="$sb/bus.conf" -- \
      bash "$HERE/run.sh" --in-sandbox "$name" >"$log" 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then
      echo "PASS $name"
    else
      echo "FAIL $name (exit $rc) — log: $log"
      tail -n 15 "$log" | sed 's/^/    /'
      failed=$((failed + 1))
    fi
  done
  echo "--- ${#list[@]} scenarios, $failed failed"
  if [ "$failed" = 0 ] && [ "$keep" = 0 ]; then rm -rf -- "${root:?}"; fi
  [ "$failed" = 0 ]
}

write_bus_conf() {
  local sb=$1
  cat >"$sb/bus.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <keep_umask/>
  <listen>unix:tmpdir=$sb/r</listen>
  <auth>EXTERNAL</auth>
  <servicedir>$sb/home/.local/share/dbus-1/services</servicedir>
  <servicedir>$sb/h o&amp;m&apos;e/.local/share/dbus-1/services</servicedir>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF
}

# ----------------------------------------------------------------- inside --

guard_sandbox() {
  : "${T8_SANDBOX:?not in a sandbox}"
  case "$HOME" in "$T8_SANDBOX"/*) ;; *) echo "HOME outside the sandbox" >&2; exit 99 ;; esac
  case "${DBUS_SESSION_BUS_ADDRESS:-}" in *"$T8_SANDBOX"/*) ;; *) echo "bus outside the sandbox" >&2; exit 99 ;; esac
  [ "$(command -v systemctl)" = "$T8_STUBS/systemctl" ] || { echo "systemctl is not the stub" >&2; exit 99; }
  [ "$(command -v fcitx5-remote)" = "$T8_STUBS/fcitx5-remote" ] || { echo "fcitx5-remote is not the stub" >&2; exit 99; }
  [ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] || { echo "display leaked into the sandbox" >&2; exit 99; }
}

cleanup_stubs() {
  local f pid
  for f in "$XDG_RUNTIME_DIR"/stub-pids/*; do
    [ -f "$f" ] || continue
    pid=$(cat "$f")
    if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; fi
  done
}

FAILS=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

owner_pid() {
  local out
  out=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.GetConnectionUnixProcessID "$1" 2>/dev/null) || return 1
  out=${out#*uint32 }
  printf '%s\n' "${out%%,*}"
}
has_owner() { owner_pid "$1" >/dev/null; }
no_owner() { ! has_owner "$1"; }

# Snapshot of the sandbox HOME: type, mode, path, link target, content hash.
# With "noibus" the IBus address files' content is left out (a restarted
# fcitx5 rewrites them with its new pid).
snap() {
  local out=$1 mode=${2:-}
  (
    cd "$HOME"
    find . -mindepth 1 -printf '%y %m %p -> %l\n' | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) | if [ "$mode" = noibus ]; then grep -v 'ibus/bus/.*-unix-' ; else cat; fi >"$out"
}
same_snap() {
  if diff -u "$1" "$2"; then return 0; fi
  return 1
}

keyfile() { printf '%s\n' "$XDG_CONFIG_HOME/glib-2.0/settings/keyfile"; }
gs() { gsettings get org.gnome.desktop.input-sources "$1"; }

addr_file_pid_is() {
  local pid=$1 f
  for f in "$XDG_CONFIG_HOME"/ibus/bus/*-unix-*; do
    [ -f "$f" ] && grep -qx "IBUS_DAEMON_PID=$pid" "$f" && return 0
  done
  return 1
}

run_install() { bash "$T8_REPO/install.sh" "$@"; }
run_uninstall() { bash "$T8_REPO/uninstall.sh" "$@"; }

pre_state_fcitx5() {
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
  printf '# im-config(8) generated on Thu, 12 Nov 2026 19:56:21 +0700\nrun_im fcitx5\n# im-config signature: efffcf4aa45dc22a042431202d07e026  -\n' >"$HOME/.xinputrc"
  mkdir -p "$XDG_CONFIG_HOME/environment.d"
  printf 'FOO=bar\n' >"$XDG_CONFIG_HOME/environment.d/90-other.conf"
  fcitx5 -d
}

expect_installed() {
  local main
  main=$(systemctl --user show -p MainPID --value vr-talex.service)
  check "vr-talex unit active" systemctl --user is-active --quiet vr-talex.service
  check "vr-talex unit enabled" systemctl --user is-enabled --quiet vr-talex.service
  check "org.fcitx.Fcitx5 owned by the unit's MainPID ($main)" [ "$(owner_pid org.fcitx.Fcitx5)" = "$main" ]
  check "IBus address file holds the daemon pid" addr_file_pid_is "$main"
  check "binary installed 0755" [ "$(stat -c %a "$HOME/.local/bin/vr-talex")" = 755 ]
  check "binary is VR_TALEX_BIN" cmp -s "$VR_TALEX_BIN" "$HOME/.local/bin/vr-talex"
  check "unit = packaging template" cmp -s "$T8_REPO/packaging/vr-talex.service" "$XDG_CONFIG_HOME/systemd/user/vr-talex.service"
  check "environment.d = packaging template" cmp -s "$T8_REPO/packaging/90-vr-talex.conf" "$XDG_CONFIG_HOME/environment.d/90-vr-talex.conf"
  check "environment.d sets QT_IM_MODULE=fcitx (D27)" grep -qx 'QT_IM_MODULE=fcitx' "$XDG_CONFIG_HOME/environment.d/90-vr-talex.conf"
  check "xinputrc = packaging template" cmp -s "$T8_REPO/packaging/xinputrc" "$HOME/.xinputrc"
  check "autostart override = packaging template" cmp -s "$T8_REPO/packaging/org.fcitx.Fcitx5.desktop" "$XDG_CONFIG_HOME/autostart/org.fcitx.Fcitx5.desktop"
  check "autostart override hides fcitx5" grep -qx 'Hidden=true' "$XDG_CONFIG_HOME/autostart/org.fcitx.Fcitx5.desktop"
  check "D-Bus activation shadow execs vr-talex (quoted)" grep -qxF "Exec=\"$HOME/.local/bin/vr-talex\"" "$XDG_DATA_HOME/dbus-1/services/org.fcitx.Fcitx5.service"
  check "backup manifest exists" [ -f "$XDG_DATA_HOME/vr-talex/backup/manifest" ]
  check "backup dir is 0700" [ "$(stat -c %a "$XDG_DATA_HOME/vr-talex/backup")" = 700 ]
  check "vr-talex source present exactly once" [ "$(gs sources | grep -o "('ibus', 'vr-talex')" | wc -l)" = 1 ]
  check "vr-talex source selected (first in mru-sources)" [ "$(gs mru-sources | cut -c1-21)" = "[('ibus', 'vr-talex')" ]
}

expect_no_vr_talex_left() {
  local hits='' f
  # The sandbox path itself contains "vr-talex" (the checkout's name), so it
  # is cut out of each file before looking for the string.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if sed "s|$T8_SANDBOX||g" "$f" | grep -q vr-talex; then hits="$hits $f"; fi
    case "${f#"$HOME"}" in *vr-talex*) hits="$hits $f" ;; esac
  done < <(grep -rl vr-talex "$XDG_CONFIG_HOME" "$HOME/.local" "$HOME/.xinputrc" 2>/dev/null || true; \
    find "$XDG_CONFIG_HOME" "$HOME/.local" -name '*vr-talex*' 2>/dev/null || true)
  check "no vr-talex string left in ~/.config, ~/.local, ~/.xinputrc" [ -z "$hits" ]
  [ -z "$hits" ] || printf '  left: %s\n' "$hits"
  check "vr-talex unit inactive" sh -c '! systemctl --user is-active --quiet vr-talex.service'
}

# --- scenarios -------------------------------------------------------------

t_fresh_fcitx5() {
  pre_state_fcitx5
  local fpid
  fpid=$(owner_pid org.fcitx.Fcitx5)
  snap "$T8_SANDBOX/pre.snap" noibus
  cp "$HOME/.xinputrc" "$T8_SANDBOX/pre.xinputrc"
  cp "$(keyfile)" "$T8_SANDBOX/pre.keyfile"

  check "first install exits 0" run_install
  check "fcitx5 asked to quit, not killed" grep -qx 'fcitx5-remote -e' "$XDG_RUNTIME_DIR/stub-calls.log"
  check "old fcitx5 ($fpid) has exited" sh -c "! kill -0 $fpid 2>/dev/null"
  expect_installed
  check "keyfile after install" diff -u - "$(keyfile)" <<'EOF'
[org/gnome/desktop/input-sources]
sources=[('xkb', 'us'), ('ibus', 'vr-talex')]
mru-sources=[('ibus', 'vr-talex'), ('xkb', 'us')]
EOF
  check "pre-existing xinputrc backed up byte for byte" cmp -s "$T8_SANDBOX/pre.xinputrc" "$XDG_DATA_HOME/vr-talex/backup/files/.xinputrc"
  local main1 calls1
  main1=$(systemctl --user show -p MainPID --value vr-talex.service)
  snap "$T8_SANDBOX/inst1.snap"
  cp "$(keyfile)" "$T8_SANDBOX/inst1.keyfile"
  calls1=$(wc -l <"$XDG_RUNTIME_DIR/stub-calls.log")

  check "second install exits 0" run_install
  snap "$T8_SANDBOX/inst2.snap"
  check "second install changes no file (snapshot identical)" same_snap "$T8_SANDBOX/inst1.snap" "$T8_SANDBOX/inst2.snap"
  check "second install leaves the keyfile byte-identical" cmp "$T8_SANDBOX/inst1.keyfile" "$(keyfile)"
  check "second install did not restart the daemon" [ "$(systemctl --user show -p MainPID --value vr-talex.service)" = "$main1" ]
  check "second install did not reload or restart units" sh -c "tail -n +$((calls1 + 1)) '$XDG_RUNTIME_DIR/stub-calls.log' | grep -Eq 'daemon-reload|restart|fcitx5-remote' && exit 1 || exit 0"

  check "uninstall exits 0" run_uninstall
  snap "$T8_SANDBOX/post.snap" noibus
  check "files restored exactly (snapshot = pre-install)" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "keyfile restored byte for byte" cmp "$T8_SANDBOX/pre.keyfile" "$(keyfile)"
  check "sources back to [('xkb', 'us')]" [ "$(gs sources)" = "[('xkb', 'us')]" ]
  check "fcitx5 started again and owns org.fcitx.Fcitx5" has_owner org.fcitx.Fcitx5
  local npid
  npid=$(owner_pid org.fcitx.Fcitx5 || echo none)
  check "new owner is the restarted fcitx5" grep -q "^fcitx5 -d" "$XDG_RUNTIME_DIR/stub-calls.log"
  check "IBus address file is fcitx5's again" addr_file_pid_is "$npid"
  expect_no_vr_talex_left
}

t_fresh_no_fcitx5() {
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('xkb', 'de')]"
  snap "$T8_SANDBOX/pre.snap"
  check "install exits 0" run_install
  check "no fcitx5-remote call when fcitx5 is not running" sh -c "! grep -q fcitx5-remote '$XDG_RUNTIME_DIR/stub-calls.log'"
  expect_installed
  check "keyfile after install" diff -u - "$(keyfile)" <<'EOF'
[org/gnome/desktop/input-sources]
sources=[('xkb', 'us'), ('xkb', 'de'), ('ibus', 'vr-talex')]
mru-sources=[('ibus', 'vr-talex'), ('xkb', 'us'), ('xkb', 'de')]
EOF
  check "uninstall exits 0" run_uninstall
  snap "$T8_SANDBOX/post.snap"
  check "everything restored exactly, keyfile and IBus dir included" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "fcitx5 not started by uninstall (it did not run before)" no_owner org.fcitx.Fcitx5
  expect_no_vr_talex_left
}

t_empty_sources() {
  # Keys never set: uninstall must reset them, not write explicit defaults.
  mkdir -p "$HOME/.local/bin"
  printf 'keep me\n' >"$HOME/.local/bin/other-tool"
  local before_rec
  before_rec=$(gsettings list-recursively org.gnome.desktop.input-sources)
  snap "$T8_SANDBOX/pre.snap"
  check "install exits 0" run_install
  check "vr-talex is the only source" [ "$(gs sources)" = "[('ibus', 'vr-talex')]" ]
  check "uninstall exits 0" run_uninstall
  check "gsettings values back to defaults" [ "$(gsettings list-recursively org.gnome.desktop.input-sources)" = "$before_rec" ]
  check "sources key no longer set in the keyfile" sh -c "! grep -q '^sources=' '$(keyfile)' 2>/dev/null"
  # The keyfile backend keeps an empty file once it has written; drop it from
  # the comparison, the values are checked above.
  snap "$T8_SANDBOX/post.snap"
  grep -v 'glib-2.0' "$T8_SANDBOX/pre.snap" >"$T8_SANDBOX/pre.cmp"
  grep -v 'glib-2.0' "$T8_SANDBOX/post.snap" >"$T8_SANDBOX/post.cmp"
  check "files restored exactly, created dirs removed, ~/.local/bin kept" same_snap "$T8_SANDBOX/pre.cmp" "$T8_SANDBOX/post.cmp"
}

t_broken_daemon() {
  pre_state_fcitx5
  snap "$T8_SANDBOX/pre.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/pre.keyfile"
  local out rc=0
  out=$(VR_TALEX_BIN="$T8_STUBS/broken-vr-talex" run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install with a dying daemon exits non-zero" [ "$rc" -ne 0 ]
  check "install prints the recovery path" grep -q 'systemctl --user disable --now vr-talex.service' <<<"$out"
  check "install says it rolled back" grep -qi 'rolled back' <<<"$out"
  snap "$T8_SANDBOX/post.snap" noibus
  check "rollback restored every file" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "sources unchanged (keyfile byte-identical)" cmp "$T8_SANDBOX/pre.keyfile" "$(keyfile)"
  check "fcitx5 runs again after rollback" has_owner org.fcitx.Fcitx5
  expect_no_vr_talex_left
}

t_root_refused() {
  mkdir -p "$T8_SANDBOX/rootstub"
  printf '#!/bin/sh\n[ "$1" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' >"$T8_SANDBOX/rootstub/id"
  chmod +x "$T8_SANDBOX/rootstub/id"
  snap "$T8_SANDBOX/pre.snap"
  local out rc=0
  out=$(PATH="$T8_SANDBOX/rootstub:$PATH" run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install as root exits 1" [ "$rc" = 1 ]
  check "install as root explains" grep -q 'do not run as root' <<<"$out"
  rc=0
  out=$(PATH="$T8_SANDBOX/rootstub:$PATH" run_uninstall 2>&1) || rc=$?
  check "uninstall as root exits 1" [ "$rc" = 1 ]
  snap "$T8_SANDBOX/post.snap"
  check "nothing changed" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "no systemctl call" [ ! -s "$XDG_RUNTIME_DIR/stub-calls.log" ]
}

t_no_cargo() {
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
  snap "$T8_SANDBOX/pre.snap"
  local out rc=0
  out=$(env -u VR_TALEX_BIN bash "$T8_REPO/install.sh" 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install without cargo exits non-zero" [ "$rc" -ne 0 ]
  check "install without cargo explains" grep -q 'cargo not found' <<<"$out"
  snap "$T8_SANDBOX/post.snap"
  check "nothing changed" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
}

t_ibus_refused() {
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('ibus', 'm17n:vi:telex')]"
  setsid python3 "$T8_STUBS/fake-ime" ibus </dev/null >>"$XDG_RUNTIME_DIR/fake-ibus.log" 2>&1 &
  gdbus wait --session --timeout 5 org.freedesktop.portal.IBus
  snap "$T8_SANDBOX/pre.snap"
  local out rc=0
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install next to a running ibus-daemon exits non-zero" [ "$rc" -ne 0 ]
  check "install names ibus-daemon" grep -q 'ibus-daemon' <<<"$out"
  snap "$T8_SANDBOX/post.snap"
  check "nothing changed" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
}

t_activation_shadow() {
  # Spike Q6 point 5: an activation request for org.fcitx.Fcitx5 must start
  # vr-talex, not the real fcitx5.
  pre_state_fcitx5
  check "install exits 0" run_install
  systemctl --user stop vr-talex.service
  check "name released after stop" no_owner org.fcitx.Fcitx5
  gdbus call --session --dest org.fcitx.Fcitx5 --object-path / \
    --method org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1 || true
  local apid
  apid=$(owner_pid org.fcitx.Fcitx5 || echo 0)
  check "activation started a process" [ "$apid" != 0 ]
  check "activated process is ~/.local/bin/vr-talex" grep -q "$HOME/.local/bin/vr-talex" "/proc/$apid/cmdline"
  # Stop the activated stub by the pid recorded above (our own process).
  if [ "$apid" != 0 ]; then
    kill -TERM "$apid"
    timeout 5 tail --pid="$apid" -f /dev/null || true
  fi
  check "uninstall exits 0" run_uninstall
  check "fcitx5 runs again" has_owner org.fcitx.Fcitx5
  expect_no_vr_talex_left
}

t_uninstall_without_backup() {
  # The backup was deleted by hand: uninstall removes only what is surely
  # vr-talex's and leaves the rest (no restore is possible).
  check "install exits 0" run_install
  rm -rf -- "${XDG_DATA_HOME:?}/vr-talex/backup"
  local out rc=0
  out=$(run_uninstall 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "uninstall without backup exits 0" [ "$rc" = 0 ]
  check "uninstall warns that no backup exists" grep -q 'no backup found' <<<"$out"
  check "binary removed" [ ! -e "$HOME/.local/bin/vr-talex" ]
  check "unit removed" [ ! -e "$XDG_CONFIG_HOME/systemd/user/vr-talex.service" ]
  check "environment.d file removed" [ ! -e "$XDG_CONFIG_HOME/environment.d/90-vr-talex.conf" ]
  check "autostart override removed" [ ! -e "$XDG_CONFIG_HOME/autostart/org.fcitx.Fcitx5.desktop" ]
  check "D-Bus shadow removed" [ ! -e "$XDG_DATA_HOME/dbus-1/services/org.fcitx.Fcitx5.service" ]
  check "our xinputrc removed" [ ! -e "$HOME/.xinputrc" ]
  check "vr-talex unit inactive" sh -c '! systemctl --user is-active --quiet vr-talex.service'
}

t_uninstall_not_installed() {
  snap "$T8_SANDBOX/pre.snap"
  local out rc=0
  out=$(run_uninstall 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "uninstall without install exits 0" [ "$rc" = 0 ]
  check "says not installed" grep -q 'not installed' <<<"$out"
  snap "$T8_SANDBOX/post.snap"
  check "nothing changed" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
}

saved_copy() { ls -d "$1".vr-talex-saved-* 2>/dev/null | head -n 1 || true; }

t_edited_after_install() {
  # Review blocker 2 + major 5: changes the user makes after install survive
  # uninstall (moved aside with a warning), and so do added input sources.
  pre_state_fcitx5
  cp "$HOME/.xinputrc" "$T8_SANDBOX/pre.xinputrc"
  check "install exits 0" run_install
  printf 'run_im fcitx5\n# my edit\n' >"$HOME/.xinputrc"
  printf 'QT_IM_MODULE=user-edit\n' >"$XDG_CONFIG_HOME/environment.d/90-vr-talex.conf"
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('ibus', 'vr-talex'), ('xkb', 'fr')]"
  gsettings set org.gnome.desktop.input-sources mru-sources "[('xkb', 'fr'), ('ibus', 'vr-talex'), ('xkb', 'us')]"
  local out rc=0 saved
  out=$(run_uninstall 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "uninstall exits 0" [ "$rc" = 0 ]
  check "pre-install ~/.xinputrc restored" cmp -s "$T8_SANDBOX/pre.xinputrc" "$HOME/.xinputrc"
  saved=$(saved_copy "$HOME/.xinputrc")
  check "user's edited ~/.xinputrc kept aside" sh -c "[ -n '$saved' ] && grep -qx '# my edit' '$saved'"
  check "warning names the kept ~/.xinputrc" grep -qF "$saved" <<<"$out"
  check "environment.d file that install created is gone" [ ! -e "$XDG_CONFIG_HOME/environment.d/90-vr-talex.conf" ]
  saved=$(saved_copy "$XDG_CONFIG_HOME/environment.d/90-vr-talex.conf")
  check "user's edited environment.d file kept aside" sh -c "[ -n '$saved' ] && grep -qx 'QT_IM_MODULE=user-edit' '$saved'"
  check "kept copy is not a .conf (environment.d ignores it)" sh -c "case '$saved' in *.conf) exit 1;; esac"
  check "warning names the kept environment.d file" grep -qF "$saved" <<<"$out"
  check "source added after install kept, vr-talex removed" [ "$(gs sources)" = "[('xkb', 'us'), ('xkb', 'fr')]" ]
  check "mru keeps the user's order without vr-talex" [ "$(gs mru-sources)" = "[('xkb', 'fr'), ('xkb', 'us')]" ]
  check "backup removed after a complete uninstall" [ ! -e "$XDG_DATA_HOME/vr-talex/backup" ]
}

t_failed_restore() {
  # Review blocker 1: a restore that fails keeps the user's file, keeps the
  # backup, names the file and exits non-zero; a second uninstall finishes.
  pre_state_fcitx5
  snap "$T8_SANDBOX/pre.snap" noibus
  check "install exits 0" run_install
  local b="$XDG_DATA_HOME/vr-talex/backup/files/.xinputrc" out rc=0 mode
  mode=$(stat -c %a "$b")
  chmod 000 "$b"
  out=$(run_uninstall 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "uninstall with an unreadable backup file exits non-zero" [ "$rc" -ne 0 ]
  check "~/.xinputrc still exists (not deleted before its replacement)" [ -f "$HOME/.xinputrc" ]
  check "backup dir kept" [ -d "$XDG_DATA_HOME/vr-talex/backup" ]
  check "backup manifest kept" [ -f "$XDG_DATA_HOME/vr-talex/backup/manifest" ]
  check "output names the file not restored" grep -q 'not restored:.*\.xinputrc' <<<"$out"
  chmod "$mode" "$b"
  check "second uninstall exits 0" run_uninstall
  snap "$T8_SANDBOX/post.snap" noibus
  check "second uninstall restores everything" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "fcitx5 runs" has_owner org.fcitx.Fcitx5
}

t_symlinked_config() {
  # ~/.config is a symlink into a dotfiles dir and ~/.xinputrc a symlink.
  mkdir -p "$HOME/dotfiles/config"
  ln -s dotfiles/config "$HOME/.config"
  printf 'run_im fcitx5\n' >"$HOME/dotfiles/xinputrc"
  ln -s dotfiles/xinputrc "$HOME/.xinputrc"
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
  fcitx5 -d
  snap "$T8_SANDBOX/pre.snap" noibus
  check "install exits 0" run_install
  check "dotfiles xinputrc target untouched while installed" [ "$(cat "$HOME/dotfiles/xinputrc")" = "run_im fcitx5" ]
  check "~/.config is still a symlink" [ -L "$HOME/.config" ]
  check "uninstall exits 0" run_uninstall
  snap "$T8_SANDBOX/post.snap" noibus
  check "symlinks and targets restored exactly" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "~/.xinputrc is the same symlink again" [ "$(readlink "$HOME/.xinputrc")" = dotfiles/xinputrc ]
}

t_fcitx5_unit() {
  # fcitx5 runs as a systemd user unit: stopped and disabled through
  # systemctl, enabled and started again by uninstall.
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
  mkdir -p "$XDG_CONFIG_HOME/systemd/user"
  printf '[Service]\nExecStart=%s\n[Install]\nWantedBy=graphical-session.target\n' "$T8_STUBS/fcitx5" \
    >"$XDG_CONFIG_HOME/systemd/user/fcitx5.service"
  systemctl --user enable --now fcitx5.service
  local fpid
  fpid=$(owner_pid org.fcitx.Fcitx5)
  snap "$T8_SANDBOX/pre.snap" noibus
  check "install exits 0" run_install
  check "fcitx5.service stopped through systemctl" grep -qx 'systemctl --user stop fcitx5.service' "$XDG_RUNTIME_DIR/stub-calls.log"
  check "fcitx5.service disabled" grep -qx 'systemctl --user disable fcitx5.service' "$XDG_RUNTIME_DIR/stub-calls.log"
  check "no fcitx5-remote call" sh -c "! grep -q fcitx5-remote '$XDG_RUNTIME_DIR/stub-calls.log'"
  check "old fcitx5 ($fpid) has exited" sh -c "! kill -0 $fpid 2>/dev/null"
  expect_installed
  check "uninstall exits 0" run_uninstall
  check "fcitx5.service active again" systemctl --user is-active --quiet fcitx5.service
  check "fcitx5.service enabled again" systemctl --user is-enabled --quiet fcitx5.service
  check "fcitx5 owns its name" [ "$(owner_pid org.fcitx.Fcitx5)" = "$(cat "$XDG_RUNTIME_DIR/stub-systemd/fcitx5.service.pid")" ]
  snap "$T8_SANDBOX/post.snap" noibus
  check "files restored exactly (wants link included)" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
}

t_fcitx5_stuck() {
  # fcitx5 does not quit in time: install rolls back and never kills it.
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
  setsid python3 "$T8_STUBS/fake-ime" fcitx5-stuck </dev/null >>"$XDG_RUNTIME_DIR/fake-fcitx5.log" 2>&1 &
  gdbus wait --session --timeout 5 org.fcitx.Fcitx5
  local fpid out rc=0
  fpid=$(owner_pid org.fcitx.Fcitx5)
  snap "$T8_SANDBOX/pre.snap"
  out=$(VR_TALEX_TIMEOUT=2 run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install exits non-zero" [ "$rc" -ne 0 ]
  check "says fcitx5 did not quit" grep -q 'did not quit' <<<"$out"
  check "rolled back" grep -qi 'rolled back' <<<"$out"
  check "stuck fcitx5 still alive (never killed)" kill -0 "$fpid"
  check "stuck fcitx5 still owns its name" [ "$(owner_pid org.fcitx.Fcitx5)" = "$fpid" ]
  snap "$T8_SANDBOX/post.snap"
  check "nothing changed" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
}

t_reinstall_backup_deleted() {
  # Review major 3: install must not take vr-talex's own files as the
  # "original" state when the backup is gone.
  pre_state_fcitx5
  check "install exits 0" run_install
  rm -rf -- "${XDG_DATA_HOME:?}/vr-talex/backup"
  snap "$T8_SANDBOX/mid.snap"
  local out rc=0
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "re-install without backup exits non-zero" [ "$rc" -ne 0 ]
  check "tells the user to run uninstall first" grep -q 'run ./uninstall.sh first' <<<"$out"
  check "no new backup taken" [ ! -e "$XDG_DATA_HOME/vr-talex/backup" ]
  snap "$T8_SANDBOX/post.snap"
  check "nothing changed" same_snap "$T8_SANDBOX/mid.snap" "$T8_SANDBOX/post.snap"
}

t_special_home() {
  # Review minor 7 / QC note c: a HOME with a space, & and a quote.
  export HOME="$T8_SANDBOX/$SPECIAL_HOME_NAME"
  export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
  mkdir -p "$HOME"
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
  fcitx5 -d
  snap "$T8_SANDBOX/pre.snap" noibus
  check "install exits 0" run_install
  check "vr-talex owns org.fcitx.Fcitx5" [ "$(owner_pid org.fcitx.Fcitx5)" = "$(systemctl --user show -p MainPID --value vr-talex.service)" ]
  systemctl --user stop vr-talex.service
  gdbus call --session --dest org.fcitx.Fcitx5 --object-path / \
    --method org.freedesktop.DBus.Peer.Ping 2>&1 || true
  cat "$XDG_DATA_HOME/dbus-1/services/org.fcitx.Fcitx5.service"
  local apid
  apid=$(owner_pid org.fcitx.Fcitx5 || echo 0)
  check "bus activation through the shadow file started a process" [ "$apid" != 0 ]
  check "activated process is exactly \$HOME/.local/bin/vr-talex" \
    sh -c "tr '\0' '\n' </proc/$apid/cmdline | grep -qxF \"\$1\"" _ "$HOME/.local/bin/vr-talex"
  if [ "$apid" != 0 ]; then
    kill -TERM "$apid"
    timeout 5 tail --pid="$apid" -f /dev/null || true
  fi
  check "uninstall exits 0" run_uninstall
  snap "$T8_SANDBOX/post.snap" noibus
  check "everything restored" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
}

t_rerun_failure() {
  # Review minor 9: a failed re-run says the earlier install was removed.
  pre_state_fcitx5
  snap "$T8_SANDBOX/pre.snap" noibus
  check "install exits 0" run_install
  local out rc=0
  out=$(VR_TALEX_BIN="$T8_STUBS/broken-vr-talex" run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "failed re-run exits non-zero" [ "$rc" -ne 0 ]
  check "says the earlier install was removed" grep -q 'earlier install was removed' <<<"$out"
  check "says how to install again" grep -q 'run ./install.sh again' <<<"$out"
  snap "$T8_SANDBOX/post.snap" noibus
  check "back to the pre-install state" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "fcitx5 runs again" has_owner org.fcitx.Fcitx5
}

t_bad_xdg() {
  # Review minor 8: tab or newline in any XDG dir is refused.
  snap "$T8_SANDBOX/pre.snap"
  local out rc=0 v
  for v in XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME; do
    rc=0
    out=$(env "$v=$HOME/bad$(printf '\t')dir" bash "$T8_REPO/install.sh" 2>&1) || rc=$?
    check "install refuses a tab in $v" sh -c "[ $rc -ne 0 ] && printf '%s' \"\$1\" | grep -q 'tab or newline'" _ "$out"
    rc=0
    out=$(env "$v=$HOME/bad
dir" bash "$T8_REPO/uninstall.sh" 2>&1) || rc=$?
    check "uninstall refuses a newline in $v" sh -c "[ $rc -ne 0 ] && printf '%s' \"\$1\" | grep -q 'tab or newline'" _ "$out"
  done
  local qh="$T8_SANDBOX/q\"h"
  mkdir -p "$qh"
  rc=0
  out=$(HOME="$qh" XDG_CONFIG_HOME="$qh/.config" XDG_DATA_HOME="$qh/.local/share" XDG_STATE_HOME="$qh/.local/state" bash "$T8_REPO/install.sh" 2>&1) || rc=$?
  check "install refuses a HOME with a double quote" sh -c "[ $rc -ne 0 ] && printf '%s' \"\$1\" | grep -q 'double quote'" _ "$out"
  check "nothing written in that HOME" [ -z "$(ls -A "$qh")" ]
  snap "$T8_SANDBOX/post.snap"
  check "nothing changed" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
}

t_edited_then_reinstall() {
  # A re-run of install does not overwrite a managed file the user edited.
  pre_state_fcitx5
  cp "$HOME/.xinputrc" "$T8_SANDBOX/pre.xinputrc"
  check "install exits 0" run_install
  printf 'run_im fcitx5\n# mine\n' >"$HOME/.xinputrc"
  local out rc=0 saved
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "re-install exits 0" [ "$rc" = 0 ]
  saved=$(saved_copy "$HOME/.xinputrc")
  check "edited ~/.xinputrc kept aside" sh -c "[ -n '$saved' ] && grep -qx '# mine' '$saved'"
  check "warning names it" grep -qF "$saved" <<<"$out"
  check "~/.xinputrc is the template again" cmp -s "$T8_REPO/packaging/xinputrc" "$HOME/.xinputrc"
  check "uninstall exits 0" run_uninstall
  check "pre-install ~/.xinputrc restored" cmp -s "$T8_SANDBOX/pre.xinputrc" "$HOME/.xinputrc"
  check "kept copy still there" [ -f "$saved" ]
}

t_record_write_fails() {
  # Re-check finding: recording what install writes fails (disk full in the
  # backup dir). The rollback must leave no vr-talex file behind and print
  # no "was not written by vr-talex" warning. A cp wrapper fails only the
  # copy into backup/installed/ for .xinputrc.
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
  fcitx5 -d
  mkdir -p "$T8_SANDBOX/fullstub"
  cat >"$T8_SANDBOX/fullstub/cp" <<'EOF'
#!/bin/sh
# Fails like a full disk when the copy goes into backup/installed/ and the
# source is the installed ~/.xinputrc content.
src= dst=
for a in "$@"; do
  case "$a" in -*) ;; *) src=$dst; dst=$a ;; esac
done
case "$dst" in
  */vr-talex/backup/installed/*)
    if grep -q "run_im none" "$src" 2>/dev/null; then
      echo "cp: error writing $dst: No space left on device" >&2
      exit 1
    fi
    ;;
esac
exec /usr/bin/cp "$@"
EOF
  chmod +x "$T8_SANDBOX/fullstub/cp"
  snap "$T8_SANDBOX/pre.snap" noibus
  local out rc=0
  out=$(PATH="$T8_SANDBOX/fullstub:$PATH" run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install exits non-zero" [ "$rc" -ne 0 ]
  check "rolled back" grep -qi 'rolled back' <<<"$out"
  check "no wrong \"not written by vr-talex\" warning" sh -c "! printf '%s' \"\$1\" | grep -q 'not written by vr-talex'" _ "$out"
  check "~/.xinputrc not left behind" [ ! -e "$HOME/.xinputrc" ]
  snap "$T8_SANDBOX/post.snap" noibus
  check "everything restored" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "fcitx5 runs again" has_owner org.fcitx.Fcitx5
}

in_sandbox() {
  local name=$1
  guard_sandbox
  : >"$XDG_RUNTIME_DIR/stub-calls.log"
  trap cleanup_stubs EXIT
  echo "== $name (HOME=$HOME)"
  "t_$name"
  echo "== $name: $FAILS failed check(s)"
  [ "$FAILS" = 0 ]
}

if [ "${1:-}" = --in-sandbox ]; then
  in_sandbox "$2"
else
  run_all "$@"
fi
