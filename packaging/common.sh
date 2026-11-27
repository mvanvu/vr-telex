# shellcheck shell=bash
# Shared by install.sh and uninstall.sh (sourced, never run on its own).
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
  case "$BIN_DST" in
    *'"'* | *'\'*) die "HOME contains a double quote or backslash, which the D-Bus service file cannot hold" ;;
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
# and init_paths refuses a HOME holding " or \.
render_dbus_svc() {
  local svc
  svc=$(<"$REPO/packaging/org.fcitx.Fcitx5.service")
  printf '%s\n' "${svc//@BIN@/"\"$BIN_DST\""}"
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
    warn "the backup is kept in $BACKUP_DIR; fix the cause, then run $REPO/uninstall.sh again"
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
  say "if typing stops working: run 'systemctl --user disable --now vr-telex.service', then '$REPO/uninstall.sh'"
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
legacy_template() { sed "s/vr-telex/$LEGACY_NAME/g" "$REPO/packaging/$1"; }

# The D-Bus activation file the vr-talex installer wrote.
legacy_render_dbus_svc() {
  local svc
  svc=$(<"$REPO/packaging/org.fcitx.Fcitx5.service")
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
