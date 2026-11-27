# shellcheck shell=bash
# The install and uninstall logic, sourced by install.sh / uninstall.sh of a
# checkout and by vr-telex-setup of the package (never run on its own). Both
# kinds run the same code; use_checkout / use_package set what differs:
# where the shared files come from, which binary runs and which unit it runs
# in, and the command names in messages.
#
# Everything here writes only under $HOME and talks only to the user's own
# session bus and systemd user manager (SEC-20). Processes are stopped only
# through systemctl --user or fcitx5's own quit request, never by name
# (SEC-23).

SCHEMA=org.gnome.desktop.input-sources
VR_SOURCE="('ibus', 'vr-telex')"
UNIT=vr-telex.service
FCITX_NAME=org.fcitx.Fcitx5
FCITX_UNIT=fcitx5.service
IBUS_GNOME_UNIT=org.freedesktop.IBus.session.GNOME.service
TIMEOUT=${VR_TELEX_TIMEOUT:-10}

# The project was first published as vr-talex (D37). These names exist only
# to find and retire such an install; nothing is ever written under them.
LEGACY_NAME=vr-talex
LEGACY_SOURCE="('ibus', '$LEGACY_NAME')"
LEGACY_UNIT=$LEGACY_NAME.service

# A checkout (install.sh / uninstall.sh, $1 = the checkout): builds the
# binary, installs it to ~/.local/bin and its own unit to
# ~/.config/systemd/user.
use_checkout() {
  KIND=checkout
  REPO=$1
  SHARE=$REPO/packaging
  INSTALL_CMD=./install.sh
  UNINSTALL_CMD=./uninstall.sh
  UNINSTALL_PATH=$REPO/uninstall.sh
}

# The package (vr-telex-setup, $1 = its shared files dir): runs the packaged
# binary in the packaged unit. Nothing is built and nothing goes to
# ~/.local/bin or ~/.config/systemd/user except the link `systemctl --user
# enable` makes there; a from-source install found there is retired
# (retire_checkout_files).
use_package() {
  KIND=package
  SHARE=$1
  DAEMON_BIN=${VR_TELEX_BIN:-/usr/bin/vr-telex}
  SYSTEM_UNIT_DIR=${VR_TELEX_SYSTEM_UNIT_DIR:-/usr/lib/systemd/user}
  INSTALL_CMD=vr-telex-setup
  UNINSTALL_CMD='vr-telex-setup --remove'
  UNINSTALL_PATH='vr-telex-setup --remove'
}

# A shared file. The package ships only its own unit; the checkout's unit
# differs from it in ExecStart alone (tests/deb checks that), so it is
# derived from the packaged one where uninstall needs to recognise it.
share_file() {
  if [ "$1" = "$UNIT" ] && [ ! -f "$SHARE/$1" ] && [ "$KIND" = package ]; then
    sed 's|^ExecStart=.*|ExecStart="%h/.local/bin/vr-telex"|' -- "$SYSTEM_UNIT_DIR/$UNIT"
  else
    cat -- "$SHARE/$1"
  fi
}

say() { printf 'vr-telex: %s\n' "$*"; }
warn() { printf 'vr-telex: warning: %s\n' "$*" >&2; }
die() {
  printf 'vr-telex: error: %s\n' "$*" >&2
  exit 1
}

require_user() {
  if [ "$(id -u)" -eq 0 ]; then
    printf 'vr-telex: error: do not run as root or with sudo; run it as your own user\n' >&2
    exit 1
  fi
  : "${HOME:?HOME is not set}"
  if [ ! -d "$HOME" ] || [ ! -O "$HOME" ]; then die "HOME ($HOME) is not a directory you own"; fi
  case "$HOME" in
    /*) ;;
    *) die "HOME must be an absolute path" ;;
  esac
  # The backup manifest is tab- and line-separated.
  case "$HOME" in
    *$'\t'* | *$'\n'*) die "HOME contains a tab or newline" ;;
  esac
  case "$TIMEOUT" in
    '' | *[!0-9]*) die "VR_TELEX_TIMEOUT must be a number of seconds" ;;
  esac
}

inside_home() {
  case "$1" in
    "$HOME"/*) ;;
    *) die "$2 ($1) must be inside HOME" ;;
  esac
  case "/$1/" in
    */../* | */./*) die "$2 ($1) must not contain . or .. parts" ;;
  esac
  # The backup manifest is tab- and line-separated.
  case "$1" in
    *$'\t'* | *$'\n'*) die "$2 contains a tab or newline" ;;
  esac
}

init_paths() {
  CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
  DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
  STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}
  inside_home "$CONFIG_HOME" XDG_CONFIG_HOME
  inside_home "$DATA_HOME" XDG_DATA_HOME
  inside_home "$STATE_HOME" XDG_STATE_HOME

  # The unit runs %h/.local/bin/vr-telex, so this path does not follow XDG.
  BIN_DST=$HOME/.local/bin/vr-telex
  # The binary the D-Bus activation file starts (render_dbus_svc).
  if [ "$KIND" = checkout ]; then
    DAEMON_BIN=$BIN_DST
  else
    case "$DAEMON_BIN" in
      /*) ;;
      *) die "VR_TELEX_BIN must be an absolute path" ;;
    esac
  fi
  case "$DAEMON_BIN" in
    *'"'* | *'\'*)
      if [ "$KIND" = checkout ]; then die "HOME contains a double quote or backslash, which the D-Bus service file cannot hold"; fi
      die "$DAEMON_BIN contains a double quote or backslash, which the D-Bus service file cannot hold"
      ;;
  esac
  UNIT_DIR=$CONFIG_HOME/systemd/user
  UNIT_DST=$UNIT_DIR/$UNIT
  WANTS_DIR=$UNIT_DIR/graphical-session.target.wants
  ENV_DST=$CONFIG_HOME/environment.d/90-vr-telex.conf
  XINPUTRC=$HOME/.xinputrc
  AUTOSTART_DST=$CONFIG_HOME/autostart/org.fcitx.Fcitx5.desktop
  DBUS_SVC_DST=$DATA_HOME/dbus-1/services/org.fcitx.Fcitx5.service
  IBUS_BUS_DIR=$CONFIG_HOME/ibus/bus
  STATE_DIR=$DATA_HOME/vr-telex
  BACKUP_DIR=$STATE_DIR/backup
  MANIFEST=$BACKUP_DIR/manifest
  DAEMON_STATE_DIR=$STATE_HOME/vr-telex
  RUNTIME_BASE=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

  LEGACY_BIN=$HOME/.local/bin/$LEGACY_NAME
  LEGACY_UNIT_DST=$UNIT_DIR/$LEGACY_UNIT
  LEGACY_ENV=$CONFIG_HOME/environment.d/90-$LEGACY_NAME.conf
  LEGACY_STATE_DIR=$DATA_HOME/$LEGACY_NAME
  LEGACY_BACKUP=$LEGACY_STATE_DIR/backup
  LEGACY_MANIFEST=$LEGACY_BACKUP/manifest
  LEGACY_DAEMON_STATE_DIR=$STATE_HOME/$LEGACY_NAME
  LEGACY_RUNTIME_DIR=$RUNTIME_BASE/$LEGACY_NAME
  # Written into the vr-telex backup when it was copied from the vr-talex
  # one, so the vr-talex backup may go once the move is complete.
  FROM_LEGACY=$BACKUP_DIR/from-$LEGACY_NAME

  MANAGED_FILES=("$BIN_DST" "$UNIT_DST" "$ENV_DST" "$XINPUTRC" "$AUTOSTART_DST" "$DBUS_SVC_DST")
  MANAGED_DIRS=("$HOME/.local" "$HOME/.local/bin"
    "$DATA_HOME" "$DATA_HOME/dbus-1" "$DATA_HOME/dbus-1/services" "$STATE_DIR"
    "$CONFIG_HOME" "$CONFIG_HOME/systemd" "$UNIT_DIR" "$WANTS_DIR"
    "$CONFIG_HOME/environment.d" "$CONFIG_HOME/autostart"
    "$CONFIG_HOME/ibus" "$IBUS_BUS_DIR"
    "$STATE_HOME" "$DAEMON_STATE_DIR")
}

rel() { printf '%s' "${1#"$HOME"/}"; }

need_commands() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "$c not found"
  done
}

# --- session bus -------------------------------------------------------------

bus_call() {
  local method=$1
  shift
  gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method "org.freedesktop.DBus.$method" "$@"
}

owner_pid() {
  local out
  out=$(bus_call GetConnectionUnixProcessID "$1" 2>/dev/null) || return 1
  out=${out#*uint32 }
  out=${out%%,*}
  case "$out" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$out"
}

has_owner() { owner_pid "$1" >/dev/null; }

machine_id() {
  local out
  out=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.Peer.GetMachineId 2>/dev/null) || return 1
  out=${out#"('"}
  out=${out%%"'"*}
  case "$out" in
    '' | *[!0-9a-f]*) return 1 ;;
  esac
  printf '%s\n' "$out"
}

# The bus also watches its service dirs; the explicit reload makes the
# shadowing of fcitx5's activation file take effect before fcitx5 quits.
reload_bus() {
  bus_call ReloadConfig >/dev/null 2>&1 || warn "the session bus did not reload its service files"
}

# --- systemd user manager --------------------------------------------------

unit_pid() {
  local pid
  pid=$(systemctl --user show -p MainPID --value "${1:-$UNIT}" 2>/dev/null) || pid=0
  case "$pid" in
    '' | *[!0-9]*) pid=0 ;;
  esac
  printf '%s\n' "$pid"
}

# Event wait on a process we were told about (no polling loop of our own).
wait_pid_exit() {
  timeout "$TIMEOUT" tail --pid="$1" -s 0.2 -f /dev/null >/dev/null 2>&1
}

# --- gsettings ---------------------------------------------------------------

gs_get() { gsettings get "$SCHEMA" "$1"; }

# The schema default, read without touching the user's settings.
gs_default() { GSETTINGS_BACKEND=memory gsettings get "$SCHEMA" "$1"; }

# Write a value; a value equal to the default is written as a reset, so a
# key the user never set ends up unset again.
gs_put() {
  if [ "$2" = "$(gs_default "$1")" ]; then
    gsettings reset "$SCHEMA" "$1"
  else
    gsettings set "$SCHEMA" "$1" "$2"
  fi
}

# A source list without the entry $2.
without_source() {
  local items src=$2
  items=$(list_items "$1")
  items=${items//"$src, "/}
  items=${items//", $src"/}
  items=${items//"$src"/}
  if [ -z "$items" ]; then printf '@a(ss) []'; else printf '[%s]' "$items"; fi
}

# A source list without the vr-telex entry.
without_vr() { without_source "$1" "$VR_SOURCE"; }

# Restore one key. When it still holds what install wrote, the saved value
# comes back; when the user changed it since (a layout added, another
# source selected), only the vr-telex entry is taken out.
gs_restore() {
  local key=$1 saved=$2 installed=$3 cur new
  cur=$(gs_get "$key") || return 1
  [ "$cur" = "$saved" ] && return 0
  if [ -n "$installed" ] && [ "$cur" = "$installed" ]; then
    gs_put "$key" "$saved"
    # Explicit status: a bare return inside the EXIT trap (install rollback)
    # would return the status the trap started with.
    return $?
  fi
  new=$(without_vr "$cur")
  [ "$new" = "$cur" ] && return 0
  gs_put "$key" "$new" || return 1
  say "kept your changes to input sources ($key); removed only Vietnamese (Telex)"
}

# dbus-daemon splits Exec like a shell. Measured on dbus 1.14 (T8 fix
# round 1): a double-quoted path with spaces, & or ' starts; a backslash
# escape makes the whole service file invalid. So the path is double-quoted
# and init_paths refuses a binary path holding " or \.
render_dbus_svc() {
  local svc bin=${1:-$DAEMON_BIN}
  svc=$(<"$SHARE/org.fcitx.Fcitx5.service")
  printf '%s\n' "${svc//@BIN@/"\"$bin\""}"
}

# "[('xkb', 'us'), ...]" or "@a(ss) []" -> "('xkb', 'us'), ..."
list_items() {
  local v=$1
  v=${v#"@a(ss) "}
  v=${v#[}
  v=${v%]}
  printf '%s' "$v"
}

# --- backup manifest ---------------------------------------------------------

check_rel() {
  [ -n "$1" ] || die "corrupt backup manifest (empty path)"
  case "/$1/" in
    //* | */../* | */./*) die "corrupt backup manifest (path $1)" ;;
  esac
}

load_manifest() {
  local kind a b
  M_VERSION='' M_FCITX=none M_FCITX_EN=no
  M_PRESENT=() M_ABSENT=() M_DIRS=() M_GS_KEYS=() M_GS_VALS=()
  if [ ! -f "$MANIFEST" ] || [ -L "$MANIFEST" ]; then die "backup manifest $MANIFEST is missing"; fi
  while IFS=$'\t' read -r kind a b || [ -n "$kind" ]; do
    case "$kind" in
      v) M_VERSION=$a ;;
      file)
        check_rel "$a"
        case "$b" in
          present) M_PRESENT+=("$a") ;;
          absent) M_ABSENT+=("$a") ;;
          *) die "corrupt backup manifest (file state $b)" ;;
        esac
        ;;
      dir) check_rel "$a" && M_DIRS+=("$a") ;;
      gs)
        case "$a" in
          sources | mru-sources) ;;
          *) die "corrupt backup manifest (key $a)" ;;
        esac
        M_GS_KEYS+=("$a")
        M_GS_VALS+=("$b")
        ;;
      fcitx5)
        case "$a" in
          none | remote | unit) M_FCITX=$a ;;
          *) die "corrupt backup manifest (fcitx5 $a)" ;;
        esac
        M_FCITX_EN=$b
        ;;
      *) die "corrupt backup manifest (entry $kind)" ;;
    esac
  done <"$MANIFEST"
  [ "$M_VERSION" = 1 ] || die "unknown backup manifest version"
}

in_list() {
  local needle=$1 x
  shift
  for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
  return 1
}

exists() { [ -e "$1" ] || [ -L "$1" ]; }

# Same kind of entry with the same link target, or the same content and mode.
same_entry() {
  if [ -L "$1" ] || [ -L "$2" ]; then
    [ -L "$1" ] && [ -L "$2" ] && [ "$(readlink -- "$1")" = "$(readlink -- "$2")" ]
    # Explicit status: a bare return inside the EXIT trap (install rollback)
    # would return the status the trap started with.
    return $?
  fi
  [ -f "$1" ] && [ -f "$2" ] && cmp -s -- "$1" "$2" &&
    [ "$(stat -c %a -- "$1")" = "$(stat -c %a -- "$2")" ]
}

# Put a copy of src at dst. dst is never removed first: the copy is
# complete next to it before one rename replaces it.
replace_with() {
  local src=$1 dst=$2 dir tmp
  dir=$(dirname -- "$dst")
  mkdir -p -- "$dir" || return 1
  tmp=$(mktemp -d "$dir/.vr-telex-tmp.XXXXXX") || return 1
  if cp -a -- "$src" "$tmp/entry" 2>/dev/null && mv -fT -- "$tmp/entry" "$dst"; then
    rmdir -- "$tmp"
    return 0
  fi
  rm -f -- "$tmp/entry"
  rmdir -- "$tmp" 2>/dev/null
  return 1
}

# Move a file the user changed after install aside, under a name nothing
# reads (environment.d only reads *.conf, autostart only *.desktop).
keep_user_copy() {
  local dst=$1 saved
  saved="$dst.vr-telex-saved-$(date +%Y%m%d-%H%M%S)"
  if exists "$saved"; then saved="$saved-$$"; fi
  mv -T -- "$dst" "$saved" || return 1
  warn "$dst was changed after install; your version is kept as $saved"
}

# Record what install wrote, so uninstall can tell the user's later edits
# from its own files.
# Called before dst is written: if the record cannot be made, nothing has
# been written yet, so a rollback never meets an unrecorded vr-telex file.
record_installed() {
  local src=$1 mode=$2 dst=$3 r dir tmp
  r=$(rel "$dst")
  dir=$BACKUP_DIR/installed/$(dirname -- "$r")
  mkdir -p -- "$dir" || return 1
  tmp=$(mktemp "$dir/.rec.XXXXXX") || return 1
  if cp -- "$src" "$tmp" && chmod "$mode" "$tmp" && mv -f -- "$tmp" "$BACKUP_DIR/installed/$r"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

installed_gs() {
  local key=$1 k v
  [ -f "$BACKUP_DIR/installed.gs" ] || return 0
  while IFS=$'\t' read -r k v || [ -n "$k" ]; do
    if [ "$k" = "$key" ]; then printf '%s' "$v"; fi
  done <"$BACKUP_DIR/installed.gs"
}

# Bring one managed path back to its pre-install state. Appends to
# RESTORE_FAILED on any failure; never deletes a file before its
# replacement is in place, never drops a version the user wrote.
restore_entry() {
  local rel=$1 state=$2 dst bak inst daemon_file=0
  dst=$HOME/$rel
  bak=$BACKUP_DIR/files/$rel
  inst=$BACKUP_DIR/installed/$rel
  # IBus address files are rewritten by whichever daemon runs; they are
  # restored as saved, without an edit check.
  case "$rel" in
    "$(rel "$IBUS_BUS_DIR")"/*) daemon_file=1 ;;
  esac
  if [ -d "$dst" ] && [ ! -L "$dst" ]; then
    RESTORE_FAILED+=("$dst (now a directory)")
    return 0
  fi
  if [ "$state" = absent ]; then
    exists "$dst" || return 0
    if exists "$inst" && same_entry "$dst" "$inst"; then
      rm -f -- "$dst" || RESTORE_FAILED+=("$dst")
    elif exists "$inst"; then
      keep_user_copy "$dst" || RESTORE_FAILED+=("$dst")
    else
      warn "$dst was not written by vr-telex; left in place"
    fi
    return 0
  fi
  same_entry "$dst" "$bak" && return 0
  if [ "$daemon_file" = 0 ] && exists "$dst" && ! { exists "$inst" && same_entry "$dst" "$inst"; }; then
    keep_user_copy "$dst" || {
      RESTORE_FAILED+=("$dst")
      return 0
    }
  fi
  replace_with "$bak" "$dst" || RESTORE_FAILED+=("$dst")
}

# Undo an install from the manifest: used by uninstall.sh and by the
# rollback of a failed install (SEC-19, SEC-21). Every step runs even when
# one fails; any failure keeps the backup and makes this return 1.
restore_all() {
  local i rel dst vr_pid legacy_pid u f d key svc_rel
  RESTORE_FAILED=()
  load_manifest

  # Input sources first, so the shell leaves the vr-telex source while the
  # daemon still answers; mru-sources before sources, because gnome-shell
  # activates the head of the MRU list when sources changes.
  for key in mru-sources sources; do
    for i in "${!M_GS_KEYS[@]}"; do
      [ "${M_GS_KEYS[$i]}" = "$key" ] || continue
      gs_restore "$key" "${M_GS_VALS[$i]}" "$(installed_gs "$key")" ||
        RESTORE_FAILED+=("input sources ($key)")
    done
  done

  # The D-Bus activation shadow goes first, and the bus drops it, before the
  # unit stops: a client call to org.fcitx.Fcitx5 after the stop would
  # otherwise start vr-telex again, and that process would keep the name
  # after its unit file is gone, so fcitx5 could not take it back.
  svc_rel=$(rel "$DBUS_SVC_DST")
  if in_list "$svc_rel" "${M_ABSENT[@]}"; then
    restore_entry "$svc_rel" absent
  elif in_list "$svc_rel" "${M_PRESENT[@]}"; then
    restore_entry "$svc_rel" present
  fi
  reload_bus

  vr_pid=$(unit_pid)
  legacy_pid=$(unit_pid "$LEGACY_UNIT")
  # A vr-talex unit still running (uninstall of an install under the old
  # name) holds org.fcitx.Fcitx5 too, so fcitx5 could not come back.
  for u in "$UNIT" "$LEGACY_UNIT"; do
    if systemctl --user is-enabled --quiet "$u" 2>/dev/null || systemctl --user is-active --quiet "$u" 2>/dev/null; then
      systemctl --user disable --now "$u" >/dev/null 2>&1 || warn "could not stop $u"
    fi
  done

  for rel in "${M_ABSENT[@]}"; do
    [ "$rel" = "$svc_rel" ] || restore_entry "$rel" absent
  done
  for rel in "${M_PRESENT[@]}"; do
    [ "$rel" = "$svc_rel" ] || restore_entry "$rel" present
  done

  # IBus address files vr-telex published that did not exist before.
  if [ -d "$IBUS_BUS_DIR" ]; then
    for f in "$IBUS_BUS_DIR"/*; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      in_list "$(rel "$f")" "${M_PRESENT[@]}" && continue
      if { [ "$vr_pid" != 0 ] && grep -qx "IBUS_DAEMON_PID=$vr_pid" "$f"; } ||
        { [ "$legacy_pid" != 0 ] && grep -qx "IBUS_DAEMON_PID=$legacy_pid" "$f"; } ||
        grep -qF "IBUS_ADDRESS=unix:path=$RUNTIME_BASE/vr-telex/" "$f" ||
        grep -qF "IBUS_ADDRESS=unix:path=$LEGACY_RUNTIME_DIR/" "$f"; then
        rm -f -- "$f"
      fi
    done
  fi
  # The daemon's own state (input mode), never anything else in that dir.
  rm -f -- "$DAEMON_STATE_DIR/mode"

  systemctl --user daemon-reload >/dev/null 2>&1 || warn "systemctl --user daemon-reload failed"
  reload_bus

  case "$M_FCITX" in
    unit)
      if [ "$M_FCITX_EN" = yes ]; then systemctl --user enable "$FCITX_UNIT" >/dev/null 2>&1 || true; fi
      systemctl --user start "$FCITX_UNIT" >/dev/null 2>&1 || warn "could not start $FCITX_UNIT"
      ;;
    remote)
      if ! has_owner "$FCITX_NAME"; then
        if command -v fcitx5 >/dev/null 2>&1; then
          fcitx5 -d >/dev/null 2>&1 || warn "fcitx5 -d failed"
        else
          warn "fcitx5 not found; it cannot be started again"
        fi
      fi
      ;;
  esac
  if [ "$M_FCITX" != none ]; then
    if gdbus wait --session --timeout "$TIMEOUT" "$FCITX_NAME" >/dev/null 2>&1; then
      say "fcitx5 is running again"
    else
      warn "fcitx5 did not start; start it from the app menu or log out and in"
    fi
  fi

  if [ ${#RESTORE_FAILED[@]} -gt 0 ]; then
    for f in "${RESTORE_FAILED[@]}"; do warn "not restored: $f"; done
    warn "the backup is kept in $BACKUP_DIR; fix the cause, then run $UNINSTALL_PATH again"
    return 1
  fi
  rm -rf -- "${DATA_HOME:?}/vr-telex/backup"
  remove_created_dirs
}

# Directories install created (from the loaded manifest), deepest first;
# non-empty ones stay.
remove_created_dirs() {
  local d
  for d in "${M_DIRS[@]}" "$(rel "$DAEMON_STATE_DIR")"; do
    printf '%s\t%s\n' "$(tr -cd / <<<"$d" | wc -c)" "$d"
  done | sort -rn | cut -f2- | while IFS= read -r d; do
    rmdir -- "$HOME/$d" 2>/dev/null || true
  done
}

print_recovery() {
  say "if typing stops working: run 'systemctl --user disable --now vr-telex.service', then '$UNINSTALL_PATH'"
}

# --- legacy vr-talex install (D37) ---------------------------------------------
#
# install.sh moves a vr-talex install to vr-telex; uninstall.sh removes one.
# Only files the vr-talex installer wrote are removed (SEC-24): a file at a
# vr-talex path counts as ours when it equals the copy that installer kept in
# backup/installed/, or, without that copy, its template. A binary has no
# template, so without the copy it is never taken for ours: a wrapper script
# of the user's at that path would match any content test.

# A packaging template as the vr-talex installer wrote it: the files differ
# only in the name.
legacy_template() { share_file "$1" | sed "s/vr-telex/$LEGACY_NAME/g"; }

# The D-Bus activation file the vr-talex installer wrote.
legacy_render_dbus_svc() {
  local svc
  svc=$(<"$SHARE/org.fcitx.Fcitx5.service")
  svc=${svc//"SystemdService=$UNIT"/"SystemdService=$LEGACY_UNIT"}
  printf '%s\n' "${svc//@BIN@/"\"$LEGACY_BIN\""}"
}

legacy_is_ours() {
  local f=$1 rec
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  rec=$LEGACY_BACKUP/installed/$(rel "$f")
  if [ -f "$rec" ] && [ ! -L "$rec" ] && [ ! -L "$LEGACY_STATE_DIR" ] && [ ! -L "$LEGACY_BACKUP" ]; then
    same_entry "$f" "$rec"
    return $?
  fi
  case "$f" in
    "$LEGACY_UNIT_DST") cmp -s -- <(legacy_template vr-telex.service) "$f" ;;
    "$LEGACY_ENV") cmp -s -- <(legacy_template 90-vr-telex.conf) "$f" ;;
    *) return 1 ;;
  esac
}

# Any sign of a vr-talex install: one of its own files, its backup or mode
# file, or its unit. A file of the user's that only has a vr-talex name is
# not one. Settings are not read here (see legacy_source_listed).
legacy_found() {
  exists "$LEGACY_STATE_DIR" && return 0
  exists "$LEGACY_DAEMON_STATE_DIR/mode" && return 0
  legacy_is_ours "$LEGACY_UNIT_DST" && return 0
  legacy_is_ours "$LEGACY_BIN" && return 0
  legacy_is_ours "$LEGACY_ENV" && return 0
  systemctl --user is-enabled --quiet "$LEGACY_UNIT" 2>/dev/null && return 0
  systemctl --user is-active --quiet "$LEGACY_UNIT" 2>/dev/null && return 0
  return 1
}

# The vr-talex input source is still listed (alone it is a dead entry, left
# by an uninstall of vr-talex without a backup).
legacy_source_listed() {
  local key
  for key in sources mru-sources; do
    case "$(gs_get "$key" 2>/dev/null)" in *"$LEGACY_SOURCE"*) return 0 ;; esac
  done
  return 1
}

legacy_stop_unit() {
  if systemctl --user is-enabled --quiet "$LEGACY_UNIT" 2>/dev/null ||
    systemctl --user is-active --quiet "$LEGACY_UNIT" 2>/dev/null; then
    say "stopping $LEGACY_UNIT (the old name of this input method)"
    systemctl --user disable --now "$LEGACY_UNIT" >/dev/null 2>&1 || return 1
  fi
  return 0
}

# The vr-talex (or an already renamed vr-telex) source is the current one:
# the head of mru-sources, or, with mru-sources empty, the head of sources
# (what gnome-shell activates then). Read before the rename, so the move
# can keep another current source current (AC-2).
legacy_was_current() {
  local key v
  for key in mru-sources sources; do
    v=$(gs_get "$key") || return 1
    case "$v" in
      "[$LEGACY_SOURCE"* | "[$VR_SOURCE"*) return 0 ;;
      "@a(ss) []" | "[]") ;;
      *) return 1 ;;
    esac
  done
  return 1
}

# A source list with the vr-talex entry renamed in place, so the order and
# the other entries stay; dropped instead when vr-telex is listed already.
legacy_renamed_sources() {
  local v=$1 items
  case "$v" in
    *"$LEGACY_SOURCE"*) ;;
    *)
      printf '%s' "$v"
      return 0
      ;;
  esac
  case "$v" in
    *"$VR_SOURCE"*) without_source "$v" "$LEGACY_SOURCE" ;;
    *)
      items=$(list_items "$v")
      printf '[%s]' "${items//"$LEGACY_SOURCE"/"$VR_SOURCE"}"
      ;;
  esac
}

# Rename the input source in both keys, mru-sources first (gnome-shell
# activates the head of the MRU list when sources changes).
legacy_rename_sources() {
  local key cur new
  for key in mru-sources sources; do
    cur=$(gs_get "$key") || return 1
    new=$(legacy_renamed_sources "$cur")
    [ "$new" = "$cur" ] && continue
    case "$cur" in
      "[("*")]") ;;
      *) die "unexpected $key value: $cur" ;;
    esac
    gsettings set "$SCHEMA" "$key" "$new" || return 1
  done
}

# Drop a left-over vr-talex entry from both keys (its engine is gone).
legacy_drop_sources() {
  local key cur new
  for key in mru-sources sources; do
    cur=$(gs_get "$key") || return 1
    case "$cur" in *"$LEGACY_SOURCE"*) ;; *) continue ;; esac
    new=$(without_source "$cur" "$LEGACY_SOURCE")
    gs_put "$key" "$new" || return 1
    say "removed the old vr-talex entry from input sources ($key)"
  done
}

legacy_map_rel() {
  local r=$1
  case "$r" in
    "$(rel "$LEGACY_BIN")") rel "$BIN_DST" ;;
    "$(rel "$LEGACY_UNIT_DST")") rel "$UNIT_DST" ;;
    "$(rel "$LEGACY_ENV")") rel "$ENV_DST" ;;
    "$(rel "$LEGACY_STATE_DIR")") rel "$STATE_DIR" ;;
    "$(rel "$LEGACY_DAEMON_STATE_DIR")") rel "$DAEMON_STATE_DIR" ;;
    *) printf '%s' "$r" ;;
  esac
}

# Turn a copy of the vr-talex backup ($1) into the vr-telex one: paths and
# the input source in the manifest, the recorded input sources, and the
# saved and recorded files under their new names. Returns 1 on anything it
# does not know, before the copy is put in place.
legacy_rewrite_backup() {
  local b=$1 kind a c out='' r n sub k v gs=''
  [ -f "$b/manifest" ] && [ ! -L "$b/manifest" ] || return 1
  while IFS=$'\t' read -r kind a c || [ -n "$kind" ]; do
    case "$kind" in
      v)
        [ "$a" = 1 ] || return 1
        out+="v"$'\t'"$a"$'\n'
        ;;
      dir) out+="dir"$'\t'"$(legacy_map_rel "$a")"$'\n' ;;
      file) out+="file"$'\t'"$(legacy_map_rel "$a")"$'\t'"$c"$'\n' ;;
      gs) out+="gs"$'\t'"$a"$'\t'"${c//"$LEGACY_SOURCE"/"$VR_SOURCE"}"$'\n' ;;
      fcitx5) out+="fcitx5"$'\t'"$a"$'\t'"$c"$'\n' ;;
      *) return 1 ;;
    esac
  done <"$b/manifest"
  printf '%s' "$out" >"$b/manifest.tmp" && mv -f -- "$b/manifest.tmp" "$b/manifest" || return 1

  if [ -f "$b/installed.gs" ]; then
    while IFS=$'\t' read -r k v || [ -n "$k" ]; do
      gs+="$k"$'\t'"${v//"$LEGACY_SOURCE"/"$VR_SOURCE"}"$'\n'
    done <"$b/installed.gs"
    printf '%s' "$gs" >"$b/installed.gs.tmp" && mv -f -- "$b/installed.gs.tmp" "$b/installed.gs" || return 1
  fi

  for r in "$(rel "$LEGACY_BIN")" "$(rel "$LEGACY_UNIT_DST")" "$(rel "$LEGACY_ENV")"; do
    n=$(legacy_map_rel "$r")
    for sub in files installed; do
      exists "$b/$sub/$r" || continue
      mkdir -p -- "$(dirname -- "$b/$sub/$n")" && mv -T -- "$b/$sub/$r" "$b/$sub/$n" || return 1
    done
  done
  : >"$b/$(basename -- "$FROM_LEGACY")" || return 1
}

# Copy the vr-talex backup to the vr-telex place, rewritten. The vr-talex
# one stays until the move is complete (legacy_cleanup), so a failed install
# can return to it. The copy appears in one rename, never half-written.
legacy_copy_backup() {
  local tmp
  if [ -L "$LEGACY_STATE_DIR" ] || [ -L "$LEGACY_BACKUP" ] || [ -L "$LEGACY_MANIFEST" ]; then
    die "refusing a symlinked vr-talex backup ($LEGACY_BACKUP)"
  fi
  if [ -L "$STATE_DIR" ] || [ -L "$BACKUP_DIR" ]; then die "refusing a symlinked backup dir ($BACKUP_DIR)"; fi
  # A partial backup from an interrupted first run holds no manifest.
  if [ -d "$BACKUP_DIR" ]; then rm -rf -- "${DATA_HOME:?}/vr-telex/backup"; fi
  mkdir -p -- "$STATE_DIR" || die "cannot create $STATE_DIR"
  tmp=$(mktemp -d "$STATE_DIR/.backup-tmp.XXXXXX") || die "cannot write in $STATE_DIR"
  if cp -a -- "$LEGACY_BACKUP/." "$tmp/" && legacy_rewrite_backup "$tmp" && mv -T -- "$tmp" "$BACKUP_DIR"; then
    say "moved the saved setup from $LEGACY_BACKUP to $BACKUP_DIR"
    return 0
  fi
  rm -rf -- "${tmp:?}"
  die "cannot copy the vr-talex backup $LEGACY_BACKUP (nothing was changed)"
}

# Remove one vr-talex file when it is ours; leave it, with a warning, when not.
legacy_retire_file() {
  local f=$1
  exists "$f" || return 0
  if legacy_is_ours "$f"; then
    rm -f -- "$f" || warn "could not remove $f"
  elif [ "$f" = "$LEGACY_BIN" ] && [ ! -f "$LEGACY_BACKUP/installed/$(rel "$f")" ]; then
    warn "$f cannot be told apart from a file of yours (vr-talex left no record of it); left in place, remove it by hand if it is the old vr-talex binary"
  else
    warn "$f is not the file vr-talex installed; left in place"
  fi
}

# What is left of vr-talex once vr-telex took over or was removed: its unit,
# binary and environment file (when ours), its stale runtime files and IBus
# address files, its mode file, and its backup when the vr-telex backup was
# copied from it ($1 = 1). Never fails; problems are warnings.
legacy_cleanup() {
  local drop_backup=$1 f
  legacy_stop_unit || warn "could not stop $LEGACY_UNIT"
  legacy_retire_file "$LEGACY_UNIT_DST"
  legacy_retire_file "$LEGACY_BIN"
  legacy_retire_file "$LEGACY_ENV"
  systemctl --user daemon-reload >/dev/null 2>&1 || warn "systemctl --user daemon-reload failed"

  # Its address files point at a socket that is gone.
  if [ -d "$IBUS_BUS_DIR" ]; then
    for f in "$IBUS_BUS_DIR"/*; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      if grep -qF "IBUS_ADDRESS=unix:path=$LEGACY_RUNTIME_DIR/" "$f"; then rm -f -- "$f" || warn "could not remove $f"; fi
    done
  fi
  # The daemon's own entries only (instance lock and socket).
  if [ -d "$LEGACY_RUNTIME_DIR" ] && [ ! -L "$LEGACY_RUNTIME_DIR" ]; then
    rm -f -- "$LEGACY_RUNTIME_DIR/ibus.lock" "$LEGACY_RUNTIME_DIR/ibus" || warn "could not clean $LEGACY_RUNTIME_DIR"
    rmdir -- "$LEGACY_RUNTIME_DIR" 2>/dev/null || true
  fi
  if [ -d "$LEGACY_DAEMON_STATE_DIR" ] && [ ! -L "$LEGACY_DAEMON_STATE_DIR" ]; then
    rm -f -- "$LEGACY_DAEMON_STATE_DIR/mode" || warn "could not remove $LEGACY_DAEMON_STATE_DIR/mode"
    rmdir -- "$LEGACY_DAEMON_STATE_DIR" 2>/dev/null || true
  fi

  if [ "$drop_backup" = 1 ] && [ ! -L "$LEGACY_STATE_DIR" ]; then
    if rm -rf -- "${DATA_HOME:?}/vr-talex/backup"; then
      rmdir -- "$LEGACY_STATE_DIR" 2>/dev/null || warn "$LEGACY_STATE_DIR is not empty; left in place"
    else
      warn "could not remove the older backup $LEGACY_BACKUP; it is no longer used, remove it by hand"
    fi
  elif exists "$LEGACY_STATE_DIR"; then
    warn "kept the older backup in $LEGACY_STATE_DIR: the one in $STATE_DIR is used instead; remove it by hand when you no longer need it"
  fi
  legacy_drop_sources || warn "could not remove the old vr-talex entry from input sources"
}

# --- install (install.sh, vr-telex-setup) ---------------------------------------

ROLLBACK=0
RERUN=0
# Set while a vr-talex install is being moved to vr-telex (D37). A failure
# then returns to that vr-talex install from the snapshot in MIG_SNAP, so the
# user keeps a working Vietnamese input method (see restore_legacy).
MIGRATING=0
MIG_SNAP=''
# Set by migrate_live when the renamed source is listed but was not the
# current one: the move then keeps the user's selection (AC-2).
MIG_KEEP_SELECTION=0
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
      say "rolled back: vr-talex runs again as before; fix the cause, then run $INSTALL_CMD again"
    else
      KEEP_SNAP=1
      warn "rollback is incomplete (see the lines above); the saved vr-talex files and settings are kept in $MIG_SNAP"
    fi
    say "if typing stops working: run 'systemctl --user disable --now $LEGACY_UNIT', then '$UNINSTALL_PATH'"
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
      say "the earlier install was removed too; fix the cause, then run $INSTALL_CMD again"
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
  command -v cargo >/dev/null 2>&1 || die "cargo not found; install the Rust toolchain, then run $INSTALL_CMD again"
  say "building (cargo build --release --locked)"
  (cd "$REPO" && cargo build --release --locked -p vr-telex) || die "build failed"
  SRC_BIN=${CARGO_TARGET_DIR:-$REPO/target}/release/vr-telex
  [ -x "$SRC_BIN" ] || die "build produced no $SRC_BIN"
}

# The package instead of a build: its binary and unit must be there, and no
# unit of the user's in ~/.config/systemd/user may replace the packaged one
# (systemd prefers it). A unit an earlier install.sh wrote there is fine:
# with its record it is retired (retire_checkout_files); without a backup it
# equals the checkout's unit, and installed_without_backup asks for
# --remove, which removes it (remove_if_ours). Anything else is refused here,
# before any change; --remove would not remove it, so that advice would only
# lead back here.
check_package() {
  if [ ! -f "$DAEMON_BIN" ] || [ ! -x "$DAEMON_BIN" ]; then
    die "$DAEMON_BIN is missing or not executable; is the vr-telex package installed?"
  fi
  [ -f "$SYSTEM_UNIT_DIR/$UNIT" ] ||
    die "the packaged unit $SYSTEM_UNIT_DIR/$UNIT is missing; is the vr-telex package installed?"
  if exists "$UNIT_DST" && ! exists "$BACKUP_DIR/installed/$(rel "$UNIT_DST")"; then
    if [ -f "$MANIFEST" ] || ! cmp -s -- <(share_file "$UNIT") "$UNIT_DST"; then
      die "$UNIT_DST would replace the packaged unit and was not written by vr-telex; move it away, then run $INSTALL_CMD again"
    fi
  fi
  SRC_BIN=$DAEMON_BIN
}

# The package takes over from a from-source install: its binary and unit in
# ~/.local/bin and ~/.config/systemd/user go, so the packaged unit runs.
# Only what install.sh recorded as written is removed; a version the user
# changed since is moved aside. The record goes too, so uninstall later finds
# nothing of vr-telex's there and the backup still restores the state before
# the first install. A record whose file is absent (a vr-talex backup moved
# over by the setup names files the package never writes) is dropped too, so
# a unit the user adds there later is refused by check_package, not moved
# aside.
retire_checkout_files() {
  local f inst gone=0
  for f in "$UNIT_DST" "$BIN_DST"; do
    inst=$BACKUP_DIR/installed/$(rel "$f")
    if ! exists "$f"; then
      rm -f -- "$inst" || die "cannot remove $inst"
      continue
    fi
    exists "$inst" || continue
    if [ "$f" = "$UNIT_DST" ]; then
      # The enable link points at this file; it is made again for the
      # packaged unit by start_daemon.
      systemctl --user disable "$UNIT" >/dev/null 2>&1 || die "could not disable $UNIT"
    fi
    if same_entry "$f" "$inst"; then
      rm -f -- "$f" || die "cannot remove $f"
    else
      keep_user_copy "$f" || die "cannot move $f aside"
    fi
    rm -f -- "$inst"
    gone=1
  done
  if [ "$gone" = 1 ]; then say "replaced the from-source install with the packaged vr-telex"; fi
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
  if [ "$KIND" = checkout ]; then
    # A running daemon is restarted on every run (start_daemon), so a new
    # binary needs no flag of its own.
    install_managed "$SRC_BIN" "$BIN_DST" 0755 || true
    if install_managed "$SHARE/vr-telex.service" "$UNIT_DST" 0644; then CHANGED_UNIT=1; fi
  else
    retire_checkout_files
    # The user manager loads a unit the package added or changed only on a
    # reload; it is cheap, so every run of the setup does one.
    CHANGED_UNIT=1
  fi
  install_managed "$SHARE/90-vr-telex.conf" "$ENV_DST" 0644 || true
  install_managed "$SHARE/xinputrc" "$XINPUTRC" 0644 || true
  install_managed "$SHARE/org.fcitx.Fcitx5.desktop" "$AUTOSTART_DST" 0644 || true

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
    command -v fcitx5-remote >/dev/null 2>&1 || die "fcitx5 (pid $pid) is running but fcitx5-remote is missing; quit fcitx5, then run $INSTALL_CMD again"
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
    cmp -s -- "$SHARE/xinputrc" "$XINPUTRC" ||
    cmp -s -- "$SHARE/org.fcitx.Fcitx5.desktop" "$AUTOSTART_DST"
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
    die "vr-talex (the old name of vr-telex) is installed without a backup; run $UNINSTALL_CMD first, then $INSTALL_CMD"
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
  local was_current=0
  # Read while vr-talex still runs: the shell may move away from a source
  # whose engine has gone.
  legacy_was_current && was_current=1
  legacy_stop_unit || die "could not stop $LEGACY_UNIT"
  legacy_rename_sources || die "could not rename the vr-talex input source"
  case "$(gs_get sources)" in
    *"$VR_SOURCE"*) [ "$was_current" = 1 ] || MIG_KEEP_SELECTION=1 ;;
  esac
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

install_main() {
  require_user
  init_paths
  preflight
  if [ "$KIND" = package ]; then check_package; else build_binary; fi
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
      die "vr-telex is installed without a backup; run $UNINSTALL_CMD first, then $INSTALL_CMD"
    fi
    backup_state
  fi
  ROLLBACK=1
  install_files
  if [ "$MIGRATING" = 1 ]; then migrate_live; fi
  hand_over_fcitx5
  if [ "$MIG_KEEP_SELECTION" = 1 ]; then
    say "kept the current input source; Vietnamese (Telex) stays where vr-talex was in the list"
  else
    select_source
  fi
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

# --- uninstall (uninstall.sh, vr-telex-setup --remove) ---------------------------

# Remove dst only when it is still the file install wrote; a version the
# user changed stays, with a warning naming it.
remove_if_ours() {
  if cmp -s -- "$1" "$2"; then
    rm -f -- "$2"
  elif exists "$2"; then
    warn "$2 was changed after install; left in place"
  fi
}

# Same for a file written from a template by either the vr-telex or the
# vr-talex installer; returns 0 when it was removed.
remove_template_copy() {
  local name=$1 dst=$2
  if cmp -s -- <(share_file "$name") "$dst" || cmp -s -- <(legacy_template "$name") "$dst"; then
    rm -f -- "$dst"
    return 0
  fi
  if exists "$dst"; then warn "$dst was changed after install; left in place"; fi
  return 1
}

# No backup (deleted by hand): remove only what is certainly ours.
remove_without_backup() {
  warn "no backup found in $BACKUP_DIR; removing vr-telex files only"
  # The activation shadow goes, and the bus drops it, before the unit stops,
  # so a client call in between cannot start vr-telex again (see restore_all).
  if cmp -s -- <(render_dbus_svc) "$DBUS_SVC_DST" || cmp -s -- <(render_dbus_svc "$BIN_DST") "$DBUS_SVC_DST" ||
    cmp -s -- <(legacy_render_dbus_svc) "$DBUS_SVC_DST"; then
    rm -f -- "$DBUS_SVC_DST"
  fi
  reload_bus
  systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || true
  legacy_stop_unit || warn "could not stop $LEGACY_UNIT"
  rm -f -- "$BIN_DST"
  remove_if_ours <(share_file vr-telex.service) "$UNIT_DST"
  remove_if_ours <(share_file 90-vr-telex.conf) "$ENV_DST"
  remove_template_copy org.fcitx.Fcitx5.desktop "$AUTOSTART_DST" || true
  if remove_template_copy xinputrc "$XINPUTRC"; then
    warn "removed ~/.xinputrc; run 'im-config' to choose an input method framework again"
  fi
  rm -f -- "$DAEMON_STATE_DIR/mode"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  reload_bus
  warn "input sources were not changed; remove 'Vietnamese (Telex)' in Settings > Keyboard if it is listed"
}

uninstall_main() {
  local drop_legacy=0
  require_user
  init_paths
  need_commands gdbus gsettings systemctl timeout tail
  # vr-talex saved the setup before it; restore from a vr-telex copy of it.
  if [ ! -f "$MANIFEST" ] && [ -f "$LEGACY_MANIFEST" ] && [ ! -L "$LEGACY_MANIFEST" ]; then
    say "found an install under the old name vr-talex"
    legacy_copy_backup
    legacy_rename_sources || die "could not rename the vr-talex input source"
  fi
  if [ -f "$FROM_LEGACY" ]; then drop_legacy=1; fi
  if [ ! -f "$MANIFEST" ]; then
    # The packaged setup leaves no binary or unit file in HOME; its enable
    # link or its running unit shows it is set up.
    if [ -e "$UNIT_DST" ] || [ -e "$BIN_DST" ] || legacy_found ||
      systemctl --user is-enabled --quiet "$UNIT" 2>/dev/null || systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
      remove_without_backup
      legacy_cleanup 0
      say "removed"
    else
      say "vr-telex is not installed; nothing to do"
    fi
    return 0
  fi
  if ! restore_all; then
    die "uninstall is incomplete; the files listed above were left as they are"
  fi
  if legacy_found || legacy_source_listed; then
    legacy_cleanup "$drop_legacy"
    remove_created_dirs
  fi
  say "removed; the previous input method setup is restored"
}
