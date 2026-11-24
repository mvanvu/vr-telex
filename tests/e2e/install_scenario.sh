# AC-5 / AC-6: install-then-type and uninstall, inside the isolated session. Sourced by run.sh
# (needs lib.sh and run.sh: result, E2E, IME_PID, BIN, DELAY, LOGS, OUTD, RUN_DIR, REPO, start_chrome, page_*). install.sh / uninstall.sh come from T8.
#
# The sandbox has no systemd user manager, so a `systemctl` stand-in on PATH runs the unit's ExecStart
# itself (tagged, so cleanup stops it). Process-killing-by-name tools are replaced by stand-ins that
# refuse and log: inside the sandbox they would still reach the live desktop's processes (SEC-29).

write_shims() {
  SHIM="$RUN_DIR/shims"; mkdir -p "$SHIM"
  for t in pkill killall; do
    printf '#!/bin/bash\necho "%s refused by the e2e sandbox: $*" >> "%s/shims.log"\nexit 1\n' "$t" "$LOGS" > "$SHIM/$t"
  done
  cat > "$SHIM/systemctl" <<EOF
#!/bin/bash
# systemctl stand-in for the e2e sandbox (user units only).
LOG="$LOGS/shims.log"; UNITS="\$XDG_CONFIG_HOME/systemd/user"; STATE="$SHIM/state"; mkdir -p "\$STATE"
echo "systemctl \$*" >> "\$LOG"
user=0 now=0 verb="" prop="" units=() next=""
for a in "\$@"; do
  if [ "\$next" = p ]; then prop=\$a; next=""; continue; fi
  case "\$a" in
    --user) user=1;; --now) now=1;; -p) next=p;; --property=*) prop=\${a#--property=};;
    --*|-q) ;;
    *) if [ -z "\$verb" ]; then verb=\$a; else units+=("\${a%.service}"); fi;;
  esac
done
[ "\$user" = 1 ] || { echo "system manager refused by the e2e sandbox" >&2; exit 1; }
start() {
  local f="\$UNITS/\$1.service"; [ -f "\$f" ] || { echo "Unit \$1.service not found." >&2; return 5; }
  local cmd; cmd=\$(sed -n 's/^ExecStart=//p' "\$f" | head -1 | sed "s|%h|\$HOME|g")
  [ -f "\$STATE/\$1.pid" ] && kill -0 "\$(cat "\$STATE/\$1.pid")" 2>/dev/null && return 0
  # Shell-parse the line so a quoted binary path (as the unit writes it) runs as the binary it names.
  local argv; eval "argv=(\$cmd)"
  "\${argv[@]}" >>"$LOGS/unit-\$1.log" 2>&1 < /dev/null &
  echo \$! > "\$STATE/\$1.pid"
}
# Like real systemctl, stop returns only once the process is gone (bounded wait, then SIGKILL).
stop() {
  local p i; [ -f "\$STATE/\$1.pid" ] && p=\$(cat "\$STATE/\$1.pid")
  rm -f "\$STATE/\$1.pid"
  [ -n "\$p" ] || return 0
  kill -TERM "\$p" 2>/dev/null
  for i in \$(seq 50); do kill -0 "\$p" 2>/dev/null || return 0; sleep 0.1; done
  kill -KILL "\$p" 2>/dev/null; sleep 0.2; return 0
}
rc=0
case "\$verb" in
  daemon-reload|reset-failed|import-environment|set-environment|unset-environment) ;;
  start) for u in "\${units[@]}"; do start "\$u" || rc=\$?; done;;
  restart|reload-or-restart|try-restart) for u in "\${units[@]}"; do stop "\$u"; start "\$u" || rc=\$?; done;;
  stop|kill) for u in "\${units[@]}"; do stop "\$u"; done;;
  enable) for u in "\${units[@]}"; do touch "\$STATE/\$u.enabled"; [ "\$now" = 1 ] && { start "\$u" || rc=\$?; }; done;;
  disable) for u in "\${units[@]}"; do rm -f "\$STATE/\$u.enabled"; [ "\$now" = 1 ] && stop "\$u"; done;;
  is-active) for u in "\${units[@]}"; do [ -f "\$STATE/\$u.pid" ] && kill -0 "\$(cat "\$STATE/\$u.pid")" 2>/dev/null || rc=3; done;;
  is-enabled) for u in "\${units[@]}"; do [ -f "\$STATE/\$u.enabled" ] || rc=1; done;;
  show) for u in "\${units[@]}"; do
          case "\$prop" in
            MainPID) p=0; [ -f "\$STATE/\$u.pid" ] && kill -0 "\$(cat "\$STATE/\$u.pid")" 2>/dev/null && p=\$(cat "\$STATE/\$u.pid"); echo "\$p";;
            *) echo "";;
          esac
        done;;
  status|cat|list-units|list-unit-files) rc=3;;
  *) echo "unsupported verb \$verb" >&2; rc=1;;
esac
exit \$rc
EOF
  chmod +x "$SHIM"/*
}

sources() { gsettings get org.gnome.desktop.input-sources sources; }

# The running shell's current input source and its top-bar label, read from the input source
# manager itself (D33: what the user sees, not what the settings say): "type:id|label".
CUR_SRC_JS="(k => [(k._inputSourceManager?.currentSource?.type ?? '') + ':' + (k._inputSourceManager?.currentSource?.id ?? ''), $CUR_LABEL_JS].join('|'))(Main.panel.statusArea.keyboard)"
cur_src() { sh_value "$CUR_SRC_JS"; }

# Wait (up to 10 s) until the shell's current source is vr-talex with the indicator on vi; prints the
# last state seen. Labels are compared case-insensitively (D32 made them lower case).
wait_vr_selected() {
  local i st=""
  for i in $(seq 40); do
    st=$(cur_src)
    case "${st,,}" in "ibus:vr-talex|vi") break;; esac
    pause 0.25
  done
  printf '%s' "$st"
  case "${st,,}" in "ibus:vr-talex|vi") return 0;; esac
  return 1
}

# footprint: hash of every file the installer may touch (apps' profiles excluded), plus the sources.
# The IBus address files are left out: every daemon start rewrites them with its pid, and a re-run
# restarts the daemon on purpose (D33).
footprint() {
  (cd "$HOME" && find . -path ./chrome -prune -o -path ./code -prune -o -path ./code-ext -prune -o -path ./.cache -prune \
     -o -path ./.config/ibus/bus -prune -o -type f -print0 | sort -z | xargs -0 sha256sum; sources) | sha256sum | cut -c1-16
}

type_in_new_terminal() {  # type_in_new_terminal <keys> <out file>
  gnome-terminal --wait -- bash -c "cat > '$2'" >>"$LOGS/terminal.log" 2>&1 &
  local pid=$!
  wait_win gnome-terminal-server || return 1
  $E2E inject --text "$1" --keys Return down:Control_L d up:Control_L >/dev/null
  wait_gone "$pid" 15
}

install_scenario() {
  guard
  # The scenario never builds: a build inside the sandbox would need the user's ~/.cargo (and write to it).
  if [ ! -x "$BIN" ]; then
    result AC-5/AC-6 INCOMPLETE "needs a built daemon (cargo build --release, or VR_TALEX_BIN); the scenario does not build"
    return
  fi
  write_shims
  # Start from the AC-5 precondition: no vr-talex, sources [('xkb','us')], fcitx5 running when installed here.
  if [ -n "$IME_PID" ] && kill -0 "$IME_PID" 2>/dev/null; then kill -TERM "$IME_PID"; wait_gone "$IME_PID" 10; fi
  rm -f "$XDG_CONFIG_HOME"/ibus/bus/*
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
  local had_fcitx=0
  if command -v fcitx5 >/dev/null; then
    fcitx5 >"$LOGS/fcitx5.log" 2>&1 &
    gdbus wait --session --timeout 10 org.fcitx.Fcitx5 && had_fcitx=1
  fi
  local before; before=$(sources)
  # VR_TALEX_BIN is T8's seam (install this binary, skip the build); CARGO_HOME/RUSTUP_HOME point into the
  # sandbox so nothing can reach the live toolchain dirs even if a build were attempted.
  local tool_env=(PATH="$SHIM:$PATH" VR_TALEX_BIN="$BIN" CARGO_HOME="$HOME/.cargo" RUSTUP_HOME="$HOME/.rustup")
  local rc t_end ready st i ok5=1 d5=""
  (cd "$REPO" && env "${tool_env[@]}" ./install.sh) >"$LOGS/install-1.log" 2>&1; rc=$?
  t_end=$(date +%s.%N)
  for i in $(seq 40); do st=$(sh_value "$IME_STATE"); case "$st" in vr-talex\|*) break;; esac; pause 0.25; done
  ready=$(python3 -c 'import sys, time; print(f"{time.time() - float(sys.argv[1]):.1f}")' "$t_end")
  # AC-5: Vietnamese works within 5 s of the install finishing.
  d5="install rc=$rc; engine connected to the shell [$st] ${ready} s after install returned (limit 5 s)"
  [ "$rc" = 0 ] || ok5=0
  case "$st" in vr-talex\|*) ;; *) ok5=0;; esac
  # D33: the running shell's current source is Vietnamese (Telex) and the indicator shows vi.
  local cur
  if cur=$(wait_vr_selected); then d5="$d5; shell current source after install [$cur]"
  else d5="$d5; shell current source after install [$cur] expected [ibus:vr-talex|vi]"; ok5=0; fi
  # BASE-48 asks for the 'current' key too; GNOME 46 marks it "deprecated and ignored" and the shell
  # never writes it, so it is recorded for the reader, not judged.
  d5="$d5; gsettings current=$(gsettings get org.gnome.desktop.input-sources current 2>&1) (deprecated, not written by the shell)"
  grep -qi selected "$LOGS/install-1.log" && { d5="$d5; install printed 'selected' (BASE-48)"; ok5=0; }
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= 5.0 else 1)' "$ready" || ok5=0
  local after; after=$(sources)
  local n; n=$(echo "$after" | grep -o "'vr-talex'" | wc -l)
  d5="$d5; sources $before -> $after ($n x vr-talex)"; [ "$n" = 1 ] || ok5=0
  ensure_vi
  type_in_new_terminal vieetj "$OUTD/install-term.txt"
  local got; got=$(cat "$OUTD/install-term.txt" 2>/dev/null)
  d5="$d5; new terminal typed [$got] expected [việt]"; [ "$got" = "việt" ] || ok5=0
  # A newly opened Chrome too (AC-5 names both): restart the harness' Chrome if an earlier step opened it.
  if [ "$CHROME_UP" = 1 ]; then kill -TERM "$CHROME_PID" 2>/dev/null; wait_gone "$CHROME_PID" 10; CHROME_UP=0; rm -f "$PORTFILE"; fi
  local gotc=""
  if start_chrome; then
    page_front; ensure_vi; page_eval "t.value=''; t.focus(); 1" >/dev/null
    $E2E inject --text "vieetj " --delay "$DELAY" >/dev/null; pause 0.5
    gotc=$(page_eval "t.value")
  fi
  d5="$d5; new Chrome typed [$gotc] expected [việt ]"; [ "$gotc" = "việt " ] || ok5=0
  # D33, source already present: replay the live state FR-7 found — the shell on English (US) while
  # mru-sources in the settings still starts with vr-talex (the shell keeps its MRU list in memory).
  # The switch is made inside the throwaway shell only; install.sh itself never uses Eval.
  sh_eval "Object.values(Main.panel.statusArea.keyboard._inputSourceManager.inputSources).find(s => s.type === 'xkb').activate(true); 1" >/dev/null
  pause 0.5
  local mru_set; mru_set=$(gsettings get org.gnome.desktop.input-sources mru-sources)
  gsettings set org.gnome.desktop.input-sources mru-sources "[('ibus', 'vr-talex'), $(echo "$mru_set" | sed -E "s/^\[//; s/\]$//; s/\('ibus', 'vr-talex'\)(, )?//; s/, $//")]"
  local pre2; pre2=$(cur_src)
  local fp1 fp2
  fp1=$(footprint)
  (cd "$REPO" && env "${tool_env[@]}" ./install.sh) >"$LOGS/install-2.log" 2>&1
  fp2=$(footprint)
  d5="$d5; second install changed files: $([ "$fp1" = "$fp2" ] && echo no || echo YES)"; [ "$fp1" = "$fp2" ] || ok5=0
  if cur=$(wait_vr_selected); then d5="$d5; second install with the shell on [$pre2] -> current [$cur]"
  else d5="$d5; second install with the shell on [$pre2] -> current [$cur] expected [ibus:vr-talex|vi]"; ok5=0; fi
  d5="$d5; gsettings current=$(gsettings get org.gnome.desktop.input-sources current 2>&1)"
  [ "$ok5" = 1 ] && result AC-5 PASS "$d5" || result AC-5 FAIL "$d5"

  (cd "$REPO" && env "${tool_env[@]}" ./uninstall.sh) >"$LOGS/uninstall.log" 2>&1; rc=$?
  local ok6=1 d6 restored
  restored=$(sources)
  d6="uninstall rc=$rc; sources back to $restored (before install: $before)"; [ "$restored" = "$before" ] || ok6=0
  if [ "$had_fcitx" = 1 ]; then
    gdbus wait --session --timeout 10 org.fcitx.Fcitx5 && d6="$d6; fcitx5 owns org.fcitx.Fcitx5 again" \
      || { d6="$d6; fcitx5 not running again"; ok6=0; }
  else d6="$d6; fcitx5 not installed here, framework restore not checked"; fi
  d6="$d6; refused kill-by-name calls: $(grep -c refused "$LOGS/shims.log" 2>/dev/null || echo 0)"
  [ "$ok6" = 1 ] && result AC-6 PASS "$d6" || result AC-6 FAIL "$d6"
}
