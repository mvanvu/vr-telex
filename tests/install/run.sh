#!/usr/bin/env bash
# Sandbox tests for install.sh / uninstall.sh (AC-5, AC-6, SEC-19..24) and the
# packaged vr-telex-setup (AC-3, with a stand-in package under the sandbox).
#
# Every scenario runs under `env -i` with a throwaway HOME, XDG dirs and
# XDG_RUNTIME_DIR, on a private bus from `dbus-run-session` whose config
# lists only the sandbox's own D-Bus service dir (the system fcitx5 service
# file can never be activated), with GSETTINGS_BACKEND=keyfile and stubs for
# systemctl, fcitx5 and fcitx5-remote first on PATH. The real HOME, the real
# session bus and the running fcitx5 are never touched (D2, SEC-29).
#
# Usage: bash tests/install/run.sh [scenario...]
#   VR_TELEX_TEST_DIR  where sandboxes and logs go (default: a new temp dir,
#                      removed when every scenario passes)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
STUBS=$HERE/stubs
SCENARIOS=(fresh_fcitx5 fresh_no_fcitx5 empty_sources broken_daemon root_refused
  no_cargo ibus_refused activation_shadow uninstall_without_backup uninstall_not_installed
  edited_after_install failed_restore symlinked_config fcitx5_unit fcitx5_stuck
  reinstall_backup_deleted special_home rerun_failure bad_xdg edited_then_reinstall
  record_write_fails unit_restart_policy uninstall_activation_gap
  uninstall_activation_gap_no_backup fcitx5_owns_ibus_portal ibus_beside_fcitx5_refused reselect_on_rerun
  reselect_rerun_failure reselect_keeps_user_edits
  legacy_migrate legacy_rollback legacy_both_dirs legacy_foreign_file foreign_legacy_name_only
  uninstall_legacy legacy_without_backup legacy_source_only
  legacy_rollback_restore_fails legacy_backup_rm_fails legacy_rollback_default_key
  legacy_source_order legacy_runtime_cleanup uninstall_legacy_runtime_cleanup legacy_newer_mode
  setup_fresh setup_root_refused setup_usage setup_no_package setup_broken_daemon setup_from_source
  install_after_setup setup_unit_override setup_remove_without_backup setup_legacy_migrate
  setup_legacy_keep_selection setup_from_source_edited setup_legacy_then_override)
# A HOME with a space, an ampersand and a quote (special_home scenario).
SPECIAL_HOME_NAME="h o&m'e"

# ---------------------------------------------------------------- outside --

run_all() {
  local root keep=1 failed=0 name sb log rc
  if [ -n "${VR_TELEX_TEST_DIR:-}" ]; then
    root=$VR_TELEX_TEST_DIR
    mkdir -p "$root"
  else
    root=$(mktemp -d "${TMPDIR:-/tmp}/vr-telex-install-test.XXXXXX")
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
      VR_TELEX_BIN="$STUBS/fake-ime" \
      VR_TELEX_TIMEOUT=5 \
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
  main=$(systemctl --user show -p MainPID --value vr-telex.service)
  check "vr-telex unit active" systemctl --user is-active --quiet vr-telex.service
  check "vr-telex unit enabled" systemctl --user is-enabled --quiet vr-telex.service
  check "org.fcitx.Fcitx5 owned by the unit's MainPID ($main)" [ "$(owner_pid org.fcitx.Fcitx5)" = "$main" ]
  check "IBus address file holds the daemon pid" addr_file_pid_is "$main"
  check "binary installed 0755" [ "$(stat -c %a "$HOME/.local/bin/vr-telex")" = 755 ]
  check "binary is VR_TELEX_BIN" cmp -s "$VR_TELEX_BIN" "$HOME/.local/bin/vr-telex"
  check "unit = packaging template" cmp -s "$T8_REPO/packaging/vr-telex.service" "$XDG_CONFIG_HOME/systemd/user/vr-telex.service"
  check "environment.d = packaging template" cmp -s "$T8_REPO/packaging/90-vr-telex.conf" "$XDG_CONFIG_HOME/environment.d/90-vr-telex.conf"
  check "environment.d sets QT_IM_MODULE=fcitx (D27)" grep -qx 'QT_IM_MODULE=fcitx' "$XDG_CONFIG_HOME/environment.d/90-vr-telex.conf"
  check "xinputrc = packaging template" cmp -s "$T8_REPO/packaging/xinputrc" "$HOME/.xinputrc"
  check "autostart override = packaging template" cmp -s "$T8_REPO/packaging/org.fcitx.Fcitx5.desktop" "$XDG_CONFIG_HOME/autostart/org.fcitx.Fcitx5.desktop"
  check "autostart override hides fcitx5" grep -qx 'Hidden=true' "$XDG_CONFIG_HOME/autostart/org.fcitx.Fcitx5.desktop"
  check "D-Bus activation shadow execs vr-telex (quoted)" grep -qxF "Exec=\"$HOME/.local/bin/vr-telex\"" "$XDG_DATA_HOME/dbus-1/services/org.fcitx.Fcitx5.service"
  check "backup manifest exists" [ -f "$XDG_DATA_HOME/vr-telex/backup/manifest" ]
  check "backup dir is 0700" [ "$(stat -c %a "$XDG_DATA_HOME/vr-telex/backup")" = 700 ]
  check "vr-telex source present exactly once" [ "$(gs sources | grep -o "('ibus', 'vr-telex')" | wc -l)" = 1 ]
  check "vr-telex source selected (first in mru-sources)" [ "$(gs mru-sources | cut -c1-21)" = "[('ibus', 'vr-telex')" ]
}

# The vr-telex start after line $1 of the stub log found vr-telex at the head
# of mru-sources: a running gnome-shell reads that list when the daemon
# connects, so this is what makes it select Vietnamese (Telex) (D33).
started_with_vr_head() {
  local line
  line=$(tail -n +$(($1 + 1)) "$XDG_RUNTIME_DIR/stub-calls.log" | grep '^started vr-telex.service ' | tail -n 1 || true)
  printf '  %s\n' "${line:-no vr-telex start logged}"
  case "$line" in
    "started vr-telex.service mru-sources=[('ibus', 'vr-telex')"*) return 0 ;;
  esac
  return 1
}

expect_no_vr_telex_left() {
  local hits='' f
  # The sandbox path itself may contain the name (the checkout's name), so it
  # is cut out of each file before looking for the string. The old name
  # vr-talex (D37) counts too.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if sed "s|$T8_SANDBOX||g" "$f" | grep -qE 'vr-t[ae]lex'; then hits="$hits $f"; fi
    case "${f#"$HOME"}" in *vr-telex* | *vr-talex*) hits="$hits $f" ;; esac
  done < <(grep -rlE 'vr-t[ae]lex' "$XDG_CONFIG_HOME" "$HOME/.local" "$HOME/.xinputrc" 2>/dev/null || true; \
    find "$XDG_CONFIG_HOME" "$HOME/.local" -name '*vr-telex*' -o -name '*vr-talex*' 2>/dev/null || true)
  check "no vr-telex or vr-talex string left in ~/.config, ~/.local, ~/.xinputrc" [ -z "$hits" ]
  [ -z "$hits" ] || printf '  left: %s\n' "$hits"
  check "vr-telex unit inactive" sh -c '! systemctl --user is-active --quiet vr-telex.service'
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
sources=[('xkb', 'us'), ('ibus', 'vr-telex')]
mru-sources=[('ibus', 'vr-telex'), ('xkb', 'us')]
EOF
  check "pre-existing xinputrc backed up byte for byte" cmp -s "$T8_SANDBOX/pre.xinputrc" "$XDG_DATA_HOME/vr-telex/backup/files/.xinputrc"
  check "daemon started only after vr-telex was first in mru-sources (D33)" started_with_vr_head 0
  local main1 calls1
  main1=$(systemctl --user show -p MainPID --value vr-telex.service)
  snap "$T8_SANDBOX/inst1.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/inst1.keyfile"
  calls1=$(wc -l <"$XDG_RUNTIME_DIR/stub-calls.log")

  check "second install exits 0" run_install
  snap "$T8_SANDBOX/inst2.snap" noibus
  check "second install changes no file (snapshot identical)" same_snap "$T8_SANDBOX/inst1.snap" "$T8_SANDBOX/inst2.snap"
  check "second install leaves the keyfile byte-identical" cmp "$T8_SANDBOX/inst1.keyfile" "$(keyfile)"
  # D33: the shell may have kept another source current; only a daemon
  # reconnect makes it read mru-sources again, so a re-run restarts it.
  check "second install restarted the daemon (shell re-reads mru-sources)" [ "$(systemctl --user show -p MainPID --value vr-telex.service)" != "$main1" ]
  check "second install restarted it with vr-telex first in mru-sources" started_with_vr_head "$calls1"
  check "second install did not reload units or touch fcitx5" sh -c "tail -n +$((calls1 + 1)) '$XDG_RUNTIME_DIR/stub-calls.log' | grep -Eq 'daemon-reload|fcitx5-remote' && exit 1 || exit 0"
  check "IBus address file holds the restarted daemon's pid" addr_file_pid_is "$(systemctl --user show -p MainPID --value vr-telex.service)"

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
  expect_no_vr_telex_left
}

t_fresh_no_fcitx5() {
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('xkb', 'de')]"
  snap "$T8_SANDBOX/pre.snap"
  check "install exits 0" run_install
  check "no fcitx5-remote call when fcitx5 is not running" sh -c "! grep -q fcitx5-remote '$XDG_RUNTIME_DIR/stub-calls.log'"
  expect_installed
  check "keyfile after install" diff -u - "$(keyfile)" <<'EOF'
[org/gnome/desktop/input-sources]
sources=[('xkb', 'us'), ('xkb', 'de'), ('ibus', 'vr-telex')]
mru-sources=[('ibus', 'vr-telex'), ('xkb', 'us'), ('xkb', 'de')]
EOF
  check "uninstall exits 0" run_uninstall
  snap "$T8_SANDBOX/post.snap"
  check "everything restored exactly, keyfile and IBus dir included" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "fcitx5 not started by uninstall (it did not run before)" no_owner org.fcitx.Fcitx5
  expect_no_vr_telex_left
}

t_empty_sources() {
  # Keys never set: uninstall must reset them, not write explicit defaults.
  mkdir -p "$HOME/.local/bin"
  printf 'keep me\n' >"$HOME/.local/bin/other-tool"
  local before_rec
  before_rec=$(gsettings list-recursively org.gnome.desktop.input-sources)
  snap "$T8_SANDBOX/pre.snap"
  check "install exits 0" run_install
  check "vr-telex is the only source" [ "$(gs sources)" = "[('ibus', 'vr-telex')]" ]
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
  out=$(VR_TELEX_BIN="$T8_STUBS/broken-vr-telex" run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install with a dying daemon exits non-zero" [ "$rc" -ne 0 ]
  check "install prints the recovery path" grep -q 'systemctl --user disable --now vr-telex.service' <<<"$out"
  check "install says it rolled back" grep -qi 'rolled back' <<<"$out"
  check "the failing daemon was started with vr-telex selected (the rollback had sources to undo)" started_with_vr_head 0
  snap "$T8_SANDBOX/post.snap" noibus
  check "rollback restored every file" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "sources and mru-sources restored exactly (keyfile byte-identical)" cmp "$T8_SANDBOX/pre.keyfile" "$(keyfile)"
  check "fcitx5 runs again after rollback" has_owner org.fcitx.Fcitx5
  expect_no_vr_telex_left
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
  out=$(env -u VR_TELEX_BIN bash "$T8_REPO/install.sh" 2>&1) || rc=$?
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
  # vr-telex, not the real fcitx5.
  pre_state_fcitx5
  check "install exits 0" run_install
  systemctl --user stop vr-telex.service
  check "name released after stop" no_owner org.fcitx.Fcitx5
  gdbus call --session --dest org.fcitx.Fcitx5 --object-path / \
    --method org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1 || true
  local apid
  apid=$(owner_pid org.fcitx.Fcitx5 || echo 0)
  check "activation started a process" [ "$apid" != 0 ]
  check "activated process is ~/.local/bin/vr-telex" grep -q "$HOME/.local/bin/vr-telex" "/proc/$apid/cmdline"
  # Stop the activated stub by the pid recorded above (our own process).
  if [ "$apid" != 0 ]; then
    kill -TERM "$apid"
    timeout 5 tail --pid="$apid" -f /dev/null || true
  fi
  check "uninstall exits 0" run_uninstall
  check "fcitx5 runs again" has_owner org.fcitx.Fcitx5
  expect_no_vr_telex_left
}

t_uninstall_without_backup() {
  # The backup was deleted by hand: uninstall removes only what is surely
  # vr-telex's and leaves the rest (no restore is possible).
  check "install exits 0" run_install
  rm -rf -- "${XDG_DATA_HOME:?}/vr-telex/backup"
  local out rc=0
  out=$(run_uninstall 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "uninstall without backup exits 0" [ "$rc" = 0 ]
  check "uninstall warns that no backup exists" grep -q 'no backup found' <<<"$out"
  check "binary removed" [ ! -e "$HOME/.local/bin/vr-telex" ]
  check "unit removed" [ ! -e "$XDG_CONFIG_HOME/systemd/user/vr-telex.service" ]
  check "environment.d file removed" [ ! -e "$XDG_CONFIG_HOME/environment.d/90-vr-telex.conf" ]
  check "autostart override removed" [ ! -e "$XDG_CONFIG_HOME/autostart/org.fcitx.Fcitx5.desktop" ]
  check "D-Bus shadow removed" [ ! -e "$XDG_DATA_HOME/dbus-1/services/org.fcitx.Fcitx5.service" ]
  check "our xinputrc removed" [ ! -e "$HOME/.xinputrc" ]
  check "vr-telex unit inactive" sh -c '! systemctl --user is-active --quiet vr-telex.service'
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

saved_copy() { ls -d "$1".vr-telex-saved-* 2>/dev/null | head -n 1 || true; }

t_edited_after_install() {
  # Review blocker 2 + major 5: changes the user makes after install survive
  # uninstall (moved aside with a warning), and so do added input sources.
  pre_state_fcitx5
  cp "$HOME/.xinputrc" "$T8_SANDBOX/pre.xinputrc"
  check "install exits 0" run_install
  printf 'run_im fcitx5\n# my edit\n' >"$HOME/.xinputrc"
  printf 'QT_IM_MODULE=user-edit\n' >"$XDG_CONFIG_HOME/environment.d/90-vr-telex.conf"
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('ibus', 'vr-telex'), ('xkb', 'fr')]"
  gsettings set org.gnome.desktop.input-sources mru-sources "[('xkb', 'fr'), ('ibus', 'vr-telex'), ('xkb', 'us')]"
  local out rc=0 saved
  out=$(run_uninstall 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "uninstall exits 0" [ "$rc" = 0 ]
  check "pre-install ~/.xinputrc restored" cmp -s "$T8_SANDBOX/pre.xinputrc" "$HOME/.xinputrc"
  saved=$(saved_copy "$HOME/.xinputrc")
  check "user's edited ~/.xinputrc kept aside" sh -c "[ -n '$saved' ] && grep -qx '# my edit' '$saved'"
  check "warning names the kept ~/.xinputrc" grep -qF "$saved" <<<"$out"
  check "environment.d file that install created is gone" [ ! -e "$XDG_CONFIG_HOME/environment.d/90-vr-telex.conf" ]
  saved=$(saved_copy "$XDG_CONFIG_HOME/environment.d/90-vr-telex.conf")
  check "user's edited environment.d file kept aside" sh -c "[ -n '$saved' ] && grep -qx 'QT_IM_MODULE=user-edit' '$saved'"
  check "kept copy is not a .conf (environment.d ignores it)" sh -c "case '$saved' in *.conf) exit 1;; esac"
  check "warning names the kept environment.d file" grep -qF "$saved" <<<"$out"
  check "source added after install kept, vr-telex removed" [ "$(gs sources)" = "[('xkb', 'us'), ('xkb', 'fr')]" ]
  check "mru keeps the user's order without vr-telex" [ "$(gs mru-sources)" = "[('xkb', 'fr'), ('xkb', 'us')]" ]
  check "backup removed after a complete uninstall" [ ! -e "$XDG_DATA_HOME/vr-telex/backup" ]
}

t_failed_restore() {
  # Review blocker 1: a restore that fails keeps the user's file, keeps the
  # backup, names the file and exits non-zero; a second uninstall finishes.
  pre_state_fcitx5
  snap "$T8_SANDBOX/pre.snap" noibus
  check "install exits 0" run_install
  local b="$XDG_DATA_HOME/vr-telex/backup/files/.xinputrc" out rc=0 mode
  mode=$(stat -c %a "$b")
  chmod 000 "$b"
  out=$(run_uninstall 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "uninstall with an unreadable backup file exits non-zero" [ "$rc" -ne 0 ]
  check "~/.xinputrc still exists (not deleted before its replacement)" [ -f "$HOME/.xinputrc" ]
  check "backup dir kept" [ -d "$XDG_DATA_HOME/vr-telex/backup" ]
  check "backup manifest kept" [ -f "$XDG_DATA_HOME/vr-telex/backup/manifest" ]
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
  out=$(VR_TELEX_TIMEOUT=2 run_install 2>&1) || rc=$?
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
  # Review major 3: install must not take vr-telex's own files as the
  # "original" state when the backup is gone.
  pre_state_fcitx5
  check "install exits 0" run_install
  rm -rf -- "${XDG_DATA_HOME:?}/vr-telex/backup"
  snap "$T8_SANDBOX/mid.snap"
  local out rc=0
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "re-install without backup exits non-zero" [ "$rc" -ne 0 ]
  check "tells the user to run uninstall first" grep -q 'run ./uninstall.sh first' <<<"$out"
  check "no new backup taken" [ ! -e "$XDG_DATA_HOME/vr-telex/backup" ]
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
  check "vr-telex owns org.fcitx.Fcitx5" [ "$(owner_pid org.fcitx.Fcitx5)" = "$(systemctl --user show -p MainPID --value vr-telex.service)" ]
  systemctl --user stop vr-telex.service
  gdbus call --session --dest org.fcitx.Fcitx5 --object-path / \
    --method org.freedesktop.DBus.Peer.Ping 2>&1 || true
  cat "$XDG_DATA_HOME/dbus-1/services/org.fcitx.Fcitx5.service"
  local apid
  apid=$(owner_pid org.fcitx.Fcitx5 || echo 0)
  check "bus activation through the shadow file started a process" [ "$apid" != 0 ]
  check "activated process is exactly \$HOME/.local/bin/vr-telex" \
    sh -c "tr '\0' '\n' </proc/$apid/cmdline | grep -qxF \"\$1\"" _ "$HOME/.local/bin/vr-telex"
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
  out=$(VR_TELEX_BIN="$T8_STUBS/broken-vr-telex" run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "failed re-run exits non-zero" [ "$rc" -ne 0 ]
  check "says the earlier install was removed" grep -q 'earlier install was removed' <<<"$out"
  check "says how to install again" grep -q 'run ./install.sh again' <<<"$out"
  snap "$T8_SANDBOX/post.snap" noibus
  check "back to the pre-install state" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "fcitx5 runs again" has_owner org.fcitx.Fcitx5
}

t_reselect_on_rerun() {
  # D33: the user switched to English after install; running install again
  # puts Vietnamese (Telex) back at the head of mru-sources before the
  # daemon restarts, and uninstall still returns to the pre-install state.
  pre_state_fcitx5
  snap "$T8_SANDBOX/pre.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/pre.keyfile"
  local out1 out2 rc=0
  out1=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out1"
  check "install exits 0" [ "$rc" = 0 ]
  gsettings set org.gnome.desktop.input-sources mru-sources "[('xkb', 'us'), ('ibus', 'vr-telex')]"
  local main1 calls1
  main1=$(systemctl --user show -p MainPID --value vr-telex.service)
  calls1=$(wc -l <"$XDG_RUNTIME_DIR/stub-calls.log")
  out2=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out2"
  check "second install exits 0" [ "$rc" = 0 ]
  # BASE-48: install cannot read the shell's current source back, so it never claims it is selected.
  check "install never prints 'selected'" sh -c '! printf "%s\n%s\n" "$1" "$2" | grep -qi selected' _ "$out1" "$out2"
  check "mru-sources has vr-telex first again" [ "$(gs mru-sources)" = "[('ibus', 'vr-telex'), ('xkb', 'us')]" ]
  check "sources unchanged" [ "$(gs sources)" = "[('xkb', 'us'), ('ibus', 'vr-telex')]" ]
  check "daemon restarted" [ "$(systemctl --user show -p MainPID --value vr-telex.service)" != "$main1" ]
  check "restarted with vr-telex first in mru-sources" started_with_vr_head "$calls1"
  check "uninstall exits 0" run_uninstall
  snap "$T8_SANDBOX/post.snap" noibus
  check "files restored exactly" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "keyfile restored byte for byte" cmp "$T8_SANDBOX/pre.keyfile" "$(keyfile)"
  expect_no_vr_telex_left
}

t_reselect_keeps_user_edits() {
  # Review FR-9 minor 1: after install the user adds a layout and uses it; a
  # re-run puts vr-telex first again, and uninstall still keeps the user's
  # own change (FR-5 rule: only the vr-telex entry is taken out).
  pre_state_fcitx5
  gsettings set org.gnome.desktop.wm.keybindings switch-input-source "['<Control>space']"
  check "install exits 0" run_install
  local rec1 out rc=0
  rec1=$(cat "$XDG_DATA_HOME/vr-telex/backup/installed.gs")
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('ibus', 'vr-telex'), ('xkb', 'de')]"
  gsettings set org.gnome.desktop.input-sources mru-sources "[('xkb', 'de'), ('ibus', 'vr-telex'), ('xkb', 'us')]"
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "second install exits 0" [ "$rc" = 0 ]
  check "mru-sources: vr-telex first, the user's order kept" [ "$(gs mru-sources)" = "[('ibus', 'vr-telex'), ('xkb', 'de'), ('xkb', 'us')]" ]
  check "installed.gs not rewritten by the re-run" [ "$(cat "$XDG_DATA_HOME/vr-telex/backup/installed.gs")" = "$rec1" ]
  check "install names the user's switch shortcut (D33)" grep -qF '<Control>space' <<<"$out"
  check "install does not name Super+Space" sh -c '! printf "%s\n" "$1" | grep -q "Super+Space"' _ "$out"
  check "uninstall exits 0" run_uninstall
  check "sources keep the user's layout" [ "$(gs sources)" = "[('xkb', 'us'), ('xkb', 'de')]" ]
  check "mru-sources keep the user's layout first" [ "$(gs mru-sources)" = "[('xkb', 'de'), ('xkb', 'us')]" ]
  expect_no_vr_telex_left
}

t_reselect_rerun_failure() {
  # SEC-19 on the re-run path: the re-selection is written, the restarted
  # daemon dies, and the rollback leaves the pre-install sources exactly.
  pre_state_fcitx5
  snap "$T8_SANDBOX/pre.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/pre.keyfile"
  check "install exits 0" run_install
  gsettings set org.gnome.desktop.input-sources mru-sources "[('xkb', 'us'), ('ibus', 'vr-telex')]"
  local out rc=0
  out=$(VR_TELEX_BIN="$T8_STUBS/broken-vr-telex" run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "failed re-run exits non-zero" [ "$rc" -ne 0 ]
  check "says it rolled back" grep -qi 'rolled back' <<<"$out"
  snap "$T8_SANDBOX/post.snap" noibus
  check "back to the pre-install files" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "keyfile restored byte for byte" cmp "$T8_SANDBOX/pre.keyfile" "$(keyfile)"
  check "fcitx5 runs again" has_owner org.fcitx.Fcitx5
  expect_no_vr_telex_left
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
  # backup dir). The rollback must leave no vr-telex file behind and print
  # no "was not written by vr-telex" warning. A cp wrapper fails only the
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
  */vr-telex/backup/installed/*)
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
  check "no wrong \"not written by vr-telex\" warning" sh -c "! printf '%s' \"\$1\" | grep -q 'not written by vr-telex'" _ "$out"
  check "~/.xinputrc not left behind" [ ! -e "$HOME/.xinputrc" ]
  snap "$T8_SANDBOX/post.snap" noibus
  check "everything restored" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "fcitx5 runs again" has_owner org.fcitx.Fcitx5
}

t_fcitx5_owns_ibus_portal() {
  # FR-4 on the real desktop: fcitx5's IBus frontend owns
  # org.freedesktop.portal.IBus. That is fcitx5, not ibus-daemon, so install
  # hands it over like any fcitx5, and the name is free afterwards.
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
  setsid python3 "$T8_STUBS/fake-ime" fcitx5-ibus </dev/null >>"$XDG_RUNTIME_DIR/fake-fcitx5.log" 2>&1 &
  gdbus wait --session --timeout 5 org.freedesktop.portal.IBus
  gdbus wait --session --timeout 5 org.fcitx.Fcitx5
  local fpid out rc=0
  fpid=$(owner_pid org.fcitx.Fcitx5)
  check "fcitx5 stub owns the IBus portal name too" [ "$(owner_pid org.freedesktop.portal.IBus)" = "$fpid" ]
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install exits 0" [ "$rc" = 0 ]
  check "install did not take fcitx5 for ibus-daemon" sh -c "! printf '%s' \"\$1\" | grep -q 'ibus-daemon is running'" _ "$out"
  check "fcitx5 asked to quit, not killed" grep -qx 'fcitx5-remote -e' "$XDG_RUNTIME_DIR/stub-calls.log"
  check "old fcitx5 ($fpid) has exited" sh -c "! kill -0 $fpid 2>/dev/null"
  check "nothing owns org.freedesktop.portal.IBus after the hand-over" no_owner org.freedesktop.portal.IBus
  expect_installed
  check "uninstall exits 0" run_uninstall
  check "fcitx5 runs again" has_owner org.fcitx.Fcitx5
  expect_no_vr_telex_left
}

t_ibus_beside_fcitx5_refused() {
  # A real ibus-daemon next to a running fcitx5: the portal owner is not
  # the fcitx5 process, so install still refuses and changes nothing.
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
  fcitx5 -d
  setsid python3 "$T8_STUBS/fake-ime" ibus </dev/null >>"$XDG_RUNTIME_DIR/fake-ibus.log" 2>&1 &
  gdbus wait --session --timeout 5 org.freedesktop.portal.IBus
  snap "$T8_SANDBOX/pre.snap"
  local out rc=0
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install exits non-zero" [ "$rc" -ne 0 ]
  check "install names ibus-daemon" grep -q 'ibus-daemon' <<<"$out"
  check "fcitx5 not asked to quit" sh -c "! grep -q fcitx5-remote '$XDG_RUNTIME_DIR/stub-calls.log'"
  snap "$T8_SANDBOX/post.snap"
  check "nothing changed" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
}

# Value of KEY= in the unit file (last one wins, as in systemd).
unit_value() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

t_unit_restart_policy() {
  # SEC-17 / D22: fast repeated failures (another instance holding the lock,
  # a refused address file, no display yet) must never park the unit in
  # start-limit-hit; it keeps retrying with a back-off instead.
  local u="$T8_REPO/packaging/vr-telex.service" interval steps maxd sec
  interval=$(unit_value "$u" StartLimitIntervalSec)
  steps=$(unit_value "$u" RestartSteps)
  maxd=$(unit_value "$u" RestartMaxDelaySec)
  sec=$(unit_value "$u" RestartSec)
  check "Restart=always" [ "$(unit_value "$u" Restart)" = always ]
  check "first restart within 1 s (RestartSec=$sec)" [ "$sec" = 1 ]
  check "no start rate limit (StartLimitIntervalSec=$interval)" [ "$interval" = 0 ]
  check "restart delay grows in steps (RestartSteps=$steps)" sh -c "[ -n '$steps' ] && [ '$steps' -gt 0 ] 2>/dev/null"
  check "restart delay is capped between 2 and 30 s (RestartMaxDelaySec=$maxd)" \
    sh -c "[ -n '$maxd' ] && [ '$maxd' -ge 2 ] && [ '$maxd' -le 30 ] 2>/dev/null"
  # Offline check by the real systemd parser: it loads the unit in a test
  # manager and reports unknown or misplaced keys; it never talks to the
  # user's own manager. ExecStart needs an executable at %h/.local/bin.
  if command -v systemd-analyze >/dev/null 2>&1; then
    mkdir -p "$HOME/.local/bin" "$XDG_CONFIG_HOME/systemd/user"
    install -m 0755 "$T8_STUBS/fake-ime" "$HOME/.local/bin/vr-telex"
    cp "$u" "$XDG_CONFIG_HOME/systemd/user/vr-telex.service"
    local out rc=0
    out=$(systemd-analyze --user --man=no verify "$XDG_CONFIG_HOME/systemd/user/vr-telex.service" 2>&1) || rc=$?
    printf 'systemd-analyze --user verify (exit %s):\n%s\n' "$rc" "$out"
    check "systemd-analyze --user verify exits 0" [ "$rc" = 0 ]
    # Only lines about this unit count: system units it pulls in may complain
    # about the long sandbox runtime path.
    check "systemd-analyze reports nothing about vr-telex.service" \
      sh -c "! printf '%s\n' \"\$1\" | grep -q 'vr-telex\.service'" _ "$out"
  else
    bad "systemd-analyze not found"
  fi
}

t_uninstall_activation_gap() {
  # Final review: an activation request for org.fcitx.Fcitx5 that arrives
  # right after uninstall stops the unit (a fcitx-route app re-probing the
  # vanished name) must not start vr-telex again; fcitx5 must come back.
  pre_state_fcitx5
  check "install exits 0" run_install
  write_gapstub
  local out rc=0 owner
  out=$(PATH="$T8_SANDBOX/gapstub:$PATH" run_uninstall 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "uninstall exits 0" [ "$rc" = 0 ]
  check "an activation request was sent right after the unit stopped" [ -s "$XDG_RUNTIME_DIR/gap-probe.log" ]
  owner=$(owner_pid org.fcitx.Fcitx5 || echo 0)
  check "org.fcitx.Fcitx5 has an owner" [ "$owner" != 0 ]
  check "the owner is not vr-telex" sh -c "! tr '\0' '\n' </proc/$owner/cmdline 2>/dev/null | grep -q '/.local/bin/vr-telex'"
  # pre_state_fcitx5 made the first "fcitx5 -d" call; uninstall makes the second.
  check "uninstall started fcitx5 again" [ "$(grep -c "^fcitx5 -d" "$XDG_RUNTIME_DIR/stub-calls.log")" -ge 2 ]
  check "no vr-telex process left running" no_vr_telex_alive
  expect_no_vr_telex_left
}

t_uninstall_activation_gap_no_backup() {
  # Same gap on the path where the backup was deleted by hand: uninstall
  # removes only vr-telex's files, and an activation request right after the
  # unit stops must not start vr-telex again.
  pre_state_fcitx5
  check "install exits 0" run_install
  rm -rf -- "${XDG_DATA_HOME:?}/vr-telex/backup"
  write_gapstub
  local out rc=0 owner
  out=$(PATH="$T8_SANDBOX/gapstub:$PATH" run_uninstall 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "uninstall without backup exits 0" [ "$rc" = 0 ]
  check "it took the no-backup path" grep -q 'no backup found' <<<"$out"
  check "an activation request was sent right after the unit stopped" [ -s "$XDG_RUNTIME_DIR/gap-probe.log" ]
  owner=$(owner_pid org.fcitx.Fcitx5 || echo 0)
  check "org.fcitx.Fcitx5 is not owned by vr-telex" \
    sh -c "[ '$owner' = 0 ] || ! tr '\0' '\n' </proc/$owner/cmdline 2>/dev/null | grep -q '/.local/bin/vr-telex'"
  check "no vr-telex process left running" no_vr_telex_alive
  check "D-Bus shadow removed" [ ! -e "$XDG_DATA_HOME/dbus-1/services/org.fcitx.Fcitx5.service" ]
  check "binary removed" [ ! -e "$HOME/.local/bin/vr-telex" ]
}

# True when no fake daemon of role $1 (default vr-telex) the sandbox
# started is still alive.
no_vr_telex_alive() {
  local f pid role=${1:-vr-telex}
  for f in "$XDG_RUNTIME_DIR"/stub-pids/"$role".*; do
    [ -f "$f" ] || continue
    pid=$(cat "$f")
    if kill -0 "$pid" 2>/dev/null; then
      echo "  alive: $pid"
      return 1
    fi
  done
  return 0
}

# A systemctl in front of the stub that, the moment the vr-telex unit has
# been stopped, sends a client call that may auto-start org.fcitx.Fcitx5.
write_gapstub() {
  mkdir -p "$T8_SANDBOX/gapstub"
  cat >"$T8_SANDBOX/gapstub/systemctl" <<'EOF'
#!/bin/sh
# The sandbox systemctl stub, then a client call that may auto-start the
# name, sent the moment the unit has stopped.
rc=0
"$T8_STUBS/systemctl" "$@" || rc=$?
if [ "$*" = "--user disable --now vr-telex.service" ]; then
  echo probe >>"$XDG_RUNTIME_DIR/gap-probe.log"
  gdbus call --session --dest org.fcitx.Fcitx5 --object-path / \
    --method org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1 || true
fi
exit "$rc"
EOF
  chmod +x "$T8_SANDBOX/gapstub/systemctl"
}

# --- legacy vr-talex install (D37) -----------------------------------------
#
# A vr-talex install is made by the vr-talex installer itself: tests/install/
# legacy holds a frozen copy of install.sh and packaging/ from de15649, the
# last commit before the rename. The fake daemon is installed as
# ~/.local/bin/vr-talex and takes the role "vr-talex" from that name.

legacy_install() {
  VR_TALEX_BIN="$T8_STUBS/fake-ime" VR_TALEX_TIMEOUT=5 bash "$T8_REPO/tests/install/legacy/install.sh"
}

legacy_files_gone() {
  check "vr-talex unit file removed" [ ! -e "$XDG_CONFIG_HOME/systemd/user/vr-talex.service" ]
  check "vr-talex unit not enabled" sh -c '! systemctl --user is-enabled --quiet vr-talex.service'
  check "vr-talex unit inactive" sh -c '! systemctl --user is-active --quiet vr-talex.service'
  if [ "${1:-}" != keepbin ]; then check "~/.local/bin/vr-talex removed" [ ! -e "$HOME/.local/bin/vr-talex" ]; fi
  check "~/.local/state/vr-talex removed" [ ! -e "$XDG_STATE_HOME/vr-talex" ]
  check "no vr-talex process left running" no_vr_telex_alive vr-talex
}

no_migration_leftovers() {
  check "no migration snapshot left" sh -c "! ls -d '$XDG_DATA_HOME'/.vr-telex-migrate.* 2>/dev/null"
  check "no migration marker left" [ ! -e "$XDG_DATA_HOME/vr-telex/backup/from-vr-talex" ]
}

t_legacy_migrate() {
  # D37: install over a running vr-talex install moves it to vr-telex, and
  # uninstall afterwards still returns to the setup from before vr-talex.
  pre_state_fcitx5
  cp "$HOME/.xinputrc" "$T8_SANDBOX/pre.xinputrc"
  snap "$T8_SANDBOX/pre.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/pre.keyfile"
  check "vr-talex installer exits 0" legacy_install
  check "vr-talex runs" systemctl --user is-active --quiet vr-talex.service
  check "vr-talex source selected" [ "$(gs mru-sources)" = "[('ibus', 'vr-talex'), ('xkb', 'us')]" ]
  # The user switched to EN while vr-talex ran.
  mkdir -p "$XDG_STATE_HOME/vr-talex"
  printf 'EN\n' >"$XDG_STATE_HOME/vr-talex/mode"
  local old_pid out rc=0 calls0 calls1
  old_pid=$(systemctl --user show -p MainPID --value vr-talex.service)
  calls0=$(wc -l <"$XDG_RUNTIME_DIR/stub-calls.log")
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install over vr-talex exits 0" [ "$rc" = 0 ]
  check "says it moved the vr-talex install" grep -q 'moved the vr-talex install to vr-telex' <<<"$out"
  check "no 'kept the older backup' warning (there was one backup)" sh -c '! printf "%s" "$1" | grep -q "kept the older backup"' _ "$out"
  check "vr-talex stopped through systemctl" grep -qx 'systemctl --user disable --now vr-talex.service' "$XDG_RUNTIME_DIR/stub-calls.log"
  check "old daemon ($old_pid) has exited" sh -c "! kill -0 $old_pid 2>/dev/null"
  legacy_files_gone
  check "90-vr-talex.conf removed" [ ! -e "$XDG_CONFIG_HOME/environment.d/90-vr-talex.conf" ]
  check "~/.local/share/vr-talex removed" [ ! -e "$XDG_DATA_HOME/vr-talex" ]
  check "sources: vr-talex renamed in place" [ "$(gs sources)" = "[('xkb', 'us'), ('ibus', 'vr-telex')]" ]
  expect_installed
  check "VI/EN mode carried over" [ "$(cat "$XDG_STATE_HOME/vr-telex/mode" 2>/dev/null)" = EN ]
  local b="$XDG_DATA_HOME/vr-telex/backup"
  check "backup manifest names no vr-talex" sh -c "! grep -q vr-talex '$b/manifest'"
  check "manifest: no vr-telex binary before vr-talex" grep -qxF "file	.local/bin/vr-telex	absent" "$b/manifest"
  check "manifest: the vr-telex state dir is install's" grep -qxF "dir	.local/share/vr-telex" "$b/manifest"
  check "pre-vr-talex ~/.xinputrc still in the backup" cmp -s "$T8_SANDBOX/pre.xinputrc" "$b/files/.xinputrc"
  check "installed.gs names vr-telex" grep -qF "mru-sources	[('ibus', 'vr-telex'), ('xkb', 'us')]" "$b/installed.gs"
  check "the recorded unit file moved to its new name" [ -f "$b/installed/.config/systemd/user/vr-telex.service" ]
  no_migration_leftovers
  check "daemon started only with vr-telex first in mru-sources" started_with_vr_head "$calls0"

  snap "$T8_SANDBOX/inst1.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/inst1.keyfile"
  calls1=$(wc -l <"$XDG_RUNTIME_DIR/stub-calls.log")
  rc=0
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "second install exits 0" [ "$rc" = 0 ]
  check "second install finds nothing of vr-talex" sh -c '! printf "%s" "$1" | grep -q vr-talex' _ "$out"
  snap "$T8_SANDBOX/inst2.snap" noibus
  check "second install changes no file" same_snap "$T8_SANDBOX/inst1.snap" "$T8_SANDBOX/inst2.snap"
  check "second install leaves the keyfile byte-identical" cmp "$T8_SANDBOX/inst1.keyfile" "$(keyfile)"
  check "second install did not stop, start or change vr-talex" sh -c "tail -n +$((calls1 + 1)) '$XDG_RUNTIME_DIR/stub-calls.log' | grep -Eq '^systemctl --user (disable|enable|stop|start|restart) .*vr-talex' && exit 1 || exit 0"

  check "uninstall exits 0" run_uninstall
  snap "$T8_SANDBOX/post.snap" noibus
  check "files back to the state before vr-talex" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "keyfile back to the state before vr-talex" cmp "$T8_SANDBOX/pre.keyfile" "$(keyfile)"
  check "fcitx5 started again" has_owner org.fcitx.Fcitx5
  expect_no_vr_telex_left
}

t_legacy_rollback() {
  # The new daemon does not come up: the vr-talex install comes back exactly
  # and runs again, instead of both being removed (no IME left, D31).
  pre_state_fcitx5
  snap "$T8_SANDBOX/pre.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/pre.keyfile"
  check "vr-talex installer exits 0" legacy_install
  mkdir -p "$XDG_STATE_HOME/vr-talex"
  printf 'EN\n' >"$XDG_STATE_HOME/vr-talex/mode"
  snap "$T8_SANDBOX/legacy.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/legacy.keyfile"
  local out rc=0 main
  out=$(VR_TELEX_BIN="$T8_STUBS/broken-vr-telex" run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install with a dying daemon exits non-zero" [ "$rc" -ne 0 ]
  check "says vr-talex runs again" grep -q 'vr-talex runs again' <<<"$out"
  check "prints the vr-talex recovery path" grep -q 'systemctl --user disable --now vr-talex.service' <<<"$out"
  check "the new daemon was started with vr-telex first (there was something to undo)" started_with_vr_head 0
  snap "$T8_SANDBOX/post.snap" noibus
  check "every file back to the vr-talex install" same_snap "$T8_SANDBOX/legacy.snap" "$T8_SANDBOX/post.snap"
  check "input sources back to vr-talex (keyfile byte-identical)" cmp "$T8_SANDBOX/legacy.keyfile" "$(keyfile)"
  main=$(systemctl --user show -p MainPID --value vr-talex.service)
  check "vr-talex unit active again" systemctl --user is-active --quiet vr-talex.service
  check "vr-talex unit enabled again" systemctl --user is-enabled --quiet vr-talex.service
  check "org.fcitx.Fcitx5 owned by vr-talex ($main)" [ "$(owner_pid org.fcitx.Fcitx5)" = "$main" ]
  check "IBus address file holds vr-talex's pid" addr_file_pid_is "$main"
  check "vr-telex unit inactive" sh -c '! systemctl --user is-active --quiet vr-telex.service'

  # Fixed: the next run moves it, and uninstall still reaches the start.
  check "install with a working daemon exits 0" run_install
  expect_installed
  legacy_files_gone
  check "uninstall exits 0" run_uninstall
  snap "$T8_SANDBOX/end.snap" noibus
  check "files back to the state before vr-talex" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/end.snap"
  check "keyfile back to the state before vr-talex" cmp "$T8_SANDBOX/pre.keyfile" "$(keyfile)"
}

# A vr-telex backup made from the vr-talex one, with the saved sources
# changed so the tests can tell which backup uninstall used.
make_telex_backup() {
  local b="$XDG_DATA_HOME/vr-telex/backup"
  cp -a "$XDG_DATA_HOME/vr-talex" "$XDG_DATA_HOME/vr-telex"
  perl -pi -e 's/vr-talex/vr-telex/g' "$b/manifest" "$b/installed.gs"
  perl -pi -e "s/^gs\tsources\t.*/gs\tsources\t[('xkb', 'us'), ('xkb', 'fr')]/" "$b/manifest"
  mv "$b/installed/.local/bin/vr-talex" "$b/installed/.local/bin/vr-telex"
  mv "$b/installed/.config/systemd/user/vr-talex.service" "$b/installed/.config/systemd/user/vr-telex.service"
  mv "$b/installed/.config/environment.d/90-vr-talex.conf" "$b/installed/.config/environment.d/90-vr-telex.conf"
}

legacy_backup_sum() { (cd "$XDG_DATA_HOME/vr-talex" && find . -printf '%y %m %p\n' | LC_ALL=C sort && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum); }

t_legacy_both_dirs() {
  # Both backups exist: the vr-telex one is used, the vr-talex one is left
  # untouched and reported; the rest of vr-talex is still moved.
  pre_state_fcitx5
  check "vr-talex installer exits 0" legacy_install
  make_telex_backup
  legacy_backup_sum >"$T8_SANDBOX/legacy.sum"
  local out rc=0
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install exits 0" [ "$rc" = 0 ]
  check "warns that the older backup is kept" grep -q 'kept the older backup' <<<"$out"
  check "vr-talex backup untouched" sh -c "legacy_sum=\$(cat '$T8_SANDBOX/legacy.sum'); [ \"\$legacy_sum\" = \"\$1\" ]" _ "$(legacy_backup_sum)"
  legacy_files_gone
  check "sources: vr-talex renamed in place" [ "$(gs sources)" = "[('xkb', 'us'), ('ibus', 'vr-telex')]" ]
  expect_installed
  no_migration_leftovers
  snap "$T8_SANDBOX/inst1.snap" noibus
  rc=0
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "second install exits 0" [ "$rc" = 0 ]
  snap "$T8_SANDBOX/inst2.snap" noibus
  check "second install changes no file" same_snap "$T8_SANDBOX/inst1.snap" "$T8_SANDBOX/inst2.snap"
  rc=0
  out=$(run_uninstall 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "uninstall exits 0" [ "$rc" = 0 ]
  check "uninstall used the vr-telex backup" [ "$(gs sources)" = "[('xkb', 'us'), ('xkb', 'fr')]" ]
  check "vr-talex backup still untouched" sh -c "legacy_sum=\$(cat '$T8_SANDBOX/legacy.sum'); [ \"\$legacy_sum\" = \"\$1\" ]" _ "$(legacy_backup_sum)"
  check "uninstall says the older backup is kept" grep -q 'kept the older backup' <<<"$out"
}

t_legacy_foreign_file() {
  # A file at a vr-talex path that is not what vr-talex installed (here the
  # user edited its environment file) is never deleted (SEC-24).
  pre_state_fcitx5
  check "vr-talex installer exits 0" legacy_install
  local env="$XDG_CONFIG_HOME/environment.d/90-vr-talex.conf" out rc=0
  printf 'MY_VAR=1\n' >"$env"
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install exits 0" [ "$rc" = 0 ]
  check "the edited 90-vr-talex.conf is left in place" grep -qx 'MY_VAR=1' "$env"
  check "the warning names it" grep -qF "$env is not the file vr-talex installed" <<<"$out"
  legacy_files_gone
  expect_installed
  snap "$T8_SANDBOX/inst1.snap" noibus
  check "second install exits 0" run_install
  snap "$T8_SANDBOX/inst2.snap" noibus
  check "second install changes no file" same_snap "$T8_SANDBOX/inst1.snap" "$T8_SANDBOX/inst2.snap"
  check "uninstall exits 0" run_uninstall
  check "the edited 90-vr-talex.conf survives uninstall" grep -qx 'MY_VAR=1' "$env"
}

t_foreign_legacy_name_only() {
  # No vr-talex install, only a file of the user's under that name (a
  # wrapper that even names vr-talex): not taken for an install, never
  # deleted, by uninstall or install (SEC-21, SEC-24).
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\nexec "$HOME/src/vr-talex/target/release/vr-talex" "$@"\n' >"$HOME/.local/bin/vr-talex"
  chmod 0755 "$HOME/.local/bin/vr-talex"
  cp -p "$HOME/.local/bin/vr-talex" "$T8_SANDBOX/mine"
  local out rc=0
  out=$(run_uninstall 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "uninstall before any install exits 0" [ "$rc" = 0 ]
  check "uninstall says nothing is installed" grep -q 'not installed' <<<"$out"
  check "uninstall left the user's wrapper untouched" same_entry_t "$T8_SANDBOX/mine" "$HOME/.local/bin/vr-talex"
  rc=0
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install exits 0" [ "$rc" = 0 ]
  check "no migration attempted" sh -c '! printf "%s" "$1" | grep -q "old name"' _ "$out"
  check "the user's ~/.local/bin/vr-talex is untouched" same_entry_t "$T8_SANDBOX/mine" "$HOME/.local/bin/vr-talex"
  expect_installed
  check "uninstall exits 0" run_uninstall
  check "the user's ~/.local/bin/vr-talex survives uninstall" same_entry_t "$T8_SANDBOX/mine" "$HOME/.local/bin/vr-talex"
}

same_entry_t() { cmp -s "$1" "$2" && [ "$(stat -c %a "$1")" = "$(stat -c %a "$2")" ]; }

t_uninstall_legacy() {
  # The new uninstall.sh run on a vr-talex install (install.sh never ran)
  # restores the setup vr-talex saved and removes vr-talex.
  pre_state_fcitx5
  snap "$T8_SANDBOX/pre.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/pre.keyfile"
  check "vr-talex installer exits 0" legacy_install
  mkdir -p "$XDG_STATE_HOME/vr-talex"
  printf 'EN\n' >"$XDG_STATE_HOME/vr-talex/mode"
  local out rc=0
  out=$(run_uninstall 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "uninstall exits 0" [ "$rc" = 0 ]
  check "says it found vr-talex" grep -q 'old name vr-talex' <<<"$out"
  legacy_files_gone
  snap "$T8_SANDBOX/post.snap" noibus
  check "files back to the state before vr-talex" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "keyfile back to the state before vr-talex" cmp "$T8_SANDBOX/pre.keyfile" "$(keyfile)"
  check "fcitx5 started again" has_owner org.fcitx.Fcitx5
  expect_no_vr_telex_left
}

t_legacy_without_backup() {
  # vr-talex with its backup deleted by hand: install refuses before any
  # change; uninstall removes only vr-talex's own files and its source.
  pre_state_fcitx5
  check "vr-talex installer exits 0" legacy_install
  rm -rf -- "${XDG_DATA_HOME:?}/vr-talex"
  snap "$T8_SANDBOX/mid.snap"
  local out rc=0
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install exits non-zero" [ "$rc" -ne 0 ]
  check "tells the user to run uninstall first" grep -q 'run ./uninstall.sh first' <<<"$out"
  snap "$T8_SANDBOX/post.snap"
  check "nothing changed" same_snap "$T8_SANDBOX/mid.snap" "$T8_SANDBOX/post.snap"
  check "vr-talex still runs" systemctl --user is-active --quiet vr-talex.service
  rc=0
  out=$(run_uninstall 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "uninstall exits 0" [ "$rc" = 0 ]
  legacy_files_gone keepbin
  # Without vr-talex's record the binary cannot be told from a file of the
  # user's, so it is left and named (SEC-21).
  check "unrecorded ~/.local/bin/vr-talex left in place" [ -f "$HOME/.local/bin/vr-talex" ]
  check "the warning names it" grep -qF "$HOME/.local/bin/vr-talex cannot be told apart" <<<"$out"
  rm -f -- "$HOME/.local/bin/vr-talex"
  check "90-vr-talex.conf removed" [ ! -e "$XDG_CONFIG_HOME/environment.d/90-vr-talex.conf" ]
  check "D-Bus shadow vr-talex wrote removed" [ ! -e "$XDG_DATA_HOME/dbus-1/services/org.fcitx.Fcitx5.service" ]
  check "autostart override vr-talex wrote removed" [ ! -e "$XDG_CONFIG_HOME/autostart/org.fcitx.Fcitx5.desktop" ]
  check "~/.xinputrc vr-talex wrote removed" [ ! -e "$HOME/.xinputrc" ]
  check "vr-talex source dropped from sources" [ "$(gs sources)" = "[('xkb', 'us')]" ]
  check "vr-talex source dropped from mru-sources" [ "$(gs mru-sources)" = "[('xkb', 'us')]" ]
  expect_no_vr_telex_left
}


t_legacy_source_only() {
  # Only a dead vr-talex entry is left in the input sources (an old uninstall
  # without a backup kept it): install drops it before taking the backup, so
  # uninstall does not bring it back either.
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('ibus', 'vr-talex')]"
  gsettings set org.gnome.desktop.input-sources mru-sources "[('ibus', 'vr-talex'), ('xkb', 'us')]"
  local out rc=0
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install exits 0" [ "$rc" = 0 ]
  check "the vr-talex entry is gone, vr-telex added once" [ "$(gs sources)" = "[('xkb', 'us'), ('ibus', 'vr-telex')]" ]
  check "backup holds the sources without the dead entry" grep -qxF "gs	sources	[('xkb', 'us')]" "$XDG_DATA_HOME/vr-telex/backup/manifest"
  expect_installed
  check "uninstall exits 0" run_uninstall
  check "sources after uninstall" [ "$(gs sources)" = "[('xkb', 'us')]" ]
  check "mru-sources after uninstall" [ "$(gs mru-sources)" = "[('xkb', 'us')]" ]
  expect_no_vr_telex_left
}


t_legacy_rollback_restore_fails() {
  # The rollback to vr-talex cannot put a file back (a
  # cp that fails for copies out of the snapshot): the snapshot is kept and
  # its path printed, never deleted.
  pre_state_fcitx5
  check "vr-talex installer exits 0" legacy_install
  mkdir -p "$T8_SANDBOX/cpstub"
  cat >"$T8_SANDBOX/cpstub/cp" <<'EOS'
#!/bin/sh
for a in "$@"; do
  case "$a" in -*) ;; *) src=$a; break ;; esac
done
case "$src" in
  */.vr-telex-migrate.*) echo "cp: cannot read $src: Input/output error" >&2; exit 1 ;;
esac
exec /usr/bin/cp "$@"
EOS
  chmod +x "$T8_SANDBOX/cpstub/cp"
  local out rc=0 kept
  out=$(PATH="$T8_SANDBOX/cpstub:$PATH" VR_TELEX_BIN="$T8_STUBS/broken-vr-telex" run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install exits non-zero" [ "$rc" -ne 0 ]
  check "says the rollback is incomplete" grep -q 'rollback is incomplete' <<<"$out"
  kept=$(sed -n 's/.*kept in \(.*\.vr-telex-migrate\.[A-Za-z0-9]*\).*/\1/p' <<<"$out" | head -n 1)
  check "names the kept snapshot" [ -n "$kept" ]
  check "the snapshot is still there, with its saved files" sh -c "[ -f '$kept/list' ] && [ -f '$kept/files/.xinputrc' ]"
}

t_legacy_backup_rm_fails() {
  # The old backup cannot be removed after a healthy
  # start: a warning, and install still succeeds.
  pre_state_fcitx5
  check "vr-talex installer exits 0" legacy_install
  mkdir -p "$T8_SANDBOX/rmstub"
  cat >"$T8_SANDBOX/rmstub/rm" <<'EOS'
#!/bin/sh
for a in "$@"; do
  case "$a" in */vr-talex/backup) echo "rm: cannot remove '$a': Permission denied" >&2; exit 1 ;; esac
done
exec /usr/bin/rm "$@"
EOS
  chmod +x "$T8_SANDBOX/rmstub/rm"
  local out rc=0
  out=$(PATH="$T8_SANDBOX/rmstub:$PATH" run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install exits 0" [ "$rc" = 0 ]
  check "warns that the older backup could not be removed" grep -q 'could not remove the older backup' <<<"$out"
  check "the rest of the cleanup ran (vr-talex source renamed, unit file gone)" \
    sh -c "[ ! -e '$XDG_CONFIG_HOME/systemd/user/vr-talex.service' ]"
  expect_installed
}

t_legacy_rollback_default_key() {
  # A key at its default before the run (the user reset
  # mru-sources) is unset again after the rollback, not written.
  pre_state_fcitx5
  check "vr-talex installer exits 0" legacy_install
  gsettings reset org.gnome.desktop.input-sources mru-sources
  cp "$(keyfile)" "$T8_SANDBOX/legacy.keyfile"
  local out rc=0
  out=$(VR_TELEX_BIN="$T8_STUBS/broken-vr-telex" run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install exits non-zero" [ "$rc" -ne 0 ]
  check "rolled back to vr-talex" grep -q 'vr-talex runs again' <<<"$out"
  check "mru-sources not set in the keyfile" sh -c "! grep -q '^mru-sources=' '$(keyfile)'"
  check "keyfile byte-identical to before the run" cmp "$T8_SANDBOX/legacy.keyfile" "$(keyfile)"
}

t_legacy_source_order() {
  # AC-2: the vr-talex entry is renamed at its own index (here the first of
  # three) and the current source stays current: English was selected (head
  # of mru-sources), so it still is after the move.
  pre_state_fcitx5
  check "vr-talex installer exits 0" legacy_install
  gsettings set org.gnome.desktop.input-sources sources "[('ibus', 'vr-talex'), ('xkb', 'us'), ('xkb', 'fr')]"
  gsettings set org.gnome.desktop.input-sources mru-sources "[('xkb', 'us'), ('ibus', 'vr-talex'), ('xkb', 'fr')]"
  local out rc=0
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install exits 0" [ "$rc" = 0 ]
  check "says it moved the vr-talex install" grep -q 'moved the vr-talex install to vr-telex' <<<"$out"
  check "sources: renamed at index 0, others in order" \
    [ "$(gs sources)" = "[('ibus', 'vr-telex'), ('xkb', 'us'), ('xkb', 'fr')]" ]
  check "mru-sources: English still current, vr-telex at its old place" \
    [ "$(gs mru-sources)" = "[('xkb', 'us'), ('ibus', 'vr-telex'), ('xkb', 'fr')]" ]
  check "does not claim to have put vr-telex first" sh -c '! printf "%s" "$1" | grep -q "first"' _ "$out"
  legacy_files_gone
  no_migration_leftovers
  check "vr-telex unit active" systemctl --user is-active --quiet vr-telex.service
  check "IBus address file holds the daemon pid" \
    addr_file_pid_is "$(systemctl --user show -p MainPID --value vr-telex.service)"
  # The lists differ from what the vr-talex installer recorded, so uninstall
  # keeps the user's lists and takes out only vr-telex (gs_restore).
  check "uninstall exits 0" run_uninstall
  check "sources after uninstall" [ "$(gs sources)" = "[('xkb', 'us'), ('xkb', 'fr')]" ]
  check "mru-sources after uninstall" [ "$(gs mru-sources)" = "[('xkb', 'us'), ('xkb', 'fr')]" ]
  expect_no_vr_telex_left
}

# Leftovers of a vr-talex daemon that died without cleaning up: an address
# file for another display pointing into its runtime dir, its lock and
# socket, plus an address file of another daemon that must stay. With
# "foreign", a file of someone else's in the runtime dir too.
plant_legacy_runtime() {
  local mid busdir="$XDG_CONFIG_HOME/ibus/bus" rt="$XDG_RUNTIME_DIR/vr-talex"
  mid=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.Peer.GetMachineId)
  mid=${mid#*\'}
  mid=${mid%%\'*}
  mkdir -p "$busdir" "$rt"
  printf 'IBUS_ADDRESS=unix:path=%s/ibus\nIBUS_DAEMON_PID=999999\n' "$rt" >"$busdir/$mid-unix-:1"
  printf 'IBUS_ADDRESS=unix:path=%s/other-ime/ibus\nIBUS_DAEMON_PID=1\n' "$XDG_RUNTIME_DIR" >"$busdir/$mid-unix-:2"
  : >"$rt/ibus.lock"
  : >"$rt/ibus"
  if [ "${1:-}" = foreign ]; then printf 'keep\n' >"$rt/notes.txt"; fi
  LEGACY_ADDR=$busdir/$mid-unix-:1
  OTHER_ADDR=$busdir/$mid-unix-:2
}

expect_legacy_runtime_cleaned() {
  local rt="$XDG_RUNTIME_DIR/vr-talex"
  check "stale vr-talex address file removed" [ ! -e "$LEGACY_ADDR" ]
  check "another daemon's address file kept" grep -qx 'IBUS_DAEMON_PID=1' "$OTHER_ADDR"
  check "vr-talex ibus.lock removed" [ ! -e "$rt/ibus.lock" ]
  check "vr-talex ibus socket removed" [ ! -e "$rt/ibus" ]
  if [ "${1:-}" = foreign ]; then
    check "a foreign file in the runtime dir is kept" grep -qx keep "$rt/notes.txt"
    check "the runtime dir holding it is kept" [ -d "$rt" ]
  else
    check "the emptied runtime dir is removed" [ ! -e "$rt" ]
  fi
}

t_legacy_runtime_cleanup() {
  # AC-2: install over vr-talex removes its runtime address files and its
  # own runtime entries, and nothing else there.
  pre_state_fcitx5
  check "vr-talex installer exits 0" legacy_install
  plant_legacy_runtime foreign
  local out rc=0
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install exits 0" [ "$rc" = 0 ]
  expect_legacy_runtime_cleaned foreign
  legacy_files_gone
  expect_installed
}

t_uninstall_legacy_runtime_cleanup() {
  # The same leftovers through uninstall.sh on a vr-talex install.
  pre_state_fcitx5
  check "vr-talex installer exits 0" legacy_install
  plant_legacy_runtime
  local out rc=0
  out=$(run_uninstall 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "uninstall exits 0" [ "$rc" = 0 ]
  expect_legacy_runtime_cleaned
  legacy_files_gone
  expect_no_vr_telex_left
}

t_legacy_newer_mode() {
  # AC-2 "no overwrite of existing newer data": a vr-telex mode file present
  # before the move wins over the vr-talex one, which is removed.
  pre_state_fcitx5
  check "vr-talex installer exits 0" legacy_install
  mkdir -p "$XDG_STATE_HOME/vr-talex" "$XDG_STATE_HOME/vr-telex"
  printf 'EN\n' >"$XDG_STATE_HOME/vr-talex/mode"
  printf 'VI\n' >"$XDG_STATE_HOME/vr-telex/mode"
  local out rc=0
  out=$(run_install 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "install exits 0" [ "$rc" = 0 ]
  check "the newer vr-telex mode (VI) is kept" [ "$(cat "$XDG_STATE_HOME/vr-telex/mode" 2>/dev/null)" = VI ]
  check "the vr-talex mode file is removed" [ ! -e "$XDG_STATE_HOME/vr-talex/mode" ]
  legacy_files_gone
  expect_installed
}

# --- packaged setup: vr-telex-setup (AC-3) -----------------------------------
#
# A stand-in for the installed package under $T8_SANDBOX/pkg: the shared
# files as the .deb ships them (only those, so the setup cannot lean on the
# checkout), the daemon at usr/bin/vr-telex and the packaged unit with its
# ExecStart pointing there. The stub systemctl finds that unit through
# VR_TELEX_SYSTEM_UNIT_DIR, as systemd finds /usr/lib/systemd/user units.
# $1 = the daemon to package (default: fake-ime).
PKG_SHARE_FILES=(common.sh 90-vr-telex.conf xinputrc org.fcitx.Fcitx5.desktop org.fcitx.Fcitx5.service)

make_pkg() {
  local daemon=${1:-$T8_STUBS/fake-ime} f
  PKG=$T8_SANDBOX/pkg
  if [ -e "$PKG" ]; then rm -rf -- "${PKG:?}"; fi
  mkdir -p "$PKG/usr/bin" "$PKG/usr/share/vr-telex" "$PKG/usr/lib/systemd/user" "$T8_SANDBOX/nocargo"
  for f in "${PKG_SHARE_FILES[@]}"; do install -m 0644 "$T8_REPO/packaging/$f" "$PKG/usr/share/vr-telex/$f"; done
  install -m 0755 "$daemon" "$PKG/usr/bin/vr-telex"
  install -m 0755 "$T8_REPO/packaging/vr-telex-setup" "$PKG/usr/bin/vr-telex-setup"
  sed "s|^ExecStart=/usr/bin/vr-telex\$|ExecStart=$PKG/usr/bin/vr-telex|" \
    "$T8_REPO/packaging/deb/vr-telex.service" >"$PKG/usr/lib/systemd/user/vr-telex.service"
  grep -qxF "ExecStart=$PKG/usr/bin/vr-telex" "$PKG/usr/lib/systemd/user/vr-telex.service"
  # A cargo that only logs: the setup must never build.
  printf '#!/bin/sh\necho "cargo $*" >>"$XDG_RUNTIME_DIR/stub-calls.log"\nexit 1\n' >"$T8_SANDBOX/nocargo/cargo"
  chmod +x "$T8_SANDBOX/nocargo/cargo"
  export VR_TELEX_SYSTEM_UNIT_DIR=$PKG/usr/lib/systemd/user
}

run_setup() {
  VR_TELEX_SHARE="$PKG/usr/share/vr-telex" VR_TELEX_BIN="$PKG/usr/bin/vr-telex" \
    PATH="$T8_SANDBOX/nocargo:$PATH" bash "$PKG/usr/bin/vr-telex-setup" "$@"
}

pkg_sum() { (cd "$PKG" && find . -printf '%y %m %p\n' | LC_ALL=C sort && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum); }

expect_setup_installed() {
  local main u="$XDG_CONFIG_HOME/systemd/user" s="$PKG/usr/share/vr-telex"
  main=$(systemctl --user show -p MainPID --value vr-telex.service)
  check "vr-telex unit active" systemctl --user is-active --quiet vr-telex.service
  check "vr-telex unit enabled" systemctl --user is-enabled --quiet vr-telex.service
  check "enabled through the packaged unit" \
    [ "$(readlink "$u/graphical-session.target.wants/vr-telex.service")" = "$VR_TELEX_SYSTEM_UNIT_DIR/vr-telex.service" ]
  check "no unit file of its own in ~/.config/systemd/user" [ ! -e "$u/vr-telex.service" ]
  check "nothing in ~/.local/bin" sh -c "! ls -A '$HOME/.local/bin' 2>/dev/null | grep -q ."
  check "the daemon is the packaged binary" sh -c "tr '\0' '\n' </proc/$main/cmdline | grep -qxF \"\$1\"" _ "$PKG/usr/bin/vr-telex"
  check "org.fcitx.Fcitx5 owned by the unit's MainPID ($main)" [ "$(owner_pid org.fcitx.Fcitx5)" = "$main" ]
  check "IBus address file holds the daemon pid" addr_file_pid_is "$main"
  check "environment.d = packaged file" cmp -s "$s/90-vr-telex.conf" "$XDG_CONFIG_HOME/environment.d/90-vr-telex.conf"
  check "xinputrc = packaged file" cmp -s "$s/xinputrc" "$HOME/.xinputrc"
  check "autostart override = packaged file" cmp -s "$s/org.fcitx.Fcitx5.desktop" "$XDG_CONFIG_HOME/autostart/org.fcitx.Fcitx5.desktop"
  check "D-Bus activation shadow execs the packaged binary (quoted)" \
    grep -qxF "Exec=\"$PKG/usr/bin/vr-telex\"" "$XDG_DATA_HOME/dbus-1/services/org.fcitx.Fcitx5.service"
  check "backup manifest exists" [ -f "$XDG_DATA_HOME/vr-telex/backup/manifest" ]
  check "backup dir is 0700" [ "$(stat -c %a "$XDG_DATA_HOME/vr-telex/backup")" = 700 ]
  check "vr-telex source present exactly once" [ "$(gs sources | grep -o "('ibus', 'vr-telex')" | wc -l)" = 1 ]
  check "vr-telex source selected (first in mru-sources)" [ "$(gs mru-sources | cut -c1-21)" = "[('ibus', 'vr-telex')" ]
  check "never ran cargo" sh -c "! grep -q '^cargo' '$XDG_RUNTIME_DIR/stub-calls.log'"
}

t_setup_fresh() {
  make_pkg
  pre_state_fcitx5
  local fpid sum0 out rc=0 main1 calls1
  fpid=$(owner_pid org.fcitx.Fcitx5)
  snap "$T8_SANDBOX/pre.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/pre.keyfile"
  sum0=$(pkg_sum)
  out=$(run_setup 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "vr-telex-setup exits 0" [ "$rc" = 0 ]
  check "fcitx5 asked to quit, not killed" grep -qx 'fcitx5-remote -e' "$XDG_RUNTIME_DIR/stub-calls.log"
  check "old fcitx5 ($fpid) has exited" sh -c "! kill -0 $fpid 2>/dev/null"
  check "user manager reloaded (it may not know the packaged unit yet)" grep -qx 'systemctl --user daemon-reload' "$XDG_RUNTIME_DIR/stub-calls.log"
  expect_setup_installed
  check "keyfile after setup" diff -u - "$(keyfile)" <<'EOF'
[org/gnome/desktop/input-sources]
sources=[('xkb', 'us'), ('ibus', 'vr-telex')]
mru-sources=[('ibus', 'vr-telex'), ('xkb', 'us')]
EOF
  check "daemon started only after vr-telex was first in mru-sources (D33)" started_with_vr_head 0
  check "recovery path names vr-telex-setup --remove" grep -q "then 'vr-telex-setup --remove'" <<<"$out"
  check "package files untouched" [ "$(pkg_sum)" = "$sum0" ]

  main1=$(systemctl --user show -p MainPID --value vr-telex.service)
  snap "$T8_SANDBOX/inst1.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/inst1.keyfile"
  calls1=$(wc -l <"$XDG_RUNTIME_DIR/stub-calls.log")
  check "second setup exits 0" run_setup
  snap "$T8_SANDBOX/inst2.snap" noibus
  check "second setup changes no file" same_snap "$T8_SANDBOX/inst1.snap" "$T8_SANDBOX/inst2.snap"
  check "second setup leaves the keyfile byte-identical" cmp "$T8_SANDBOX/inst1.keyfile" "$(keyfile)"
  check "second setup restarted the daemon (D33)" [ "$(systemctl --user show -p MainPID --value vr-telex.service)" != "$main1" ]
  check "second setup restarted it with vr-telex first" started_with_vr_head "$calls1"

  rc=0
  out=$(run_setup --remove 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "vr-telex-setup --remove exits 0" [ "$rc" = 0 ]
  snap "$T8_SANDBOX/post.snap" noibus
  check "files restored exactly (snapshot = before setup)" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "keyfile restored byte for byte" cmp "$T8_SANDBOX/pre.keyfile" "$(keyfile)"
  check "unit no longer enabled" sh -c '! systemctl --user is-enabled --quiet vr-telex.service'
  check "fcitx5 started again and owns org.fcitx.Fcitx5" has_owner org.fcitx.Fcitx5
  check "package files untouched" [ "$(pkg_sum)" = "$sum0" ]
  expect_no_vr_telex_left
  rc=0
  out=$(run_setup --remove 2>&1) || rc=$?
  check "second --remove exits 0 and says not installed" sh -c '[ "$1" = 0 ] && printf "%s" "$2" | grep -q "not installed"' _ "$rc" "$out"
}

t_setup_root_refused() {
  make_pkg
  mkdir -p "$T8_SANDBOX/rootstub" "$T8_SANDBOX/evilshare"
  printf '#!/bin/sh\n[ "$1" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' >"$T8_SANDBOX/rootstub/id"
  chmod +x "$T8_SANDBOX/rootstub/id"
  # A shared dir the environment points at must not run as root either.
  printf 'touch "%s/evil-ran"\n' "$T8_SANDBOX" >"$T8_SANDBOX/evilshare/common.sh"
  # Real root cannot be had here (no user namespaces), so a copy of the
  # script reads 0 where it reads bash's own EUID. That the copy differs
  # proves the check reads EUID, which no PATH or environment can change.
  perl -pe 's/\$\{?EUID\}?/0/g' "$PKG/usr/bin/vr-telex-setup" >"$T8_SANDBOX/asroot-setup"
  check "the root check reads bash's EUID" sh -c "! cmp -s '$PKG/usr/bin/vr-telex-setup' '$T8_SANDBOX/asroot-setup'"
  check "the interpreter is /bin/bash, not looked up in PATH" [ "$(head -n 1 "$PKG/usr/bin/vr-telex-setup")" = '#!/bin/bash' ]
  snap "$T8_SANDBOX/pre.snap"
  local out rc=0 arg
  for arg in '' --remove; do
    rc=0
    out=$(PATH="$T8_SANDBOX/rootstub:$PATH" run_setup $arg 2>&1) || rc=$?
    printf '%s\n' "$out"
    check "vr-telex-setup $arg as root (id says 0) exits 1" [ "$rc" = 1 ]
    check "vr-telex-setup $arg as root (id says 0) explains" grep -q 'do not run as root' <<<"$out"
    rc=0
    out=$(VR_TELEX_SHARE="$T8_SANDBOX/evilshare" bash "$T8_SANDBOX/asroot-setup" $arg 2>&1) || rc=$?
    printf '%s\n' "$out"
    check "vr-telex-setup $arg as root (EUID 0) exits 1 and explains" sh -c '[ "$1" = 1 ] && printf "%s" "$2" | grep -q "do not run as root"' _ "$rc" "$out"
    check "vr-telex-setup $arg as root (EUID 0) reads no shared file first" [ ! -e "$T8_SANDBOX/evil-ran" ]
  done
  snap "$T8_SANDBOX/post.snap"
  check "nothing changed" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "no systemctl call" [ ! -s "$XDG_RUNTIME_DIR/stub-calls.log" ]
}

t_setup_usage() {
  make_pkg
  snap "$T8_SANDBOX/pre.snap"
  local out rc=0
  out=$(run_setup --bogus 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "unknown option exits 2" [ "$rc" = 2 ]
  check "unknown option prints the usage" grep -q 'vr-telex-setup --remove' <<<"$out"
  rc=0
  out=$(run_setup --remove extra 2>&1) || rc=$?
  check "extra argument exits 2" [ "$rc" = 2 ]
  rc=0
  out=$(run_setup --help 2>&1) || rc=$?
  check "--help exits 0 with the usage" sh -c '[ "$1" = 0 ] && printf "%s" "$2" | grep -q -- "--remove"' _ "$rc" "$out"
  snap "$T8_SANDBOX/post.snap"
  check "nothing changed" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "no systemctl call" [ ! -s "$XDG_RUNTIME_DIR/stub-calls.log" ]
}

t_setup_no_package() {
  make_pkg
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
  snap "$T8_SANDBOX/pre.snap"
  local out rc=0
  mkdir -p "$T8_SANDBOX/nounits"
  out=$(VR_TELEX_SYSTEM_UNIT_DIR="$T8_SANDBOX/nounits" run_setup 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "without the packaged unit: exits 1" [ "$rc" = 1 ]
  check "without the packaged unit: names it" grep -qF "$T8_SANDBOX/nounits/vr-telex.service" <<<"$out"
  rc=0
  out=$(VR_TELEX_SHARE="$T8_SANDBOX/noshare" VR_TELEX_BIN="$PKG/usr/bin/vr-telex" bash "$PKG/usr/bin/vr-telex-setup" 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "without the shared files: exits 1 and names them" sh -c '[ "$1" = 1 ] && printf "%s" "$2" | grep -qF "$3/common.sh"' _ "$rc" "$out" "$T8_SANDBOX/noshare"
  if [ ! -e /usr/bin/vr-telex ]; then
    # The defaults are the package paths.
    rc=0
    out=$(env -u VR_TELEX_BIN VR_TELEX_SHARE="$PKG/usr/share/vr-telex" bash "$PKG/usr/bin/vr-telex-setup" 2>&1) || rc=$?
    printf '%s\n' "$out"
    check "default binary is /usr/bin/vr-telex" sh -c '[ "$1" = 1 ] && printf "%s" "$2" | grep -qF "/usr/bin/vr-telex "' _ "$rc" "$out"
  else
    echo "skip default-path check: /usr/bin/vr-telex exists on this machine"
  fi
  snap "$T8_SANDBOX/post.snap"
  check "nothing changed" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "no systemctl call that changes anything" sh -c "! grep -Eq 'systemctl --user (enable|disable|start|stop|restart|daemon-reload)' '$XDG_RUNTIME_DIR/stub-calls.log'"
}

t_setup_broken_daemon() {
  make_pkg "$T8_STUBS/broken-vr-telex"
  pre_state_fcitx5
  snap "$T8_SANDBOX/pre.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/pre.keyfile"
  local out rc=0
  out=$(run_setup 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "setup with a dying daemon exits non-zero" [ "$rc" -ne 0 ]
  check "says it rolled back" grep -qi 'rolled back' <<<"$out"
  check "prints the recovery path with vr-telex-setup --remove" grep -q "systemctl --user disable --now vr-telex.service', then 'vr-telex-setup --remove'" <<<"$out"
  check "the failing daemon was started with vr-telex selected" started_with_vr_head 0
  snap "$T8_SANDBOX/post.snap" noibus
  check "rollback restored every file" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "input sources restored exactly" cmp "$T8_SANDBOX/pre.keyfile" "$(keyfile)"
  check "unit not left enabled" sh -c '! systemctl --user is-enabled --quiet vr-telex.service'
  check "fcitx5 runs again after rollback" has_owner org.fcitx.Fcitx5
  expect_no_vr_telex_left
}

t_setup_from_source() {
  # A from-source install switched to the package: its binary and unit go,
  # the packaged unit runs, the first backup is kept, and --remove still
  # returns to the state before the first install.
  make_pkg
  pre_state_fcitx5
  snap "$T8_SANDBOX/pre.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/pre.keyfile"
  check "install.sh exits 0" run_install
  cp "$XDG_DATA_HOME/vr-telex/backup/manifest" "$T8_SANDBOX/manifest.src"
  local out rc=0
  out=$(run_setup 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "vr-telex-setup over a from-source install exits 0" [ "$rc" = 0 ]
  expect_setup_installed
  check "the first backup is kept" cmp -s "$T8_SANDBOX/manifest.src" "$XDG_DATA_HOME/vr-telex/backup/manifest"
  check "no copy of the from-source files kept aside" sh -c "! find '$HOME' -name '*vr-telex-saved-*' | grep -q ."
  check "user manager reloaded after the user unit went" grep -qx 'systemctl --user daemon-reload' "$XDG_RUNTIME_DIR/stub-calls.log"
  check "--remove exits 0" run_setup --remove
  snap "$T8_SANDBOX/post.snap" noibus
  check "files back to the state before the first install" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "keyfile back to the state before the first install" cmp "$T8_SANDBOX/pre.keyfile" "$(keyfile)"
  check "fcitx5 runs again" has_owner org.fcitx.Fcitx5
  expect_no_vr_telex_left
}

t_install_after_setup() {
  # The other way: install.sh over the packaged setup takes over with its
  # own binary and unit; uninstall.sh returns to the state before both.
  make_pkg
  pre_state_fcitx5
  snap "$T8_SANDBOX/pre.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/pre.keyfile"
  check "vr-telex-setup exits 0" run_setup
  check "install.sh over the setup exits 0" run_install
  expect_installed
  local main
  main=$(systemctl --user show -p MainPID --value vr-telex.service)
  check "the daemon is now ~/.local/bin/vr-telex" sh -c "tr '\0' '\n' </proc/$main/cmdline | grep -qxF \"\$1\"" _ "$HOME/.local/bin/vr-telex"
  check "uninstall.sh exits 0" run_uninstall
  snap "$T8_SANDBOX/post.snap" noibus
  check "files back to the state before both" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "keyfile back to the state before both" cmp "$T8_SANDBOX/pre.keyfile" "$(keyfile)"
  expect_no_vr_telex_left
}

# A unit of the user's that the packaged one must not run behind.
plant_user_unit() {
  mkdir -p "$XDG_CONFIG_HOME/systemd/user"
  printf '[Service]\nExecStart=/bin/true\n' >"$XDG_CONFIG_HOME/systemd/user/vr-telex.service"
}

# The setup with a user unit in place stops before any change, naming it.
expect_override_refused() {
  local out rc=0
  snap "$T8_SANDBOX/mid.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/mid.keyfile"
  out=$(run_setup 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "$1: setup exits 1" [ "$rc" = 1 ]
  check "$1: names the overriding unit" grep -qF "$XDG_CONFIG_HOME/systemd/user/vr-telex.service would replace the packaged unit" <<<"$out"
  snap "$T8_SANDBOX/post.snap" noibus
  check "$1: nothing changed" same_snap "$T8_SANDBOX/mid.snap" "$T8_SANDBOX/post.snap"
  check "$1: keyfile unchanged" cmp "$T8_SANDBOX/mid.keyfile" "$(keyfile)"
  check "$1: no systemctl call that changes anything" sh -c "! grep -Eq 'systemctl --user (enable|disable|start|stop|restart)' '$XDG_RUNTIME_DIR/stub-calls.log'"
}

t_setup_unit_override() {
  # A unit file of the user's in ~/.config/systemd/user would replace the
  # packaged one: refused before anything changes, with or without a
  # vr-telex backup (without one, the "installed without a backup" advice
  # would send the user round in a loop).
  make_pkg
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
  plant_user_unit
  expect_override_refused "no backup"
  rm -f -- "$XDG_CONFIG_HOME/systemd/user/vr-telex.service"
  check "vr-telex-setup exits 0" run_setup
  plant_user_unit
  : >"$XDG_RUNTIME_DIR/stub-calls.log"
  expect_override_refused "with a backup"
  # A from-source unit whose backup is gone still gets the uninstall advice.
  rm -f -- "$XDG_CONFIG_HOME/systemd/user/vr-telex.service"
  check "--remove exits 0" run_setup --remove
  check "install.sh exits 0" run_install
  rm -rf -- "${XDG_DATA_HOME:?}/vr-telex/backup"
  local out rc=0
  out=$(run_setup 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "from-source unit without a backup: exits 1 with the uninstall advice" \
    sh -c '[ "$1" = 1 ] && printf "%s" "$2" | grep -q "installed without a backup; run vr-telex-setup --remove first"' _ "$rc" "$out"
}

t_setup_from_source_edited() {
  # A from-source unit and binary the user changed after install.sh are moved
  # aside, not deleted, when the package takes over.
  make_pkg
  pre_state_fcitx5
  snap "$T8_SANDBOX/pre.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/pre.keyfile"
  check "install.sh exits 0" run_install
  printf '# my unit edit\n' >>"$XDG_CONFIG_HOME/systemd/user/vr-telex.service"
  printf '# my binary edit\n' >>"$HOME/.local/bin/vr-telex"
  local out rc=0 su sb main u="$XDG_CONFIG_HOME/systemd/user"
  out=$(run_setup 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "vr-telex-setup exits 0" [ "$rc" = 0 ]
  su=$(saved_copy "$u/vr-telex.service")
  sb=$(saved_copy "$HOME/.local/bin/vr-telex")
  check "edited unit kept aside with the edit" sh -c '[ -n "$1" ] && grep -qx "# my unit edit" "$1"' _ "$su"
  check "edited binary kept aside with the edit" sh -c '[ -n "$1" ] && grep -qx "# my binary edit" "$1"' _ "$sb"
  check "warning names the kept unit" grep -qF "${su:-none}" <<<"$out"
  check "no unit file of its own in ~/.config/systemd/user" [ ! -e "$u/vr-telex.service" ]
  check "no ~/.local/bin/vr-telex" [ ! -e "$HOME/.local/bin/vr-telex" ]
  check "enabled through the packaged unit" \
    [ "$(readlink "$u/graphical-session.target.wants/vr-telex.service")" = "$VR_TELEX_SYSTEM_UNIT_DIR/vr-telex.service" ]
  main=$(systemctl --user show -p MainPID --value vr-telex.service)
  check "the daemon is the packaged binary" sh -c "tr '\0' '\n' </proc/$main/cmdline | grep -qxF \"\$1\"" _ "$PKG/usr/bin/vr-telex"
  check "--remove exits 0" run_setup --remove
  # The kept copies stay, and so do the dirs that hold them.
  local keep='vr-telex-saved-|^d [0-7]+ \./\.local -> $|^d [0-7]+ \./\.local/bin -> $|^d [0-7]+ \./\.config/systemd(/user)? -> $'
  snap "$T8_SANDBOX/post.snap" noibus
  grep -Ev "$keep" "$T8_SANDBOX/pre.snap" >"$T8_SANDBOX/pre.cmp" || true
  grep -Ev "$keep" "$T8_SANDBOX/post.snap" >"$T8_SANDBOX/post.cmp" || true
  check "everything else back to the state before install.sh" same_snap "$T8_SANDBOX/pre.cmp" "$T8_SANDBOX/post.cmp"
  check "keyfile back to the state before install.sh" cmp "$T8_SANDBOX/pre.keyfile" "$(keyfile)"
  check "both kept copies still there" sh -c '[ -f "$1" ] && [ -f "$2" ]' _ "$su" "$sb"
}

t_setup_legacy_then_override() {
  # After a vr-talex move through the setup, the backup holds no record of
  # files the package never writes, so a later unit of the user's is
  # refused, not moved aside.
  make_pkg
  check "vr-talex installer exits 0" legacy_install
  check "vr-telex-setup over vr-talex exits 0" run_setup
  plant_user_unit
  : >"$XDG_RUNTIME_DIR/stub-calls.log"
  expect_override_refused "after the move"
  check "the user's unit is where it was" grep -qx 'ExecStart=/bin/true' "$XDG_CONFIG_HOME/systemd/user/vr-telex.service"
}

t_setup_remove_without_backup() {
  make_pkg
  check "vr-telex-setup exits 0" run_setup
  rm -rf -- "${XDG_DATA_HOME:?}/vr-telex/backup"
  local out rc=0
  out=$(run_setup --remove 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "--remove without backup exits 0" [ "$rc" = 0 ]
  check "warns that no backup exists" grep -q 'no backup found' <<<"$out"
  check "unit disabled" sh -c '! systemctl --user is-enabled --quiet vr-telex.service'
  check "vr-telex unit inactive" sh -c '! systemctl --user is-active --quiet vr-telex.service'
  check "environment.d file removed" [ ! -e "$XDG_CONFIG_HOME/environment.d/90-vr-telex.conf" ]
  check "autostart override removed" [ ! -e "$XDG_CONFIG_HOME/autostart/org.fcitx.Fcitx5.desktop" ]
  check "D-Bus shadow removed" [ ! -e "$XDG_DATA_HOME/dbus-1/services/org.fcitx.Fcitx5.service" ]
  check "our xinputrc removed" [ ! -e "$HOME/.xinputrc" ]
}

t_setup_legacy_migrate() {
  # AC-2 through the packaged setup: vr-talex (current) is moved to the
  # packaged vr-telex, and --remove returns to the state before vr-talex.
  make_pkg
  pre_state_fcitx5
  snap "$T8_SANDBOX/pre.snap" noibus
  cp "$(keyfile)" "$T8_SANDBOX/pre.keyfile"
  check "vr-talex installer exits 0" legacy_install
  mkdir -p "$XDG_STATE_HOME/vr-talex"
  printf 'EN\n' >"$XDG_STATE_HOME/vr-talex/mode"
  local out rc=0 calls0 calls1
  calls0=$(wc -l <"$XDG_RUNTIME_DIR/stub-calls.log")
  out=$(run_setup 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "vr-telex-setup over vr-talex exits 0" [ "$rc" = 0 ]
  check "says it moved the vr-talex install" grep -q 'moved the vr-talex install to vr-telex' <<<"$out"
  legacy_files_gone
  check "90-vr-talex.conf removed" [ ! -e "$XDG_CONFIG_HOME/environment.d/90-vr-talex.conf" ]
  check "~/.local/share/vr-talex removed" [ ! -e "$XDG_DATA_HOME/vr-talex" ]
  check "sources: vr-talex renamed in place" [ "$(gs sources)" = "[('xkb', 'us'), ('ibus', 'vr-telex')]" ]
  expect_setup_installed
  check "VI/EN mode carried over" [ "$(cat "$XDG_STATE_HOME/vr-telex/mode" 2>/dev/null)" = EN ]
  no_migration_leftovers
  check "daemon started only with vr-telex first in mru-sources" started_with_vr_head "$calls0"
  snap "$T8_SANDBOX/inst1.snap" noibus
  calls1=$(wc -l <"$XDG_RUNTIME_DIR/stub-calls.log")
  rc=0
  out=$(run_setup 2>&1) || rc=$?
  check "second setup exits 0 and finds nothing of vr-talex" sh -c '[ "$1" = 0 ] && ! printf "%s" "$2" | grep -q vr-talex' _ "$rc" "$out"
  snap "$T8_SANDBOX/inst2.snap" noibus
  check "second setup changes no file" same_snap "$T8_SANDBOX/inst1.snap" "$T8_SANDBOX/inst2.snap"
  check "second setup did not touch vr-talex" sh -c "tail -n +$((calls1 + 1)) '$XDG_RUNTIME_DIR/stub-calls.log' | grep -Eq '^systemctl --user (disable|enable|stop|start|restart) .*vr-talex' && exit 1 || exit 0"
  check "--remove exits 0" run_setup --remove
  snap "$T8_SANDBOX/post.snap" noibus
  check "files back to the state before vr-talex" same_snap "$T8_SANDBOX/pre.snap" "$T8_SANDBOX/post.snap"
  check "keyfile back to the state before vr-talex" cmp "$T8_SANDBOX/pre.keyfile" "$(keyfile)"
  check "fcitx5 started again" has_owner org.fcitx.Fcitx5
  expect_no_vr_telex_left
}

t_setup_legacy_keep_selection() {
  # AC-2: the packaged setup keeps the current source current, like
  # install.sh (legacy_was_current + MIG_KEEP_SELECTION).
  make_pkg
  pre_state_fcitx5
  check "vr-talex installer exits 0" legacy_install
  gsettings set org.gnome.desktop.input-sources sources "[('ibus', 'vr-talex'), ('xkb', 'us'), ('xkb', 'fr')]"
  gsettings set org.gnome.desktop.input-sources mru-sources "[('xkb', 'us'), ('ibus', 'vr-talex'), ('xkb', 'fr')]"
  local out rc=0
  out=$(run_setup 2>&1) || rc=$?
  printf '%s\n' "$out"
  check "vr-telex-setup exits 0" [ "$rc" = 0 ]
  check "sources: renamed at index 0, others in order" \
    [ "$(gs sources)" = "[('ibus', 'vr-telex'), ('xkb', 'us'), ('xkb', 'fr')]" ]
  check "mru-sources: English still current, vr-telex at its old place" \
    [ "$(gs mru-sources)" = "[('xkb', 'us'), ('ibus', 'vr-telex'), ('xkb', 'fr')]" ]
  check "does not claim to have put vr-telex first" sh -c '! printf "%s" "$1" | grep -q "first"' _ "$out"
  legacy_files_gone
  no_migration_leftovers
  check "vr-telex unit active" systemctl --user is-active --quiet vr-telex.service
  check "--remove exits 0" run_setup --remove
  check "sources after --remove" [ "$(gs sources)" = "[('xkb', 'us'), ('xkb', 'fr')]" ]
  check "mru-sources after --remove" [ "$(gs mru-sources)" = "[('xkb', 'us'), ('xkb', 'fr')]" ]
  expect_no_vr_telex_left
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
