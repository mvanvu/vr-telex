# shellcheck shell=bash
# Shared by install.sh and uninstall.sh (sourced, never run on its own).
#
# Everything here writes only under $HOME and talks only to the user's own
# session bus and systemd user manager (SEC-20). Processes are stopped only
# through systemctl --user or fcitx5's own quit request, never by name
# (SEC-23).

SCHEMA=org.gnome.desktop.input-sources
VR_SOURCE="('ibus', 'vr-talex')"
UNIT=vr-talex.service
FCITX_NAME=org.fcitx.Fcitx5
FCITX_UNIT=fcitx5.service
IBUS_GNOME_UNIT=org.freedesktop.IBus.session.GNOME.service
TIMEOUT=${VR_TALEX_TIMEOUT:-10}

say() { printf 'vr-talex: %s\n' "$*"; }
warn() { printf 'vr-talex: warning: %s\n' "$*" >&2; }
die() {
  printf 'vr-talex: error: %s\n' "$*" >&2
  exit 1
}

require_user() {
  if [ "$(id -u)" -eq 0 ]; then
    printf 'vr-talex: error: do not run as root or with sudo; run it as your own user\n' >&2
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
    '' | *[!0-9]*) die "VR_TALEX_TIMEOUT must be a number of seconds" ;;
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

  # The unit runs %h/.local/bin/vr-talex, so this path does not follow XDG.
  BIN_DST=$HOME/.local/bin/vr-talex
  case "$BIN_DST" in
    *'"'* | *'\'*) die "HOME contains a double quote or backslash, which the D-Bus service file cannot hold" ;;
  esac
  UNIT_DIR=$CONFIG_HOME/systemd/user
  UNIT_DST=$UNIT_DIR/$UNIT
  WANTS_DIR=$UNIT_DIR/graphical-session.target.wants
  ENV_DST=$CONFIG_HOME/environment.d/90-vr-talex.conf
  XINPUTRC=$HOME/.xinputrc
  AUTOSTART_DST=$CONFIG_HOME/autostart/org.fcitx.Fcitx5.desktop
  DBUS_SVC_DST=$DATA_HOME/dbus-1/services/org.fcitx.Fcitx5.service
  IBUS_BUS_DIR=$CONFIG_HOME/ibus/bus
  STATE_DIR=$DATA_HOME/vr-talex
  BACKUP_DIR=$STATE_DIR/backup
  MANIFEST=$BACKUP_DIR/manifest
  DAEMON_STATE_DIR=$STATE_HOME/vr-talex

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
  pid=$(systemctl --user show -p MainPID --value "$UNIT" 2>/dev/null) || pid=0
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

# A source list without the vr-talex entry.
without_vr() {
  local items
  items=$(list_items "$1")
  items=${items//"$VR_SOURCE, "/}
  items=${items//", $VR_SOURCE"/}
  items=${items//"$VR_SOURCE"/}
  if [ -z "$items" ]; then printf '@a(ss) []'; else printf '[%s]' "$items"; fi
}

# Restore one key. When it still holds what install wrote, the saved value
# comes back; when the user changed it since (a layout added, another
# source selected), only the vr-talex entry is taken out.
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
  tmp=$(mktemp -d "$dir/.vr-talex-tmp.XXXXXX") || return 1
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
  saved="$dst.vr-talex-saved-$(date +%Y%m%d-%H%M%S)"
  if exists "$saved"; then saved="$saved-$$"; fi
  mv -T -- "$dst" "$saved" || return 1
  warn "$dst was changed after install; your version is kept as $saved"
}

# Record what install wrote, so uninstall can tell the user's later edits
# from its own files.
record_installed() {
  local r
  r=$(rel "$1")
  mkdir -p -- "$BACKUP_DIR/installed/$(dirname -- "$r")" &&
    cp -a -- "$1" "$BACKUP_DIR/installed/$r"
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
      warn "$dst was not written by vr-talex; left in place"
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
  local i rel dst vr_pid f d key
  RESTORE_FAILED=()
  load_manifest

  # Input sources first, so the shell leaves the vr-talex source while the
  # daemon still answers; mru-sources before sources, because gnome-shell
  # activates the head of the MRU list when sources changes.
  for key in mru-sources sources; do
    for i in "${!M_GS_KEYS[@]}"; do
      [ "${M_GS_KEYS[$i]}" = "$key" ] || continue
      gs_restore "$key" "${M_GS_VALS[$i]}" "$(installed_gs "$key")" ||
        RESTORE_FAILED+=("input sources ($key)")
    done
  done

  vr_pid=$(unit_pid)
  if systemctl --user is-enabled --quiet "$UNIT" 2>/dev/null || systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
    systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || warn "could not stop $UNIT"
  fi

  for rel in "${M_ABSENT[@]}"; do restore_entry "$rel" absent; done
  for rel in "${M_PRESENT[@]}"; do restore_entry "$rel" present; done

  # IBus address files vr-talex published that did not exist before.
  if [ -d "$IBUS_BUS_DIR" ]; then
    for f in "$IBUS_BUS_DIR"/*; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      in_list "$(rel "$f")" "${M_PRESENT[@]}" && continue
      if { [ "$vr_pid" != 0 ] && grep -qx "IBUS_DAEMON_PID=$vr_pid" "$f"; } ||
        grep -q "^IBUS_ADDRESS=unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vr-talex/" "$f"; then
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
  rm -rf -- "${DATA_HOME:?}/vr-talex/backup"
  # Directories install created, deepest first; non-empty ones stay.
  for d in "${M_DIRS[@]}" "$(rel "$DAEMON_STATE_DIR")"; do
    printf '%s\t%s\n' "$(tr -cd / <<<"$d" | wc -c)" "$d"
  done | sort -rn | cut -f2- | while IFS= read -r d; do
    rmdir -- "$HOME/$d" 2>/dev/null || true
  done
}

print_recovery() {
  say "if typing stops working: run 'systemctl --user disable --now vr-talex.service', then '$REPO/uninstall.sh'"
}
