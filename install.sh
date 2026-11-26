#!/usr/bin/env bash
# Install vr-telex for the current user (spec B7, decisions D1, D11, D20).
#
# User-level only: builds from this checkout, writes under $HOME, uses
# systemctl --user and gsettings. Safe to run again: a second run changes no
# file; it only restarts the daemon so the running shell selects Vietnamese
# (Telex) again (D33). If the daemon does not come up healthy, every change
# is rolled back, input sources included (SEC-19).
#
# An install under the old name vr-talex (D37) is moved to vr-telex: its
# backup becomes the vr-telex backup (so uninstall still restores the setup
# from before vr-talex), its input source is renamed in place, and its own
# files go once the new daemon is healthy. If it is not, the vr-talex
# install is put back and started again (restore_legacy).
#
# Test seams: VR_TELEX_BIN (use this binary instead of building),
# VR_TELEX_TIMEOUT (seconds to wait for fcitx5 / the daemon),
# VR_TELEX_OS_RELEASE (os-release file to check).
set -euo pipefail
umask 022

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=packaging/common.sh
. "$REPO/packaging/common.sh"

ROLLBACK=0
RERUN=0
# Set while a vr-talex install is being moved to vr-telex (D37). A failure
# then returns to that vr-talex install from the snapshot in MIG_SNAP, so the
# user keeps a working Vietnamese input method (see restore_legacy).
MIGRATING=0
MIG_SNAP=''
# Set when restore_legacy failed: the snapshot is then the only full copy of
# the vr-talex install and is kept.
KEEP_SNAP=0

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$ROLLBACK" = 1 ] && [ "$MIGRATING" = 1 ]; then
    ROLLBACK=0
    set +e
    warn "install failed; returning to the vr-talex install"
    if restore_legacy; then
      say "rolled back: vr-talex runs again as before; fix the cause, then run ./install.sh again"
    else
      KEEP_SNAP=1
      warn "rollback is incomplete (see the lines above); the saved vr-talex files and settings are kept in $MIG_SNAP"
    fi
    say "if typing stops working: run 'systemctl --user disable --now $LEGACY_UNIT', then '$REPO/uninstall.sh'"
  elif [ "$rc" -ne 0 ] && [ "$ROLLBACK" = 1 ]; then
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
  if [ "$KEEP_SNAP" = 0 ] && [ -n "$MIG_SNAP" ] && [ -d "$MIG_SNAP" ]; then rm -rf -- "${MIG_SNAP:?}"; fi
  exit "$rc"
}

check_platform() {
  local os_release=${VR_TELEX_OS_RELEASE:-/etc/os-release} id='' ver=''
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
  if ibus_daemon_running; then
    die "ibus-daemon is running; this installer only takes over from fcitx5. Nothing was changed."
  fi
}

# fcitx5's own IBus frontend also owns org.freedesktop.portal.IBus, and it
# quits with the rest of fcitx5 at the hand-over. So the portal name means
# ibus-daemon only when its owner is not the process that owns
# org.fcitx.Fcitx5.
ibus_daemon_running() {
  local portal fcitx
  systemctl --user is-active --quiet "$IBUS_GNOME_UNIT" 2>/dev/null && return 0
  portal=$(owner_pid org.freedesktop.portal.IBus) || return 1
  fcitx=$(owner_pid "$FCITX_NAME") || return 0
  [ "$portal" != "$fcitx" ]
}

build_binary() {
  if [ -n "${VR_TELEX_BIN:-}" ]; then
    [ -f "$VR_TELEX_BIN" ] && [ -x "$VR_TELEX_BIN" ] || die "VR_TELEX_BIN ($VR_TELEX_BIN) is not an executable file"
    SRC_BIN=$VR_TELEX_BIN
    say "using prebuilt binary $SRC_BIN"
    return 0
  fi
  # Local toolchain and Cargo.lock only; nothing is downloaded and run (SEC-24).
  command -v cargo >/dev/null 2>&1 || die "cargo not found; install the Rust toolchain, then run ./install.sh again"
  say "building (cargo build --release --locked)"
  (cd "$REPO" && cargo build --release --locked -p vr-telex) || die "build failed"
  SRC_BIN=${CARGO_TARGET_DIR:-$REPO/target}/release/vr-telex
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
  if [ -d "$BACKUP_DIR" ]; then rm -rf -- "${DATA_HOME:?}/vr-telex/backup"; fi
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
  tmp=$(mktemp "$dir/.vr-telex-tmp.XXXXXX") || die "cannot write in $dir"
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
  # Record first, then write (see record_installed).
  if ! { [ -f "$inst" ] && [ ! -L "$inst" ] && cmp -s -- "$src" "$inst" &&
    [ "$(stat -c %a -- "$inst")" = "${mode#0}" ]; }; then
    record_installed "$src" "$mode" "$dst" || die "cannot record $dst in $BACKUP_DIR"
  fi
  if put_file "$src" "$dst" "$mode"; then rc=0; fi
  return "$rc"
}

install_files() {
  CHANGED_UNIT=0
  # A running daemon is restarted on every run (start_daemon), so a new
  # binary needs no flag of its own.
  install_managed "$SRC_BIN" "$BIN_DST" 0755 || true
  if install_managed "$REPO/packaging/vr-telex.service" "$UNIT_DST" 0644; then CHANGED_UNIT=1; fi
  install_managed "$REPO/packaging/90-vr-telex.conf" "$ENV_DST" 0644 || true
  install_managed "$REPO/packaging/xinputrc" "$XINPUTRC" 0644 || true
  install_managed "$REPO/packaging/org.fcitx.Fcitx5.desktop" "$AUTOSTART_DST" 0644 || true

  # Shadow fcitx5's D-Bus activation file: a client asking for
  # org.fcitx.Fcitx5 starts vr-telex, never fcitx5 (spike Q6 point 5).
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

# A running gnome-shell keeps its MRU list of input sources in memory and
# reads mru-sources again only when its IBus connection becomes ready
# (keyboard.js _ibusReadyCallback, GNOME 46). So the daemon is (re)started
# after select_source: the shell then connects, reads vr-telex at the head
# of mru-sources and selects it. A running daemon is restarted even when
# nothing changed, because whether the shell has another source current
# cannot be read without Eval (D33).
start_daemon() {
  if systemctl --user is-active --quiet "$UNIT"; then
    say "restarting vr-telex"
    systemctl --user restart "$UNIT" || die "vr-telex did not restart (journalctl --user -u $UNIT)"
    if ! systemctl --user is-enabled --quiet "$UNIT"; then
      systemctl --user enable "$UNIT" || die "could not enable $UNIT"
    fi
  else
    say "starting vr-telex"
    systemctl --user enable --now "$UNIT" || die "vr-telex did not start (journalctl --user -u $UNIT)"
  fi
}

# Healthy = the unit's main process owns org.fcitx.Fcitx5 and has published
# its IBus address file. Not healthy -> die, and the rollback restores the
# input sources select_source wrote (SEC-19).
health_check() {
  local main mid f
  gdbus wait --session --timeout "$TIMEOUT" "$FCITX_NAME" >/dev/null 2>&1 ||
    die "vr-telex did not take $FCITX_NAME within ${TIMEOUT}s"
  main=$(unit_pid)
  if [ "$main" = 0 ] || ! kill -0 "$main" 2>/dev/null; then die "vr-telex is not running"; fi
  [ "$(owner_pid "$FCITX_NAME" || true)" = "$main" ] || die "$FCITX_NAME is owned by another process"
  mid=$(machine_id) || die "cannot read the machine id from the session bus"
  for f in "$IBUS_BUS_DIR/$mid"-unix-*; do
    if [ -f "$f" ] && [ ! -L "$f" ] && grep -qx "IBUS_DAEMON_PID=$main" "$f"; then
      return 0
    fi
  done
  die "vr-telex did not publish its IBus address in $IBUS_BUS_DIR"
}

# Add the Vietnamese source once and put it at the head of mru-sources,
# before the daemon starts (see start_daemon). SEC-19 still holds: the
# shell lists an IBus source only once a ready IBus bus lists its engine
# (keyboard.js _inputSourcesChanged), so vr-telex cannot become current
# while the daemon is not answering, and a failed health check rolls both
# keys back exactly. An existing entry stays where it is; only mru-sources
# is changed, when another source is at its head (D33).
select_source() {
  local cur items mru sources
  cur=$(gs_get sources)
  case "$cur" in
    *"$VR_SOURCE"*)
      reselect_source
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
  say "added the Vietnamese (Telex) input source and put it first"
}

# The source is already there: move it to the head of mru-sources when
# another source is first. installed.gs is never rewritten here: when only
# vr-telex's place changed, the new value equals what the first install
# recorded, so uninstall restores the saved value; when the user changed
# the list since, it differs, and uninstall keeps the user's list minus
# vr-telex (gs_restore).
reselect_source() {
  local cur rest mru
  cur=$(gs_get mru-sources)
  case "$cur" in
    "[$VR_SOURCE"*)
      say "input source already present and first"
      return 0
      ;;
    "[("*")]" | "@a(ss) []") ;;
    *) die "unexpected mru-sources value: $cur" ;;
  esac
  rest=$(list_items "$(without_vr "$cur")")
  if [ -n "$rest" ]; then mru="[$VR_SOURCE, $rest]"; else mru="[$VR_SOURCE]"; fi
  gsettings set "$SCHEMA" mru-sources "$mru"
  say "put the Vietnamese (Telex) input source first again"
}

# The user's own input-source switch shortcut (D33: often Ctrl+Space, not
# the Super+Space default), or a neutral name when it cannot be read.
switch_shortcut() {
  local v first
  v=$(gsettings get org.gnome.desktop.wm.keybindings switch-input-source 2>/dev/null) || v=''
  first=${v#"['"}
  first=${first%%"'"*}
  case "$v" in
    "['"?*) printf 'the shortcut %s' "$(printf '%s' "$first" | tr -cd '[:print:]')" ;;
    *) printf 'the input-source switch shortcut' ;;
  esac
}

# Files of an install whose backup is gone: taking them as the "original"
# state would make uninstall restore vr-telex's own files.
installed_without_backup() {
  exists "$BIN_DST" || exists "$UNIT_DST" || exists "$ENV_DST" || exists "$DBUS_SVC_DST" ||
    cmp -s -- "$REPO/packaging/xinputrc" "$XINPUTRC" ||
    cmp -s -- "$REPO/packaging/org.fcitx.Fcitx5.desktop" "$AUTOSTART_DST"
}

# --- moving a vr-talex install to vr-telex (D37) -----------------------------
#
# The vr-talex install keeps working until the new daemon is healthy: its
# backup is copied (not moved), and its own files are removed only after the
# health check (migrate_commit). Before anything changes, MIG_SNAP saves
# every file and setting this run can touch, so a failed run puts the
# vr-talex install back exactly and starts it again (restore_legacy) instead
# of removing both installs: on a machine where fcitx5 is gone (D31) that
# would leave no Vietnamese input method at all.

SNAP_PATHS=()
SNAP_UNITS=()

unit_state() {
  local u=$1 en=no act=no
  if systemctl --user is-enabled --quiet "$u" 2>/dev/null; then en=yes; fi
  if systemctl --user is-active --quiet "$u" 2>/dev/null; then act=yes; fi
  printf '%s\t%s\t%s\n' "$u" "$en" "$act"
}

legacy_snapshot() {
  local f r
  mkdir -p -- "$DATA_HOME" || die "cannot create $DATA_HOME"
  MIG_SNAP=$(mktemp -d "$DATA_HOME/.vr-telex-migrate.XXXXXX") || die "cannot write in $DATA_HOME"
  mkdir -m 0700 -- "$MIG_SNAP/files"
  SNAP_PATHS=("${MANAGED_FILES[@]}" "$LEGACY_BIN" "$LEGACY_UNIT_DST" "$LEGACY_ENV" "$DAEMON_STATE_DIR/mode")
  for f in "${SNAP_PATHS[@]}"; do
    r=$(rel "$f")
    if exists "$f"; then
      if [ -d "$f" ] && [ ! -L "$f" ]; then die "$f is a directory; move it away and run again"; fi
      mkdir -p -- "$MIG_SNAP/files/$(dirname -- "$r")"
      cp -a -- "$f" "$MIG_SNAP/files/$r" || die "cannot save $f"
      printf 'present\t%s\n' "$r"
    else
      printf 'absent\t%s\n' "$r"
    fi
  done >"$MIG_SNAP/list"
  printf 'mru-sources\t%s\nsources\t%s\n' "$(gs_get mru-sources)" "$(gs_get sources)" >"$MIG_SNAP/gs"
  { unit_state "$LEGACY_UNIT" && unit_state "$UNIT"; } >"$MIG_SNAP/units"
  if exists "$STATE_DIR"; then
    cp -a -- "$STATE_DIR" "$MIG_SNAP/state" || die "cannot save $STATE_DIR"
  fi
  exists "$DAEMON_STATE_DIR" || : >"$MIG_SNAP/no-daemon-state-dir"
}

# Put the snapshot back and start vr-talex again. Every step runs even when
# one fails; returns 1 when any did.
restore_legacy() {
  local fail=0 k v st r u en act svc_rel
  [ -n "$MIG_SNAP" ] && [ -f "$MIG_SNAP/list" ] || return 1
  # Input sources first, as in restore_all. A key already holding its saved
  # value is left alone, and one saved at its default is reset, so a key the
  # user never set stays unset.
  while IFS=$'\t' read -r k v; do
    [ "$(gs_get "$k")" = "$v" ] && continue
    gs_put "$k" "$v" || fail=1
  done <"$MIG_SNAP/gs"

  # The activation file names vr-talex again before the new unit stops, so
  # a client call in between cannot start vr-telex.
  svc_rel=$(rel "$DBUS_SVC_DST")
  restore_snap_entry "$(snap_state "$svc_rel")" "$svc_rel" || fail=1
  reload_bus
  if systemctl --user is-enabled --quiet "$UNIT" 2>/dev/null || systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
    systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || fail=1
  fi

  while IFS=$'\t' read -r st r; do
    [ "$r" = "$svc_rel" ] || restore_snap_entry "$st" "$r" || fail=1
  done <"$MIG_SNAP/list"

  if exists "$STATE_DIR"; then rm -rf -- "${DATA_HOME:?}/vr-telex" || fail=1; fi
  if [ -d "$MIG_SNAP/state" ]; then mv -T -- "$MIG_SNAP/state" "$STATE_DIR" || fail=1; fi
  if [ -f "$MIG_SNAP/no-daemon-state-dir" ]; then rmdir -- "$DAEMON_STATE_DIR" 2>/dev/null || true; fi

  systemctl --user daemon-reload >/dev/null 2>&1 || fail=1
  reload_bus
  while IFS=$'\t' read -r u en act; do
    if [ "$en" = yes ]; then systemctl --user enable "$u" >/dev/null 2>&1 || fail=1; fi
    if [ "$act" = yes ]; then systemctl --user start "$u" >/dev/null 2>&1 || fail=1; fi
  done <"$MIG_SNAP/units"
  [ "$fail" = 0 ]
}

# The saved state (present or absent) of one snapshot path.
snap_state() {
  local st r
  while IFS=$'\t' read -r st r; do
    if [ "$r" = "$1" ]; then printf '%s' "$st"; fi
  done <"$MIG_SNAP/list"
}

# One snapshot entry back: a saved file replaces what is there; a path that
# did not exist loses what this run wrote there.
restore_snap_entry() {
  local st=$1 r=$2 dst
  dst=$HOME/$r
  case "$st" in
    present)
      same_entry "$dst" "$MIG_SNAP/files/$r" && return 0
      replace_with "$MIG_SNAP/files/$r" "$dst" || {
        warn "not restored: $dst"
        return 1
      }
      ;;
    absent)
      if exists "$dst"; then rm -f -- "$dst" || return 1; fi
      ;;
    *) return 1 ;;
  esac
  return 0
}

# Before any change: a vr-talex install without any backup cannot be moved
# (there is nothing to restore later); one with a backup gets the snapshot
# and, when vr-telex has none yet, a rewritten copy of that backup.
plan_migration() {
  if [ ! -f "$MANIFEST" ] && { [ ! -f "$LEGACY_MANIFEST" ] || [ -L "$LEGACY_MANIFEST" ]; }; then
    die "vr-talex (the old name of vr-telex) is installed without a backup; run ./uninstall.sh first, then ./install.sh"
  fi
  say "found an install under the old name vr-talex; moving it to vr-telex"
  legacy_snapshot
  MIGRATING=1
  ROLLBACK=1
  if [ ! -f "$MANIFEST" ]; then legacy_copy_backup; fi
}

# After the new files are in place and before fcitx5 / the new daemon: stop
# vr-talex (it owns the same D-Bus names), rename its input source in place
# and carry its VI/EN mode over.
migrate_live() {
  legacy_stop_unit || die "could not stop $LEGACY_UNIT"
  legacy_rename_sources || die "could not rename the vr-talex input source"
  local old=$LEGACY_DAEMON_STATE_DIR/mode
  if [ -f "$old" ] && [ ! -L "$old" ] && [ ! -L "$LEGACY_DAEMON_STATE_DIR" ] && ! exists "$DAEMON_STATE_DIR/mode"; then
    mkdir -p -m 0700 -- "$DAEMON_STATE_DIR" && cp -p -- "$old" "$DAEMON_STATE_DIR/mode" ||
      warn "could not carry the VI/EN mode over; it starts in VI"
  fi
}

# The new daemon is healthy: remove what is left of vr-talex. Its backup goes
# only when the vr-telex backup was copied from it; otherwise the vr-telex
# one was there first and the older one is kept and reported.
migrate_commit() {
  local drop=0
  if [ -f "$FROM_LEGACY" ]; then drop=1; fi
  legacy_cleanup "$drop"
  rm -f -- "$FROM_LEGACY"
  say "moved the vr-talex install to vr-telex"
}

main() {
  require_user
  init_paths
  preflight
  build_binary
  if legacy_found; then
    plan_migration
  elif legacy_source_listed; then
    # Nothing else of vr-talex is left, so its entry can never work again;
    # it goes before the backup, so uninstall does not bring it back.
    legacy_drop_sources || die "could not remove the old vr-talex input source"
  fi
  if [ -f "$MANIFEST" ]; then
    RERUN=1
  else
    if installed_without_backup; then
      die "vr-telex is installed without a backup; run ./uninstall.sh first, then ./install.sh"
    fi
    backup_state
  fi
  ROLLBACK=1
  install_files
  if [ "$MIGRATING" = 1 ]; then migrate_live; fi
  hand_over_fcitx5
  select_source
  start_daemon
  health_check
  ROLLBACK=0
  if [ "$MIGRATING" = 1 ]; then
    MIGRATING=0
    migrate_commit
  fi
  # The shell's current source cannot be read back from here (no Eval), so
  # this says what to look for instead of claiming it is selected (BASE-48).
  say "installed; the top bar shows vi or en while Vietnamese (Telex) is the current source ($(switch_shortcut) switches sources)"
  say "Ctrl+Shift switches between Vietnamese and English"
  print_recovery
}

trap on_exit EXIT
main "$@"
