#!/bin/bash
# vr-talex end-to-end stress harness (AC-2..AC-7, AC-10, SEC-1, SEC-29). See tests/e2e/README.md.
#
# usage: tests/e2e/run.sh [--smoke] [options]
#   --smoke              stub IME, apps "term chrome", 1 run, 60 words, scenarios "password toggle focus"
#   --ime stub|daemon|none   engine under test (default daemon = $VR_TALEX_BIN or target/release/vr-talex)
#   --apps "LIST"        from: term chrome omnibox code code-term (default: all five)
#   --runs N             runs per app (default 3)
#   --words N            corpus size (default 5000)
#   --seed N             corpus seed (default 20261124)
#   --delay S            seconds between keys (default 0.015)
#   --scenarios "LIST"   from: password toggle focus focus-kept suggest indicator install
#                        (default: password toggle focus focus-kept suggest install)
#   --skip-install       skip the install/uninstall scenario (also skipped while install.sh is absent)
#   --route ibus|fcitx   IM environment of the apps: Ubuntu default (ibus) or GTK_IM_MODULE=fcitx
#   --out DIR            where run directories go (default target/e2e)
#   --omnibox-chunk N    corpus lines per address-bar tab (default 40; Chrome caps a tab's history)
#   --allow-incomplete   exit 0 even when some checks are SKIP or INCOMPLETE (they are still listed)
# Exit status: 0 when every RESULT line is PASS (SKIP/INCOMPLETE only with --allow-incomplete), 1 otherwise,
# 97 when the sandbox guard trips. Any SKIP/INCOMPLETE prints a loud "INCOMPLETE: <checks>" line.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

IME=daemon APPS="term chrome omnibox code code-term" RUNS=3 WORDS=5000 SEED=20261124 DELAY=0.015
SCENARIOS="password toggle focus focus-kept suggest install" SKIP_INSTALL=0 ROUTE=ibus OUT="$REPO/target/e2e"
ALLOW_INCOMPLETE=0 OMNI_CHUNK=40
while [ $# -gt 0 ]; do
  case "$1" in
    --smoke) IME=stub APPS="term chrome" RUNS=1 WORDS=60 SCENARIOS="password toggle focus"; SKIP_INSTALL=1;;
    --ime) IME="$2"; shift;;
    --apps) APPS="$2"; shift;;
    --runs) RUNS="$2"; shift;;
    --words) WORDS="$2"; shift;;
    --seed) SEED="$2"; shift;;
    --delay) DELAY="$2"; shift;;
    --scenarios) SCENARIOS="$2"; shift;;
    --skip-install) SKIP_INSTALL=1;;
    --route) ROUTE="$2"; shift;;
    --out) OUT="$2"; shift;;
    --omnibox-chunk) OMNI_CHUNK="$2"; shift;;
    --allow-incomplete) ALLOW_INCOMPLETE=1;;
    -h|--help) sed -n '2,21p' "$0"; exit 0;;
    *) echo "unknown option $1"; exit 2;;
  esac
  shift
done
GOLDEN="$REPO/crates/telex-core/tests/golden/telex_golden.tsv"
BIN="${VR_TALEX_BIN:-$REPO/target/release/vr-talex}"
E2E="python3 $HERE/e2e.py"

# ------------------------------------------------------------------ outer: build the sandbox, re-exec isolated
if [ "${E2E_INNER:-}" != 1 ]; then
  case "$IME" in stub|daemon|none) ;; *) echo "--ime must be stub, daemon or none"; exit 2;; esac
  if [ "$IME" = daemon ] && [ ! -x "$BIN" ]; then echo "daemon binary not found: $BIN (build it or use --ime stub)"; exit 2; fi
  for t in gnome-shell gdbus dbus-run-session python3; do
    command -v "$t" >/dev/null || { echo "missing tool: $t"; exit 2; }
  done
  RUN_DIR="$OUT/run-$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$RUN_DIR/logs" "$RUN_DIR/out"
  RUN_DIR="$(cd "$RUN_DIR" && pwd)"
  # Remember the live session bus (address and server id, a read-only GetId) so guard can refuse it
  # in any address form later.
  export E2E_LIVE_BUS="${DBUS_SESSION_BUS_ADDRESS:-}" E2E_LIVE_BUS_ID=""
  [ -n "$E2E_LIVE_BUS" ] && E2E_LIVE_BUS_ID="$(bus_id)"
  iso_env "$RUN_DIR/sandbox"
  export E2E_INNER=1 RUN_DIR LOGS="$RUN_DIR/logs" OUTD="$RUN_DIR/out" E2E_START="$(date +%s)"
  echo "e2e: run dir $RUN_DIR; ime=$IME apps=[$APPS] runs=$RUNS words=$WORDS delay=$DELAY scenarios=[$SCENARIOS] route=$ROUTE"
  dbus-run-session -- bash "$0" --ime "$IME" --apps "$APPS" --runs "$RUNS" --words "$WORDS" --seed "$SEED" \
    --delay "$DELAY" --scenarios "$SCENARIOS" --route "$ROUTE" --out "$OUT" --omnibox-chunk "$OMNI_CHUNK" \
    $([ "$SKIP_INSTALL" = 1 ] && echo --skip-install) $([ "$ALLOW_INCOMPLETE" = 1 ] && echo --allow-incomplete) \
    2>"$LOGS/stderr.log"
  rc=$?
  case "$E2E_RUNTIME" in /tmp/vrt-e2e.*) rm -rf -- "$E2E_RUNTIME";; esac
  echo "e2e: exit $rc; results in $OUTD/results.txt"
  exit $rc
fi

# ------------------------------------------------------------------ inner: isolated session
RESULTS="$OUTD/results.txt"; : > "$RESULTS"
result() {  # result <name> <PASS|FAIL|SKIP|INCOMPLETE> <detail>
  echo "RESULT $1 $2 $3" | tee -a "$RESULTS"
}
IME_PID=""
finish() {
  [ -n "$IME_PID" ] && kill -0 "$IME_PID" 2>/dev/null && kill -TERM "$IME_PID" 2>/dev/null
  cleanup
}
trap finish EXIT
guard
# GSettings go through a dconf activated on this private bus, as on the desktop: the keyfile backend
# rewrites the whole file from each process' cache, so any app's write can undo an install or uninstall
# that happened a moment before.
if [ "$IME" = none ]; then SRC="[('xkb', 'us')]"; else SRC="[('ibus', 'vr-talex')]"; fi
gsettings set org.gnome.desktop.input-sources sources "$SRC" || { echo "could not seed the input sources"; exit 1; }

if [ "$ROUTE" = fcitx ]; then export GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx XMODIFIERS=@im=fcitx SDL_IM_MODULE=fcitx
else export XMODIFIERS=@im=ibus; fi

start_shell || { result shell FAIL "headless gnome-shell did not start"; exit 1; }
echo "shell up: $(gnome-shell --version)"

start_ime() {
  guard
  case "$IME" in
    stub)
      python3 "$HERE/stub_ime.py" "$GOLDEN" "$XDG_RUNTIME_DIR/vr-talex-stub/bus" "$LOGS/ime.log" "$OUTD/latency.json" &
      IME_PID=$!;;
    daemon)
      RUST_LOG=trace "$BIN" >"$LOGS/daemon.stdout" 2>"$LOGS/daemon.stderr" &
      IME_PID=$!;;
    none) return 0;;
  esac
  local i st
  for i in $(seq 40); do
    st=$(sh_value "$IME_STATE")
    case "$st" in vr-talex\|VI|vr-talex\|EN) echo "ime ($IME) connected after ~$((i / 4)) s: $st"; return 0;; esac
    pause 0.25
  done
  echo "ime ($IME) not connected within 10 s: state [$st]"; return 1
}

# ensure_vi: put the engine in VI mode before a step (the indicator shows the mode, B6).
ensure_vi() {
  [ "$IME" = none ] && return 0
  [ "$(indicator)" = VI ] && return 0
  $E2E inject --keys TOGGLE >/dev/null; pause 0.3
  [ "$(indicator)" = VI ]
}

start_ime || { result ime FAIL "engine did not connect to the shell"; exit 1; }
NONCE="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
$E2E corpus --golden "$GOLDEN" --words "$WORDS" --seed "$SEED" --nonce "$NONCE" --out "$OUTD"
EXPECTED="$OUTD/expected.txt"
NLINES=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["lines"]))' "$OUTD/corpus.json")
if [ "$IME" = none ]; then  # without an engine the app receives the raw keys
  python3 - "$OUTD/corpus.json" "$EXPECTED" <<'EOF'
import json, sys
lines = json.load(open(sys.argv[1]))["lines"]
open(sys.argv[2], "w").write("".join(" ".join(s["k"] for s in ln) + "\n" for ln in lines))
EOF
fi

# inj: corpus injection; its output (with the measured mean ms/key) is kept for check().
INJ_LOG=""
inj() {
  local o
  o=$($E2E inject "$@")
  echo "$o"
  INJ_LOG="$INJ_LOG"$'\n'"$o"
}

check() {  # check <label> <actual file> [extra diff args]
  local label="$1" act="$2"; shift 2
  local out rate slow
  out=$($E2E diff "$EXPECTED" "$act" --label "$label" --report "$OUTD/diff-$label.txt" "$@")
  echo "$out" | sed -n '2,6p'
  rate=$(echo "$INJ_LOG" | grep -o 'mean [0-9.]* ms/key' | tr '\n' ' ')
  slow=$(echo "$INJ_LOG" | grep -c 'RATE TOO SLOW')
  [ -z "$rate" ] && slow=1 rate="no injection rate reported"
  INJ_LOG=""
  if [ "$slow" != 0 ]; then
    result "AC-2:$label" FAIL "$(echo "$out" | head -1 | cut -d: -f2-); injection slower than $DELAY s/key: $rate"
  else
    case "$out" in PASS*) result "AC-2:$label" PASS "$(echo "$out" | head -1 | cut -d: -f2-); $rate";;
                   *) result "AC-2:$label" FAIL "$(echo "$out" | head -1 | cut -d: -f2-); $rate (report diff-$label.txt)";; esac
  fi
}

# ------------------------------------------------------------------ local site (address-bar suggestions)
# The suggest scenario needs pages Chrome can load, so that its history offers them as inline
# suggestions: one stdlib HTTP server on 127.0.0.1, and Chrome maps a few host names onto it.
SITE_PORT="" SITE_HOSTS="github.test youtube.test tinhte.test xn--ng-pma05d708i.test"
start_site() {
  guard
  mkdir -p "$OUTD/site"
  printf '<!doctype html><meta charset=utf-8><title>e2e site</title>ok\n' > "$OUTD/site/index.html"
  python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$OUTD/site" >"$LOGS/site.log" 2>&1 &
  local i
  for i in $(seq 40); do
    SITE_PORT=$(grep -o 'port [0-9]*' "$LOGS/site.log" | head -1 | cut -d' ' -f2)
    [ -n "$SITE_PORT" ] && return 0
    pause 0.25
  done
  echo "local site did not start"; return 1
}
case " $SCENARIOS " in *" suggest "*) start_site;; esac

# ------------------------------------------------------------------ Chrome (one browser for every Chrome step)
CHROME_UP=0
PORTFILE="$HOME/chrome/DevToolsActivePort"
start_chrome() {
  [ "$CHROME_UP" = 1 ] && return 0
  guard
  local rules="" bypass="" h
  if [ -n "$SITE_PORT" ]; then
    for h in $SITE_HOSTS; do rules="${rules}MAP $h 127.0.0.1:$SITE_PORT, "; bypass="$bypass;$h"; done
    rules="${rules}MAP localhost 127.0.0.1, "
  fi
  cat > "$OUTD/page.html" <<'EOF'
<!doctype html><meta charset=utf-8><title>vr-talex e2e</title>
<style>textarea{width:95%;height:180px}#o{width:95%;height:160px;background:#eee}</style>
<textarea id=t></textarea><br><input id=p type=password autocomplete=off><br><div id=o tabindex=0>click target</div>
<script>
const t = document.getElementById('t'), p = document.getElementById('p'), o = document.getElementById('o');
window.keylog = [];
addEventListener('keydown', e => {
  if (e.ctrlKey && e.shiftKey && e.key.length === 1) { keylog.push(e.key.toUpperCase()); e.preventDefault(); }
}, true);
t.focus();
</script>
EOF
  # The proxy points at a closed local port and every host resolves to nothing: the omnibox
  # navigations carry the typed text and must never leave the machine.
  google-chrome --user-data-dir="$HOME/chrome" --no-first-run --no-default-browser-check --password-store=basic \
    --disable-search-engine-choice-screen --disable-sync --disable-background-networking --disable-component-update \
    --proxy-server=http://127.0.0.1:9 --proxy-bypass-list="${bypass#;}" \
    --host-resolver-rules="${rules}MAP * ~NOTFOUND" --remote-debugging-port=0 \
    "file://$OUTD/page.html" >"$LOGS/chrome.log" 2>&1 &
  CHROME_PID=$!
  wait_win google-chrome || return 1
  local i; for i in $(seq 40); do [ -s "$PORTFILE" ] && break; pause 0.25; done
  [ -s "$PORTFILE" ] || { echo "chrome: no DevToolsActivePort"; return 1; }
  CHROME_UP=1
}
page_eval() { $E2E cdp "$PORTFILE" eval page.html "$1"; }
page_front() { $E2E cdp "$PORTFILE" activate page.html >/dev/null; activate google-chrome; }

# ------------------------------------------------------------------ VS Code
CODE_UP=0
code_open() {  # code_open <file>
  guard
  mkdir -p "$HOME/code/User"
  cat > "$HOME/code/User/settings.json" <<EOF
{"workbench.startupEditor":"none","files.autoSave":"afterDelay","files.autoSaveDelay":200,"telemetry.telemetryLevel":"off",
 "update.mode":"none","extensions.autoCheckUpdates":false,"editor.wordBasedSuggestions":"off","editor.suggestOnTriggerCharacters":false,
 "editor.quickSuggestions":{"other":"off","comments":"off","strings":"off"},"editor.acceptSuggestionOnEnter":"off",
 "editor.autoClosingBrackets":"never","editor.autoClosingQuotes":"never","editor.autoIndent":"none","editor.formatOnType":false,
 "security.workspace.trust.enabled":false,"chat.commandCenter.enabled":false,"workbench.tips.enabled":false,
 "terminal.integrated.enablePersistentSessions":false,"terminal.integrated.shellIntegration.enabled":false,
 "terminal.integrated.profiles.linux":{"e2e":{"path":"bash","args":["-c","cat > \"\$E2E_CODE_TERM_FILE\""]}},
 "terminal.integrated.defaultProfile.linux":"e2e"}
EOF
  echo '[{"key":"f9","command":"workbench.action.terminal.new"}]' > "$HOME/code/User/keybindings.json"
  local flag=--reuse-window; [ "$CODE_UP" = 0 ] && flag=--new-window
  E2E_CODE_TERM_FILE="$OUTD/code-term.txt" code --user-data-dir="$HOME/code" --extensions-dir="$HOME/code-ext" \
    --disable-workspace-trust --skip-welcome --skip-release-notes --password-store=basic $flag "$1" >>"$LOGS/code.log" 2>&1 &
  wait_win com.microsoft.VSCode || return 1
  if [ "$CODE_UP" = 0 ]; then pause 4; else pause 1.5; fi
  CODE_UP=1
}

run_app() {  # run_app <app> <run>
  local app="$1" r="$2" act="$OUTD/$1-$2.txt" pid
  rm -f "$act"
  ensure_vi || { result "AC-2:$app-$r" FAIL "could not put the engine in VI mode"; return; }
  case "$app" in
    term)
      guard
      gnome-terminal --wait -- bash -c "cat > '$act'" >>"$LOGS/terminal.log" 2>&1 &
      pid=$!
      wait_win gnome-terminal-server || { result "AC-2:$app-$r" FAIL "terminal window did not appear"; return; }
      inj --corpus "$OUTD/corpus.json" --enter --delay "$DELAY" --keys down:Control_L d up:Control_L
      wait_gone "$pid" 30 || echo "terminal did not exit after Ctrl+D"
      check "$app-$r" "$act";;
    chrome)
      start_chrome || { result "AC-2:$app-$r" FAIL "chrome did not start"; return; }
      page_front; page_eval "t.value=''; t.focus(); 1" >/dev/null
      inj --corpus "$OUTD/corpus.json" --enter --delay "$DELAY"
      pause 1; page_eval "t.value" > "$act"
      check "$app-$r" "$act";;
    omnibox)
      start_chrome || { result "AC-2:$app-$r" FAIL "chrome did not start"; return; }
      # Chrome keeps a bounded session history per tab, so each chunk of lines gets its own tab
      # and its history is read back before the tab is closed.
      local lo tab n got
      : > "$act"
      for ((lo = 0; lo < NLINES; lo += OMNI_CHUNK)); do
        tab=$($E2E cdp "$PORTFILE" new about:blank); activate google-chrome; pause 1
        inj --corpus "$OUTD/corpus.json" --lines "$lo:$((lo + OMNI_CHUNK))" --omnibox --delay "$DELAY"
        pause 1.5; $E2E cdp "$PORTFILE" history "$tab" > "$OUTD/omnibox-chunk.txt"
        $E2E cdp "$PORTFILE" close "$tab" >/dev/null
        n=$(( NLINES - lo < OMNI_CHUNK ? NLINES - lo : OMNI_CHUNK )); got=$(wc -l < "$OUTD/omnibox-chunk.txt")
        [ "$got" = "$n" ] || echo "  omnibox chunk at line $lo: $got of $n searches read back"
        cat "$OUTD/omnibox-chunk.txt" >> "$act"
      done
      rm -f "$OUTD/omnibox-chunk.txt"
      check "$app-$r" "$act";;
    code)
      : > "$act"
      code_open "$act" || { result "AC-2:$app-$r" FAIL "VS Code window did not appear"; return; }
      inj --corpus "$OUTD/corpus.json" --enter --delay "$DELAY"
      wait_stable "$act" 20
      check "$app-$r" "$act";;
    code-term)
      rm -f "$OUTD/code-term.txt"
      if [ "$CODE_UP" = 0 ]; then : > "$OUTD/code-scratch.txt"; code_open "$OUTD/code-scratch.txt" || { result "AC-2:$app-$r" FAIL "VS Code window did not appear"; return; }; fi
      activate com.microsoft.VSCode
      $E2E inject --keys F9 SLEEP:3 >/dev/null
      inj --corpus "$OUTD/corpus.json" --enter --delay "$DELAY" --keys down:Control_L d up:Control_L
      wait_stable "$OUTD/code-term.txt" 20; mv -f "$OUTD/code-term.txt" "$act" 2>/dev/null
      check "$app-$r" "$act";;
    *) result "AC-2:$app-$r" FAIL "unknown app";;
  esac
}

echo "corpus: $NLINES lines; typing at $DELAY s/key"
for app in $APPS; do
  for r in $(seq "$RUNS"); do
    t0=$(date +%s); run_app "$app" "$r"; echo "  ($app run $r took $(( $(date +%s) - t0 )) s)"
  done
done

# ------------------------------------------------------------------ scenarios
golden_of() { awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$GOLDEN"; }
set_mode() {  # set_mode VI|EN (the tap reaches the engine only through a focused text field)
  local i
  for i in 1 2 3; do
    [ "$(indicator)" = "$1" ] && return 0
    page_front; page_eval "t.focus(); 1" >/dev/null
    $E2E inject --keys TOGGLE >/dev/null; pause 0.5
  done
  [ "$(indicator)" = "$1" ] && return 0
  echo "  set_mode $1: indicator [$(indicator)], focus [$(focused_class)]"; return 1
}
# word:key — type the word at a human pace, wait for the suggestion, then press the key; the address
# the tab ends on must be the one EN mode reaches. word:key=address[|address] — VI mode only
# (Vietnamese words): the tab must end on one of those addresses ("search:<query>" for a search).
# xn--ng-pma05d708i is "đường". E2E_SUGGEST_CASES / E2E_SUGGEST_VI_CASES replace the lists.
# word:key+key[+…] — the keys one after the other at the typing pace ("quick+" first: without waiting
# for the suggestion, "SLEEP:s" for a pause). Chrome decides what Tab then Enter does (in Chrome 157
# Tab moves to the row's "remove suggestion" button and Enter presses it: the page leaves the
# suggestions and the bar falls back to the typed letters); VI mode must end where EN mode ends.
SUGGEST_CASES="${E2E_SUGGEST_CASES-git:Return git:Tab you:Return you:Tab loc:Return loc:Tab tinh:Return tinh:Tab
  git:Tab+Return you:Tab+Return loc:Tab+Return tinh:Tab+Return git:quick+Tab+Return git:Tab+Tab+Return}"
SUGGEST_VI_CASES="${E2E_SUGGEST_VI_CASES-dduwowngf:Return=http://xn--ng-pma05d708i.test/
  dduw:Tab=http://xn--ng-pma05d708i.test/ tieengs:Return=search:tiếng vieetj:Return=search:việt}"
SUGGEST_DELAY=0.08

for sc in $SCENARIOS; do
  case "$sc" in
    password)  # AC-7: a password field receives the raw keys
      start_chrome || { result AC-7 FAIL "chrome did not start"; continue; }
      page_front; ensure_vi; page_eval "p.value=''; p.focus(); 1" >/dev/null
      $E2E inject --text matkhau1s --delay "$DELAY" >/dev/null; pause 0.5
      got=$(page_eval "p.value")
      [ "$got" = matkhau1s ] && result AC-7 PASS "password field got matkhau1s raw" \
                             || result AC-7 FAIL "password field got [$got], expected [matkhau1s]";;
    toggle)  # AC-4: Ctrl+Shift alone toggles within 100 ms; Ctrl+Shift+T/P/C/V do not and reach the app
      [ "$IME" = none ] && { result AC-4 SKIP "no engine"; continue; }
      start_chrome || { result AC-4 FAIL "chrome did not start"; continue; }
      page_front; page_eval "t.value=''; keylog.length=0; t.focus(); 1" >/dev/null
      # Give Ctrl+Shift+T a tab to reopen, so its delivery is visible as one more page.
      closed=$($E2E cdp "$PORTFILE" new about:blank); $E2E cdp "$PORTFILE" close "$closed" >/dev/null
      page_front; page_eval "t.focus(); 1" >/dev/null
      before=$($E2E cdp "$PORTFILE" count)
      out=$($E2E toggle-check); echo "$out"
      after=$($E2E cdp "$PORTFILE" count)
      page_front; klog=$(page_eval "keylog.join()")
      $E2E cdp "$PORTFILE" close-others page.html >/dev/null
      ok=1
      echo "$out" | grep -q '^toggle PASS' || ok=0
      echo "$out" | grep -q '^combos PASS' || ok=0
      for k in P C V; do case ",$klog," in *",$k,"*) ;; *) ok=0;; esac; done
      [ "$after" -gt "$before" ] || ok=0
      detail="$(echo "$out" | tr '\n' ';') page saw Ctrl+Shift+[$klog]; pages $before -> $after after Ctrl+Shift+T"
      [ "$ok" = 1 ] && result AC-4 PASS "$detail" || result AC-4 FAIL "$detail";;
    indicator)  # AC-4 as on the desktop: xkb layouts beside the engine, picked with the source switcher,
      # and a toggle typed in a terminal (the --route path: IBus through the shell, or the fcitx D-Bus
      # frontend) moves the indicator within 100 ms and switches what the terminal gets. D33: Ctrl+Space
      # to the US layout turns the IME off for that route too (word in progress committed, keys raw,
      # Ctrl+Shift inert); Ctrl+Space back turns it on in the kept mode.
      [ "$IME" = daemon ] || { result AC-4:indicator SKIP "needs the daemon (source switch, D33)"; continue; }
      gsettings set org.gnome.desktop.wm.keybindings switch-input-source "['<Control>space']"
      gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('xkb', 'vn'), ('ibus', 'vr-talex')]"
      pause 1
      sh_eval "Main.panel.statusArea.keyboard._inputSourceManager.inputSources[2].activate(true); 1" >/dev/null
      pause 1
      echo "indicator: after picking the engine [$(sh_value "$IME_STATE")] $(sh_value "$SHELL_IME_JS")"
      act="$OUTD/indicator-term.txt"; rm -f "$act"
      gnome-terminal --wait -- bash -c "cat > '$act'" >>"$LOGS/terminal.log" 2>&1 &
      pid=$!
      wait_win gnome-terminal-server || { result AC-4:indicator FAIL "terminal window did not appear"; continue; }
      ensure_vi
      $E2E inject --text "vieetj " --delay "$DELAY" >/dev/null
      out=$($E2E toggle-check --combo); echo "$out"
      $E2E inject --keys TOGGLE >/dev/null; pause 0.3; ind1=$(sh_value "$IME_STATE")
      $E2E inject --text "vieetj " --delay "$DELAY" >/dev/null
      $E2E inject --keys TOGGLE >/dev/null; pause 0.3; ind2=$(sh_value "$IME_STATE")
      # Ctrl+Space to the US layout, then raw typing and an inert Ctrl+Shift, in one input session:
      # each injection ends with a focus-out of the field (its virtual keyboard goes away).
      $E2E inject --text "vieetj " --delay "$DELAY" --keys down:Control_L space up:Control_L SLEEP:0.7 \
        j space a a space TOGGLE SLEEP:0.3 >/dev/null
      st4=$(sh_value "$IME_STATE"); off=$(sh_value "$SHELL_IME_JS")
      $E2E inject --keys down:Control_L space up:Control_L >/dev/null; pause 0.7
      st5=$(sh_value "$IME_STATE")
      $E2E inject --text "dd " --delay "$DELAY" >/dev/null
      echo "indicator: at the end $(sh_value "$SHELL_IME_JS")"
      $E2E inject --keys Return down:Control_L d up:Control_L >/dev/null
      wait_gone "$pid" 10 || echo "terminal did not exit after Ctrl+D"
      got=$(cat "$act" 2>/dev/null); exp="$(golden_of vieetj) vieetj $(golden_of vieetj) j aa đ "
      detail="route=$ROUTE; $(echo "$out" | head -1); indicator after typed toggles [$ind1, $ind2] expected [vr-talex|EN, vr-talex|VI]"
      detail="$detail; after Ctrl+Space and a Ctrl+Shift there [$st4] ($off), Ctrl+Space back [$st5] expected [us|EN] (source-symbol=vi), [vr-talex|VI]"
      detail="$detail; terminal got [$got] expected [$exp]"
      if echo "$out" | grep -q '^toggle PASS' && [ "$ind1,$ind2" = vr-talex\|EN,vr-talex\|VI ] && [ "$got" = "$exp" ] \
         && [ "$st4,$st5" = "us|EN,vr-talex|VI" ] && case "$off" in *engine=xkb:us::eng*source-symbol=vi) true;; *) false;; esac; then
        result AC-4:indicator PASS "$detail"
      else result AC-4:indicator FAIL "$detail"; fi;;
    focus)  # AC-3: a word in preedit is committed on window switch and on a click elsewhere
      [ "$IME" = none ] && { result AC-3 SKIP "no engine"; continue; }
      start_chrome || { result AC-3 FAIL "chrome did not start"; continue; }
      gnome-terminal --wait -- bash -c 'cat > /dev/null' >>"$LOGS/terminal.log" 2>&1 &
      wait_win gnome-terminal-server
      exp1=$(golden_of vieetj); exp2=$(golden_of dduwowngf)
      page_front; ensure_vi; page_eval "t.value=''; t.focus(); 1" >/dev/null
      $E2E inject --text vieetj --delay "$DELAY" >/dev/null
      activate gnome-terminal-server; pause 0.7
      got1=$(page_eval "t.value")
      page_front; page_eval "t.value=''; t.focus(); 1" >/dev/null
      xy=$(page_eval "(() => { const r = o.getBoundingClientRect(); return Math.round(window.screenX + (outerWidth - innerWidth) / 2 + r.x + r.width / 2) + ',' + Math.round(window.screenY + outerHeight - innerHeight + r.y + r.height / 2); })()")
      wx=$(sh_value "(() => { const w = global.display.focus_window; const r = w.get_frame_rect(); return r.x + ',' + r.y; })()")
      cx=$(( ${xy%,*} + ${wx%,*} )); cy=$(( ${xy#*,} + ${wx#*,} ))
      $E2E inject --text dduwowngf --delay "$DELAY" --keys "click:$cx,$cy" >/dev/null; pause 0.7
      got2=$(page_eval "t.value"); clicked=$(page_eval "document.activeElement.id")
      d1="window switch: [$got1] expected [$exp1]"; d2="click elsewhere (focus moved to #$clicked): [$got2] expected [$exp2]"
      if [ "$got1" = "$exp1" ] && [ "$got2" = "$exp2" ] && [ "$clicked" = o ]; then result AC-3 PASS "$d1; $d2"
      else result AC-3 FAIL "$d1; $d2"; fi;;
    suggest)  # FR-8: with an inline suggestion in the address bar, Enter goes to it and Tab accepts it,
              # in VI mode exactly as Chrome does in EN mode (no engine involvement)
      [ "$IME" = none ] && { result FR-8 SKIP "no engine"; continue; }
      [ -n "$SITE_PORT" ] || { result FR-8 FAIL "local site did not start"; continue; }
      start_chrome || { result FR-8 FAIL "chrome did not start"; continue; }
      # Two typed visits per page make each one an inline suggestion for its prefix.
      seed_history() {
        local tab u k
        tab=$($E2E cdp "$PORTFILE" new about:blank)
        for u in $(for h in $SITE_HOSTS; do echo "http://$h/"; done) "http://localhost:$SITE_PORT/"; do
          for k in 1 2; do $E2E cdp "$PORTFILE" navigate "$tab" "$u" >/dev/null; pause 0.7; done
        done
        $E2E cdp "$PORTFILE" close "$tab" >/dev/null; pause 1
      }
      seed_history
      # What kind of field the address bar reports (IBus purpose/hints, as GNOME Shell forwards them).
      tab=$($E2E cdp "$PORTFILE" new about:blank); activate google-chrome; pause 0.7
      $E2E inject --keys down:Control_L l up:Control_L SLEEP:0.5 >/dev/null
      purpose=$(sh_value 'Main.inputMethod._purpose + "/" + Main.inputMethod._hints')
      $E2E inject --keys Escape >/dev/null; $E2E cdp "$PORTFILE" close "$tab" >/dev/null
      declare -A seen=()
      ok=1 detail="address bar purpose/hints $purpose" bad=0
      for mode in EN VI; do
        set_mode "$mode" || { ok=0; detail="$detail; could not switch to $mode"; break; }
        cases=$SUGGEST_CASES; [ "$mode" = VI ] && cases="$cases $SUGGEST_VI_CASES"
        for c in $cases; do
          c=${c%%=*} word=${c%%:*} how=${c#*:}
          tab=$($E2E cdp "$PORTFILE" new about:blank); activate google-chrome; pause 0.7
          # One injection for the whole case: ending an injection removes its keyboard from the
          # seat, which takes the focus from the address bar and commits the word before the key
          # under test. Screenshots are taken alongside, in the pauses.
          keys=(down:Control_L l up:Control_L SLEEP:0.4)
          for ((j = 0; j < ${#word}; j++)); do keys+=("${word:j:1}"); done
          # Tab takes the suggestion and moves the focus to the suggestion list; Shift+Tab brings it
          # back unchanged and Return then goes to whatever Tab left in the address bar. A "+" list
          # is typed as written, key after key at the typing pace ("quick+" first: without waiting
          # for the suggestion either), as a user who accepts with Tab and presses Enter at once.
          case "$how" in
            quick+*) IFS=+ read -r -a seq <<< "${how#quick+}"; keys+=("${seq[@]}");;
            *+*) IFS=+ read -r -a seq <<< "$how"; keys+=(SLEEP:1.5 "${seq[@]}");;
            Tab) keys+=(SLEEP:1.5 Tab SLEEP:1.5 down:Shift_L Tab up:Shift_L SLEEP:0.4 Return);;
            *) keys+=(SLEEP:1.5 Return);;
          esac
          t=$(python3 -c "print(1.0 + 0.4 + ${#word} * $SUGGEST_DELAY)")
          ( pause "$t"; screenshot "$OUTD/suggest-$mode-$word-$how-1typed.png"
            case "$how" in Tab*) pause 1.5; screenshot "$OUTD/suggest-$mode-$word-$how-2tab.png";; esac ) &
          $E2E inject --delay "$SUGGEST_DELAY" --keys "${keys[@]}" >/dev/null
          wait $!
          pause 1.5
          seen[$mode:$c]=$($E2E cdp "$PORTFILE" url "$tab")
          $E2E cdp "$PORTFILE" close "$tab" >/dev/null
          echo "  suggest $mode $c -> ${seen[$mode:$c]}"
          # Enter on a row's button (reached with Tab) can remove that page from the suggestions:
          # the next case starts from the same history again.
          case "$how" in *+*) seed_history;; esac
        done
      done
      for c in $SUGGEST_CASES; do
        en=${seen[EN:$c]:-} vi=${seen[VI:$c]:-}
        # Without an inline suggestion in EN mode the case proves nothing: the setup is broken.
        # A key list is compared as it is: where it ends is Chrome's choice, and the single-key
        # cases already show that the suggestions are there.
        case "$c:$en" in
          *+*:?*) ;;
          *:search:*|*:|*:about:*) ok=0; detail="$detail; $c: no suggestion in EN mode [$en]"; continue;;
        esac
        [ "$en" = "$vi" ] || { ok=0; bad=$((bad + 1)); detail="$detail; $c: VI went to [$vi], EN to [$en]"; }
      done
      # Vietnamese words, which EN mode cannot type: VI must reach the expected address.
      for c in $SUGGEST_VI_CASES; do
        want=${c#*=} c=${c%%=*} vi=${seen[VI:${c%%=*}]:-}
        case "|$want|" in *"|$vi|"*) ;; *) ok=0; bad=$((bad + 1)); detail="$detail; $c: VI went to [$vi], expected [$want]";; esac
      done
      n=$(( $(echo $SUGGEST_CASES $SUGGEST_VI_CASES | wc -w) ))
      [ "$ok" = 1 ] && result FR-8 PASS "$detail; $n cases, VI = EN / expected" \
                    || result FR-8 FAIL "$detail; $bad of $n cases differ";;
    focus-kept)  # AC-3 with the keyboard kept through the focus change: a word in progress survives, once,
      # a window switch out of Chrome, and in gnome-terminal (GTK3 im-wayland, committed by Mutter through the
      # shell) a window switch, a click on another window and Ctrl+Space to the US layout. Each case runs
      # inside one injection: ending an injection removes the headless seat's only keyboard, and GTK3 drops
      # its preedit on that keyboard loss before Mutter's commit arrives (imwayland disable()), a path a
      # desktop with a keyboard does not take (FR-10).
      [ "$IME" = daemon ] || { result AC-3:kept SKIP "needs the daemon (Ctrl+Space source switch, D33)"; continue; }
      start_chrome || { result AC-3:kept FAIL "chrome did not start"; continue; }
      gsettings set org.gnome.desktop.wm.keybindings switch-input-source "['<Control>space']"
      gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('ibus', 'vr-talex')]"
      pause 1
      sh_eval "Main.panel.statusArea.keyboard._inputSourceManager.inputSources[1].activate(true); 1" >/dev/null
      pause 1
      act="$OUTD/focus-kept-term.txt"; rm -f "$act"
      gnome-terminal --wait -- bash -c "cat > '$act'" >>"$LOGS/terminal.log" 2>&1 &
      pid=$!
      wait_win gnome-terminal-server || { result AC-3:kept FAIL "terminal window did not appear"; continue; }
      # Side by side, so a click can land on the other window.
      place() { sh_eval "global.get_window_actors().map(a => a.meta_window).filter(w => w.get_wm_class() == '$1').forEach(w => { w.unmaximize(3); w.move_resize_frame(false, $2, 40, 620, 700); }); 1" >/dev/null; }
      to() { echo "EVAL:global.get_window_actors().map(a => a.meta_window).filter(w => w.get_wm_class() == '$1').forEach(w => w.activate(global.get_current_time())); 1"; }
      place gnome-terminal-server 0; place google-chrome 650; pause 0.5
      w1=$(golden_of vieetj); w2=$(golden_of dduwowngf)
      # Chrome: window switch to the terminal mid-word (the terminal must not get the word).
      page_front; ensure_vi; page_eval "t.value=''; t.focus(); 1" >/dev/null
      $E2E inject --text vieetj --delay "$DELAY" --keys "$(to gnome-terminal-server)" SLEEP:0.7 >/dev/null
      gotc=$(page_eval "t.value")
      # gnome-terminal: switch to Chrome and back, click on Chrome and switch back, Ctrl+Space to US (raw
      # "aa" right after the word) and back. Chrome's field must stay empty.
      page_eval "t.value=''; 1" >/dev/null
      activate gnome-terminal-server; ensure_vi
      $E2E inject --text vieetj --delay "$DELAY" --keys "$(to google-chrome)" SLEEP:0.7 "$(to gnome-terminal-server)" \
        SLEEP:0.5 space >/dev/null
      $E2E inject --text dduwowngf --delay "$DELAY" --keys click:960,400 SLEEP:0.7 "$(to gnome-terminal-server)" \
        SLEEP:0.5 space >/dev/null
      $E2E inject --text vieetj --delay "$DELAY" --keys down:Control_L space up:Control_L SLEEP:0.7 a a space \
        down:Control_L space up:Control_L SLEEP:0.7 >/dev/null
      st=$(sh_value "$IME_STATE"); other=$(page_eval "t.value")
      $E2E inject --keys Return down:Control_L d up:Control_L >/dev/null
      wait_gone "$pid" 10 || echo "terminal did not exit after Ctrl+D"
      got=$(cat "$act" 2>/dev/null); exp="$w1 $w2 ${w1}aa "
      gsettings set org.gnome.desktop.input-sources sources "$SRC"; pause 1
      d1="chrome window switch: [$gotc] expected [$w1]"
      d2="terminal (switch, click on another window, Ctrl+Space): [$got] expected [$exp]; chrome field meanwhile [$other] expected []; source after Ctrl+Space back [$st] expected [vr-talex|VI]"
      [ "$gotc" = "$w1" ] && result AC-3:chrome-kept PASS "$d1" || result AC-3:chrome-kept FAIL "$d1"
      if [ "$got" = "$exp" ] && [ -z "$other" ] && [ "$st" = "vr-talex|VI" ]; then result AC-3:term PASS "$d2"
      else result AC-3:term FAIL "$d2"; fi;;
    install)  # AC-5 / AC-6: install-then-type and uninstall inside the sandbox
      if [ "$SKIP_INSTALL" = 1 ]; then result AC-5/AC-6 SKIP "--skip-install"; continue; fi
      if [ ! -x "$REPO/install.sh" ] || [ ! -x "$REPO/uninstall.sh" ]; then
        result AC-5/AC-6 SKIP "install.sh / uninstall.sh not present yet (T8)"; continue; fi
      . "$HERE/install_scenario.sh"; install_scenario;;
    *) result "$sc" FAIL "unknown scenario";;
  esac
done

# ------------------------------------------------------------------ latency (AC-10)
if [ -n "$IME_PID" ] && kill -0 "$IME_PID" 2>/dev/null; then kill -TERM "$IME_PID"; wait_gone "$IME_PID" 10; fi
case "$IME" in
  stub) out=$($E2E latency "$OUTD/latency.json"); echo "$out"
        # The stub's own handling time: proves the reporting path, says nothing about the product.
        case "$out" in *PASS*) result AC-10:stub PASS "${out#latency }";; *) result AC-10:stub FAIL "${out#latency }";; esac;;
  # D24: the daemon has no timing interface; AC-10 is proven by the ime-core latency test and the
  # fe-ibus / fe-fcitx round-trip tests, so the e2e run can only mark it incomplete.
  daemon) result AC-10 INCOMPLETE "measured in unit tests (D24: ime-core latency test, fe-ibus/fe-fcitx round-trip tests)";;
  none) result AC-10 INCOMPLETE "no engine";;
esac

# ------------------------------------------------------------------ SEC-1 leak scan
LEAK_FILES=""
for f in "$LOGS/ime.log" "$LOGS/daemon.stderr" "$LOGS/daemon.stdout" "$LOGS/shell.log" "$LOGS/systemd.log" "$LOGS/stderr.log" "$LOGS"/unit-*.log; do
  [ -f "$f" ] && LEAK_FILES="$LEAK_FILES $f"
done
out=$($E2E leakscan --tokens "$OUTD/tokens.txt" --since "$E2E_START" --root "$HOME" "$XDG_RUNTIME_DIR" --tmp \
      --exclude "$HOME/chrome" "$HOME/code" "$HOME/code-ext" "$HOME/.vscode" --file $LEAK_FILES)
rc=$?
echo "$out"
case "$rc" in
  0) result SEC-1 PASS "$(echo "$out" | head -1)";;
  2) result SEC-1 INCOMPLETE "$(echo "$out" | head -1)";;  # no hits, but a journal could not be read
  *) result SEC-1 FAIL "$(echo "$out" | tr '\n' ';')";;
esac

summarize "$RESULTS" "$ALLOW_INCOMPLETE"
