#!/usr/bin/env bash
# Install vr-talex for the current user (spec B7, decisions D1, D11, D20).
#
# User-level only: builds from this checkout, writes under $HOME, uses
# systemctl --user and gsettings. Safe to run again: a second run changes
# nothing. If the daemon does not come up healthy, every change is rolled
# back and the input sources are left untouched (SEC-19).
#
# Test seams: VR_TALEX_BIN (use this binary instead of building),
# VR_TALEX_TIMEOUT (seconds to wait for fcitx5 / the daemon),
# VR_TALEX_OS_RELEASE (os-release file to check).
set -euo pipefail
umask 022

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=packaging/common.sh
. "$REPO/packaging/common.sh"

ROLLBACK=0
RERUN=0

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$ROLLBACK" = 1 ]; then
    ROLLBACK=0
    set +e
    warn "install failed; rolling back"
    if restore_all; then
      say "rolled back: the previous input method setup is restored"
    else
      warn "rollback is incomplete (see the lines above)"
    fi
    if [ "$RERUN" = 1 ]; then
      say "the earlier install was removed too; fix the cause, then run ./install.sh again"
    fi
    print_recovery
  fi
  exit "$rc"
}

check_platform() {
  local os_release=${VR_TALEX_OS_RELEASE:-/etc/os-release} id='' ver=''
  if [ -r "$os_release" ]; then
    # Read the two keys only; the file is never sourced.
    id=$(sed -n 's/^ID=//p' "$os_release" | tr -d '"')
    ver=$(sed -n 's/^VERSION_ID=//p' "$os_release" | tr -d '"')
  fi
  if [ "$id" != ubuntu ] || [ "${ver%%.*}" -lt 24 ] 2>/dev/null || [ -z "$ver" ]; then
    warn "made for Ubuntu 24.04 or newer (found: ${id:-unknown} ${ver:-unknown}); continuing"
  fi
  case ":${XDG_CURRENT_DESKTOP:-}:" in
    *:GNOME:*) ;;
    *) warn "made for GNOME (XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset}); continuing" ;;
  esac
}

preflight() {
  need_commands gdbus gsettings systemctl timeout tail cmp stat mktemp
  check_platform
  gsettings list-keys "$SCHEMA" >/dev/null 2>&1 || die "GNOME input source settings ($SCHEMA) not found"
  bus_call GetId >/dev/null 2>&1 || die "no session D-Bus; run this from your desktop session"
  # Only the fcitx5 hand-over is supported and tested; a running ibus-daemon
  # would keep rewriting the IBus address file (spike open item O2).
  if has_owner org.freedesktop.portal.IBus || systemctl --user is-active --quiet "$IBUS_GNOME_UNIT" 2>/dev/null; then
    die "ibus-daemon is running; this installer only takes over from fcitx5. Nothing was changed."
  fi
}

build_binary() {
  if [ -n "${VR_TALEX_BIN:-}" ]; then
    [ -f "$VR_TALEX_BIN" ] && [ -x "$VR_TALEX_BIN" ] || die "VR_TALEX_BIN ($VR_TALEX_BIN) is not an executable file"
    SRC_BIN=$VR_TALEX_BIN
    say "using prebuilt binary $SRC_BIN"
    return 0
  fi
  # Local toolchain and Cargo.lock only; nothing is downloaded and run (SEC-24).
  command -v cargo >/dev/null 2>&1 || die "cargo not found; install the Rust toolchain, then run ./install.sh again"
  say "building (cargo build --release --locked)"
  (cd "$REPO" && cargo build --release --locked -p vr-talex) || die "build failed"
  SRC_BIN=${CARGO_TARGET_DIR:-$REPO/target}/release/vr-talex
  [ -x "$SRC_BIN" ] || die "build produced no $SRC_BIN"
}

# First install only: save everything that will change (SEC-21). A later run
# keeps the first backup, so uninstall always returns to the original state.
backup_state() {
  local m d f r pid mode=none enabled=no
  local -a ibus_files=()
  if [ -L "$STATE_DIR" ] || [ -L "$BACKUP_DIR" ]; then die "refusing a symlinked backup dir ($BACKUP_DIR)"; fi

  m=$'v\t1\n'
  for d in "${MANAGED_DIRS[@]}"; do
    [ -d "$d" ] || m+="dir"$'\t'"$(rel "$d")"$'\n'
  done

  # A partial backup from an interrupted first run holds the same old state.
  if [ -d "$BACKUP_DIR" ]; then rm -rf -- "${DATA_HOME:?}/vr-talex/backup"; fi
  mkdir -p -- "$STATE_DIR"
  mkdir -m 0700 -- "$BACKUP_DIR" "$BACKUP_DIR/files"

  if [ -d "$IBUS_BUS_DIR" ]; then
    for f in "$IBUS_BUS_DIR"/*; do
      if [ -e "$f" ] || [ -L "$f" ]; then ibus_files+=("$f"); fi
    done
  fi
  for f in "${MANAGED_FILES[@]}" "${ibus_files[@]}"; do
    r=$(rel "$f")
    if [ -e "$f" ] || [ -L "$f" ]; then
      if [ -d "$f" ] && [ ! -L "$f" ]; then die "$f is a directory; move it away and run again"; fi
      mkdir -p -- "$BACKUP_DIR/files/$(dirname -- "$r")"
      cp -a -- "$f" "$BACKUP_DIR/files/$r"
      m+="file"$'\t'"$r"$'\t'"present"$'\n'
    else
      m+="file"$'\t'"$r"$'\t'"absent"$'\n'
    fi
  done

  m+="gs"$'\t'"sources"$'\t'"$(gs_get sources)"$'\n'
  m+="gs"$'\t'"mru-sources"$'\t'"$(gs_get mru-sources)"$'\n'

  if pid=$(owner_pid "$FCITX_NAME") && [ "$pid" != "$(unit_pid)" ]; then
    mode=remote
    if systemctl --user is-active --quiet "$FCITX_UNIT" 2>/dev/null; then
      mode=unit
      if systemctl --user is-enabled --quiet "$FCITX_UNIT" 2>/dev/null; then enabled=yes; fi
    fi
  fi
  m+="fcitx5"$'\t'"$mode"$'\t'"$enabled"$'\n'

  printf '%s' "$m" >"$BACKUP_DIR/manifest.tmp"
  mv -f -- "$BACKUP_DIR/manifest.tmp" "$MANIFEST"
  say "saved the current setup to $BACKUP_DIR"
}

# Write src to dst atomically with mode; returns 0 when dst changed and 1
# when it already matched.
put_file() {
  local src=$1 dst=$2 mode=$3 dir tmp
  if [ -f "$dst" ] && [ ! -L "$dst" ] && cmp -s -- "$src" "$dst" && [ "$(stat -c %a -- "$dst")" = "${mode#0}" ]; then
    return 1
  fi
  dir=$(dirname -- "$dst")
  mkdir -p -- "$dir" || die "cannot create $dir"
  tmp=$(mktemp "$dir/.vr-talex-tmp.XXXXXX") || die "cannot write in $dir"
  if ! cat -- "$src" >"$tmp" || ! chmod "$mode" "$tmp" || ! mv -f -- "$tmp" "$dst"; then
    rm -f -- "$tmp"
    die "cannot write $dst"
  fi
  return 0
}

# Write one managed file. On a re-run, a version the user wrote since the
# last install is moved aside first instead of being overwritten.
install_managed() {
  local src=$1 dst=$2 mode=$3 inst rc=1
  inst=$BACKUP_DIR/installed/$(rel "$dst")
  if exists "$inst" && exists "$dst" && ! same_entry "$dst" "$inst" && ! cmp -s -- "$src" "$dst"; then
    keep_user_copy "$dst" || die "cannot move $dst aside"
  fi
  if put_file "$src" "$dst" "$mode"; then rc=0; fi
  if ! exists "$inst" || ! same_entry "$dst" "$inst"; then
    record_installed "$dst" || die "cannot record $dst in $BACKUP_DIR"
  fi
  return "$rc"
}

install_files() {
  CHANGED_BIN=0 CHANGED_UNIT=0
  if install_managed "$SRC_BIN" "$BIN_DST" 0755; then CHANGED_BIN=1; fi
  if install_managed "$REPO/packaging/vr-talex.service" "$UNIT_DST" 0644; then CHANGED_UNIT=1; fi
  install_managed "$REPO/packaging/90-vr-talex.conf" "$ENV_DST" 0644 || true
  install_managed "$REPO/packaging/xinputrc" "$XINPUTRC" 0644 || true
  install_managed "$REPO/packaging/org.fcitx.Fcitx5.desktop" "$AUTOSTART_DST" 0644 || true

  # Shadow fcitx5's D-Bus activation file: a client asking for
  # org.fcitx.Fcitx5 starts vr-talex, never fcitx5 (spike Q6 point 5).
  render_dbus_svc >"$BACKUP_DIR/.svc" || die "cannot render the D-Bus service file"
  if install_managed "$BACKUP_DIR/.svc" "$DBUS_SVC_DST" 0644; then
    rm -f -- "$BACKUP_DIR/.svc"
    reload_bus
  else
    rm -f -- "$BACKUP_DIR/.svc"
  fi

  if [ "$CHANGED_UNIT" = 1 ]; then
    systemctl --user daemon-reload || die "systemctl --user daemon-reload failed"
  fi
}

# Ask fcitx5 to quit cleanly and wait until it has gone (spike Q6 point 4).
hand_over_fcitx5() {
  local pid
  pid=$(owner_pid "$FCITX_NAME") || return 0
  [ "$pid" = "$(unit_pid)" ] && return 0
  say "asking fcitx5 to quit"
  if systemctl --user is-active --quiet "$FCITX_UNIT" 2>/dev/null; then
    systemctl --user stop "$FCITX_UNIT" || die "could not stop $FCITX_UNIT"
    if systemctl --user is-enabled --quiet "$FCITX_UNIT" 2>/dev/null; then
      systemctl --user disable "$FCITX_UNIT" || die "could not disable $FCITX_UNIT"
    fi
  else
    command -v fcitx5-remote >/dev/null 2>&1 || die "fcitx5 (pid $pid) is running but fcitx5-remote is missing; quit fcitx5, then run ./install.sh again"
    fcitx5-remote -e || die "fcitx5-remote -e failed"
  fi
  wait_pid_exit "$pid" || die "fcitx5 (pid $pid) did not quit within ${TIMEOUT}s"
  if has_owner "$FCITX_NAME"; then die "$FCITX_NAME is still owned by another process"; fi
}

start_daemon() {
  if systemctl --user is-active --quiet "$UNIT"; then
    if [ "$CHANGED_BIN$CHANGED_UNIT" != 00 ]; then
      say "restarting vr-talex"
      systemctl --user restart "$UNIT" || die "vr-talex did not restart (journalctl --user -u $UNIT)"
    fi
    if ! systemctl --user is-enabled --quiet "$UNIT"; then
      systemctl --user enable "$UNIT" || die "could not enable $UNIT"
    fi
  else
    say "starting vr-talex"
    systemctl --user enable --now "$UNIT" || die "vr-talex did not start (journalctl --user -u $UNIT)"
  fi
}

# Healthy = the unit's main process owns org.fcitx.Fcitx5 and has published
# its IBus address file. Only then are the input sources touched (SEC-19).
health_check() {
  local main mid f
  gdbus wait --session --timeout "$TIMEOUT" "$FCITX_NAME" >/dev/null 2>&1 ||
    die "vr-talex did not take $FCITX_NAME within ${TIMEOUT}s"
  main=$(unit_pid)
  if [ "$main" = 0 ] || ! kill -0 "$main" 2>/dev/null; then die "vr-talex is not running"; fi
  [ "$(owner_pid "$FCITX_NAME" || true)" = "$main" ] || die "$FCITX_NAME is owned by another process"
  mid=$(machine_id) || die "cannot read the machine id from the session bus"
  for f in "$IBUS_BUS_DIR/$mid"-unix-*; do
    if [ -f "$f" ] && [ ! -L "$f" ] && grep -qx "IBUS_DAEMON_PID=$main" "$f"; then
      return 0
    fi
  done
  die "vr-talex did not publish its IBus address in $IBUS_BUS_DIR"
}

# Add the Vietnamese source once and select it. An existing entry is left
# alone, so a second run (or a user who switched back) changes nothing.
select_source() {
  local cur items mru sources
  cur=$(gs_get sources)
  case "$cur" in
    *"$VR_SOURCE"*)
      say "input source already present"
      return 0
      ;;
    "[("*")]" | "@a(ss) []") ;;
    *) die "unexpected input sources value: $cur" ;;
  esac
  items=$(list_items "$cur")
  # mru-sources first: gnome-shell activates the head of the MRU list when
  # the sources change.
  if [ -n "$items" ]; then
    mru="[$VR_SOURCE, $items]"
    sources="[$items, $VR_SOURCE]"
  else
    mru="[$VR_SOURCE]"
    sources="[$VR_SOURCE]"
  fi
  # Recorded first: uninstall compares against it to keep later user edits.
  printf 'mru-sources\t%s\nsources\t%s\n' "$mru" "$sources" >"$BACKUP_DIR/installed.gs"
  gsettings set "$SCHEMA" mru-sources "$mru"
  gsettings set "$SCHEMA" sources "$sources"
  say "added and selected the Vietnamese (Telex) input source"
}

# Files of an install whose backup is gone: taking them as the "original"
# state would make uninstall restore vr-talex's own files.
installed_without_backup() {
  exists "$BIN_DST" || exists "$UNIT_DST" || exists "$ENV_DST" || exists "$DBUS_SVC_DST" ||
    cmp -s -- "$REPO/packaging/xinputrc" "$XINPUTRC" ||
    cmp -s -- "$REPO/packaging/org.fcitx.Fcitx5.desktop" "$AUTOSTART_DST"
}

main() {
  require_user
  init_paths
  preflight
  build_binary
  if [ -f "$MANIFEST" ]; then
    RERUN=1
  else
    if installed_without_backup; then
      die "vr-talex is installed without a backup; run ./uninstall.sh first, then ./install.sh"
    fi
    backup_state
  fi
  ROLLBACK=1
  install_files
  hand_over_fcitx5
  start_daemon
  health_check
  select_source
  ROLLBACK=0
  say "installed; Ctrl+Shift switches between Vietnamese and English"
  print_recovery
}

trap on_exit EXIT
main "$@"
