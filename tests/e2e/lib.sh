# Shared helpers for tests/e2e/run.sh. Sourced, not executed.
# Everything runs in a throwaway session (D2, SEC-29): own D-Bus session bus (dbus-run-session),
# own HOME / XDG_* / XDG_RUNTIME_DIR under the run directory, keyfile GSettings. Never the live desktop.

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
LIVE_RUNTIME="/run/user/$(id -u)"

pause() { python3 -c 'import sys, time; time.sleep(float(sys.argv[1]))' "$1"; }

# iso_env <sandbox dir>: point every per-user location into the sandbox and drop live-session values.
iso_env() {
  SB="$1"
  mkdir -p "$SB"
  # Wayland socket paths must fit in 108 bytes, so the runtime dir is a short private dir in /tmp
  # (mode 0700, removed by run.sh at the end); $SB/runtime links to it.
  E2E_RUNTIME="$(mktemp -d /tmp/vrt-e2e.XXXXXX)"; ln -sfn "$E2E_RUNTIME" "$SB/runtime"
  export XDG_RUNTIME_DIR="$E2E_RUNTIME" E2E_RUNTIME
  export HOME="$SB/home" XDG_CONFIG_HOME="$SB/home/.config" XDG_DATA_HOME="$SB/home/.local/share" \
         XDG_STATE_HOME="$SB/home/.local/state" XDG_CACHE_HOME="$SB/home/.cache" \
         GSETTINGS_BACKEND=keyfile XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=ubuntu:GNOME NO_AT_BRIDGE=1 \
         VRT_E2E_TAG="vrt-e2e-$$-$(date +%s)" E2E_SANDBOX="$SB"
  unset WAYLAND_DISPLAY DISPLAY DBUS_SESSION_BUS_ADDRESS GTK_IM_MODULE QT_IM_MODULE XMODIFIERS SDL_IM_MODULE \
        IBUS_ADDRESS IBUS_ADDRESS_FILE GNOME_SETUP_DISPLAY XAUTHORITY SESSION_MANAGER SSH_AUTH_SOCK \
        GNOME_KEYRING_CONTROL DBUS_SYSTEM_BUS_ADDRESS_OVERRIDE
  mkdir -p "$HOME/.config/glib-2.0/settings" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR" "$HOME"
}

# bus_id: server id of the current session bus (read-only GetId), empty when unreachable.
bus_id() {
  timeout 5 gdbus call --session -d org.freedesktop.DBus -o /org/freedesktop/DBus -m org.freedesktop.DBus.GetId 2>/dev/null \
    | sed -E "s/^\('([0-9a-f]+)',\)$/\1/"
}

# summarize <results file> <allow incomplete 0|1>: print the summary and the loud INCOMPLETE line;
# status 0 only when nothing failed and (nothing was skipped or incomplete, or that was allowed).
summarize() {
  local res="$1" allow="$2" inc
  echo "---- summary"
  cat "$res"
  inc=$(awk '$1 == "RESULT" && ($3 == "SKIP" || $3 == "INCOMPLETE") { printf "%s ", $2 }' "$res")
  inc="${inc% }"
  if [ -n "$inc" ]; then
    echo "INCOMPLETE: $inc$([ "$allow" = 1 ] && echo ' (allowed by --allow-incomplete)')"
  fi
  grep -q '^RESULT [^ ]* FAIL' "$res" && return 1
  [ -n "$inc" ] && [ "$allow" != 1 ] && return 1
  return 0
}

# guard: abort when anything still points at the live desktop (SEC-29). Called before every launch.
guard() {
  local bad=""
  [ "$HOME" = "$LIVE_HOME" ] && bad="HOME"
  [ "$XDG_RUNTIME_DIR" = "$LIVE_RUNTIME" ] && bad="$bad XDG_RUNTIME_DIR"
  [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && bad="$bad DBUS_SESSION_BUS_ADDRESS(empty)"
  case "${DBUS_SESSION_BUS_ADDRESS:-}" in *"$LIVE_RUNTIME/bus"*) bad="$bad DBUS_SESSION_BUS_ADDRESS";; esac
  # The live bus in any address form (path, abstract, tmpdir): the address recorded before sandboxing,
  # and the live bus' server id compared with the id of the bus in use.
  [ -n "${E2E_LIVE_BUS:-}" ] && [ "${DBUS_SESSION_BUS_ADDRESS:-}" = "$E2E_LIVE_BUS" ] && bad="$bad DBUS_SESSION_BUS_ADDRESS=live"
  if [ -n "${E2E_LIVE_BUS_ID:-}" ] && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ "$(bus_id)" = "$E2E_LIVE_BUS_ID" ]; then
    bad="$bad session-bus-id=live"
  fi
  case "$HOME" in "$E2E_SANDBOX"/*) ;; *) bad="$bad HOME-outside-sandbox";; esac
  case "$XDG_CONFIG_HOME" in "$E2E_SANDBOX"/*) ;; *) bad="$bad XDG_CONFIG_HOME";; esac
  case "$XDG_RUNTIME_DIR" in "$E2E_RUNTIME") [ -O "$XDG_RUNTIME_DIR" ] || bad="$bad XDG_RUNTIME_DIR-not-ours";; *) bad="$bad XDG_RUNTIME_DIR-not-the-sandbox-one";; esac
  if [ -n "$bad" ]; then echo "GUARD: live desktop values in use ($bad), abort"; exit 97; fi
}

start_shell() {
  guard
  python3 "$E2E_DIR/fake_systemd.py" "$LOGS/systemd.log" &
  gdbus wait --session --timeout 10 org.freedesktop.systemd1 || { echo "fake systemd did not start"; return 1; }
  gnome-shell --headless --wayland --virtual-monitor 1280x800 --unsafe-mode >"$LOGS/shell.log" 2>&1 &
  SHELL_PID=$!
  gdbus wait --session --timeout 30 org.gnome.Mutter.RemoteDesktop || { echo "shell did not come up"; tail -20 "$LOGS/shell.log"; return 1; }
  gdbus wait --session --timeout 30 org.gnome.Shell || return 1
  export WAYLAND_DISPLAY=wayland-0
  # The bus name appears before the Shell object is exported; retry Eval for up to 30 s.
  local i
  for i in $(seq 60); do
    case "$(sh_eval "Main.overview.hide(); 1" 2>/dev/null)" in "(true"*) return 0;; esac
    pause 0.5
  done
  echo "shell Eval not available"; return 1
}

# sh_eval <js>: run JS in the throwaway shell (unsafe mode); prints gdbus' "(true, 'result')".
sh_eval() { gdbus call --session -d org.gnome.Shell -o /org/gnome/Shell -m org.gnome.Shell.Eval "$1"; }

# Unquoted result of sh_eval.
sh_value() { sh_eval "$1" | sed -E "s/^\(true, '\"?//; s/\"?'\)$//"; }

IME_STATE='[Main.inputMethod._currentSource?.id ?? "", Object.values(Main.panel.statusArea.keyboard._indicatorLabels ?? {}).map(l => l.text).join()].join("|")'
indicator() { sh_value "Object.values(Main.panel.statusArea.keyboard._indicatorLabels ?? {}).map(l => l.text).join()"; }

# wait_win <wm_class>: bounded wait (30 s) until a window of that class has a real size, then focus it.
wait_win() {
  local i r
  for i in $(seq 60); do
    r=$(sh_eval "global.get_window_actors().map(a => a.meta_window).filter(w => w.get_wm_class() == '$1' && w.get_frame_rect().width > 0).map(w => { w.activate(global.get_current_time()); return w.has_focus(); }).join()")
    case "$r" in *\"true*) pause 1; return 0;; esac
    pause 0.5
  done
  echo "window $1 not focused within 30 s: $r"; return 1
}

activate() {  # activate <wm_class>
  sh_eval "global.get_window_actors().map(a => a.meta_window).filter(w => w.get_wm_class() == '$1').map(w => { w.activate(global.get_current_time()); return w.has_focus(); }).join()" >/dev/null
  pause 0.5
}

focused_class() { sh_value 'global.display.focus_window?.get_wm_class() ?? ""'; }

screenshot() { gdbus call --session -d org.gnome.Shell.Screenshot -o /org/gnome/Shell/Screenshot -m org.gnome.Shell.Screenshot.Screenshot false false "$1" >/dev/null 2>&1; }

# wait_stable <file> <timeout s>: wait until the file exists and its size stops changing for 1 s.
wait_stable() {
  local f="$1" left=$(( $2 * 4 )) last=-1 same=0 size
  while [ "$left" -gt 0 ]; do
    size=$(stat -c %s "$f" 2>/dev/null || echo -1)
    if [ "$size" = "$last" ] && [ "$size" != -1 ]; then same=$((same + 1)); [ "$same" -ge 4 ] && return 0; else same=0; fi
    last=$size; left=$((left - 1)); pause 0.25
  done
  return 1
}

# wait_gone <pid> <timeout s>
wait_gone() {
  local left=$(( $2 * 4 ))
  while [ "$left" -gt 0 ] && kill -0 "$1" 2>/dev/null; do pause 0.25; left=$((left - 1)); done
  ! kill -0 "$1" 2>/dev/null
}

# cleanup: stop exactly the processes carrying this run's tag (the harness' own children), nothing else.
cleanup() {
  local p pids=""
  # The shell first, so it does not abort on a vanished bus while the rest is stopped.
  if [ -n "${SHELL_PID:-}" ] && kill -0 "$SHELL_PID" 2>/dev/null; then kill -TERM "$SHELL_PID"; wait_gone "$SHELL_PID" 10; fi
  for p in /proc/[0-9]*; do
    [ -r "$p/environ" ] || continue
    if grep -qz "^VRT_E2E_TAG=$VRT_E2E_TAG\$" "$p/environ" 2>/dev/null; then
      case "${p#/proc/}" in "$$"|"$BASHPID"|"$PPID") ;; *) pids="$pids ${p#/proc/}";; esac
    fi
  done
  [ -n "$pids" ] && kill -TERM $pids 2>/dev/null
  pause 1.5
  for p in $pids; do [ -d "/proc/$p" ] && kill -KILL "$p" 2>/dev/null; done
  echo "cleanup: stopped $(echo $pids | wc -w) tagged processes"
}
