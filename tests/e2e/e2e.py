#!/usr/bin/env python3
"""e2e harness helpers (Python 3 stdlib only). Subcommands:

  corpus   --golden TSV --words N --seed S --nonce X --out DIR
           writes DIR/corpus.json (lines of typed segments), DIR/expected.txt, DIR/tokens.txt
  inject   [--corpus JSON --lines A:B [--enter]] [--text STR] [--keys SPEC...] [--delay S]
           types through Mutter RemoteDesktop on the current (isolated) session bus
  cdp      PORTFILE list | eval URLPART JS | navigate TAB URL | url TAB | ...
           Chrome DevTools: list page URLs, or evaluate JS in the first page whose URL contains URLPART
  diff     EXPECTED ACTUAL --label L --report FILE
           character-exact comparison; report lists the first mismatches with context
  leakscan --tokens FILE --since EPOCH --root DIR... --exclude DIR... --file F...
           SEC-1: typed words must not appear in the journal, daemon stderr or any written file
  latency  STATS_JSON
"""
import argparse
import base64
import difflib
import json
import os
import random
import socket
import struct
import subprocess
import sys
import time
import unicodedata
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dbuslite as d  # noqa: E402

# ---------------------------------------------------------------- corpus

VI_SECTIONS_SKIP = ("English",)


def read_golden(path):
    sections, cur = {}, None
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("# ") and "[" in line:
                cur = line[2:].split("[")[0].strip()
                sections[cur] = []
            elif not line.startswith("#") and "\t" in line and cur:
                keys, exp = line.rstrip("\n").split("\t", 1)
                sections[cur].append((keys, exp))
    return sections


def usable(keys, exp):
    # Only letters: digits/punctuation are word boundaries and would split the word.
    return keys.isascii() and keys.isalpha() and " " not in exp


def cmd_corpus(a):
    rng = random.Random(a.seed)
    sections = read_golden(a.golden)
    vi = [p for name, rows in sections.items() if not name.startswith(VI_SECTIONS_SKIP) for p in rows if usable(*p)]
    en = [p for name, rows in sections.items() if name.startswith(VI_SECTIONS_SKIP) for p in rows if usable(*p)]
    # A word typed in VI mode must come out as listed; drop keys whose expected text is ambiguous.
    seen = {}
    for k, e in vi:
        seen.setdefault(k, e)
    vi = [(k, e) for k, e in vi if seen[k] == e]
    canaries = [f"vrtcanary{a.nonce}{i:02d}q" for i in range(a.canaries)]
    lines, total, ci = [], 0, 0
    while total < a.words:
        n = min(rng.randint(8, 14), a.words - total)
        segs = []
        i = 0
        while i < n:
            if ci < len(canaries) and rng.random() < 0.06:
                segs.append({"m": "EN", "k": canaries[ci], "e": canaries[ci]})
                ci += 1
            elif rng.random() < 0.2:
                for _ in range(min(rng.randint(1, 3), n - i)):
                    k, _e = rng.choice(en)
                    segs.append({"m": "EN", "k": k, "e": k})
                    i += 1
                continue
            else:
                k, e = rng.choice(vi)
                segs.append({"m": "VI", "k": k, "e": e})
            i += 1
        lines.append(segs)
        total += n
    # Canaries not placed yet go on a last line so every one is typed.
    rest = [{"m": "EN", "k": c, "e": c} for c in canaries[ci:]]
    if rest:
        lines.append(rest)
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "corpus.json"), "w", encoding="utf-8") as f:
        json.dump({"seed": a.seed, "words": total, "lines": lines}, f, ensure_ascii=False)
    with open(os.path.join(a.out, "expected.txt"), "w", encoding="utf-8") as f:
        f.write("".join(line_text(s) + "\n" for s in lines))
    # Leak-scan tokens: every canary, plus distinctive Vietnamese words (composed and raw keys).
    vi_words = sorted({(s["e"], s["k"]) for ln in lines for s in ln if s["m"] == "VI"},
                      key=lambda p: (-sum(not ch.isascii() for ch in p[0]), -len(p[0]), p[0]))
    picked = [p for p in vi_words if len(p[1]) >= 6][:a.scan_words]
    with open(os.path.join(a.out, "tokens.txt"), "w", encoding="utf-8") as f:
        for c in canaries:
            f.write(c + "\n")
        for e, k in picked:
            f.write(e + "\n" + k + "\n")
    print(f"corpus: {total} words in {len(lines)} lines, {sum(s['m'] == 'EN' for ln in lines for s in ln)} typed in EN "
          f"mode, {len(canaries)} canaries, {len(picked)} scan words, seed {a.seed}")


def line_text(segs):
    return " ".join(s["e"] for s in segs)


def line_keys(segs):
    """Key plan for one line; starts and ends in VI mode. 'T' = Ctrl+Shift tap."""
    out, mode = [], "VI"
    for i, s in enumerate(segs):
        if i:
            out.append(("t", " "))
        if s["m"] != mode:
            out.append(("toggle", None))
            mode = s["m"]
        out.append(("t", s["k"]))
    if mode != "VI":
        out.append(("toggle", None))
    return out


# ---------------------------------------------------------------- injection

NAMED = {"Control_L": 0xFFE3, "Control_R": 0xFFE4, "Shift_L": 0xFFE1, "Shift_R": 0xFFE2, "Alt_L": 0xFFE9,
         "Super_L": 0xFFEB, "Return": 0xFF0D, "Tab": 0xFF09, "BackSpace": 0xFF08, "Escape": 0xFF1B,
         "space": 0x20, "grave": 0x60, "Left": 0xFF51, "Right": 0xFF53, "Home": 0xFF50, "End": 0xFF57, "F9": 0xFFC6}


def keysym(ch):
    if ch == "\n":
        return 0xFF0D
    if ch == "\t":
        return 0xFF09
    o = ord(ch)
    return o if 0x20 <= o <= 0x7E or 0xA0 <= o <= 0xFF else 0x01000000 + o


def spec_keysym(name):
    return NAMED[name] if name in NAMED else keysym(name)


class Injector:
    SI = "org.gnome.Mutter.RemoteDesktop.Session"

    def __init__(self, delay):
        self.delay = delay
        self.conn = d.Connection.session()
        (self.session,) = self.conn.call("org.gnome.Mutter.RemoteDesktop", "/org/gnome/Mutter/RemoteDesktop",
                                         "org.gnome.Mutter.RemoteDesktop", "CreateSession")
        self.conn.call("org.gnome.Mutter.RemoteDesktop", self.session, self.SI, "Start")
        time.sleep(0.5)
        # The first event of a new virtual keyboard is not delivered (spike T1, Q2): warm up with Shift.
        self.sym(0xFFE1, True)
        self.sym(0xFFE1, False)
        time.sleep(0.3)
        self.keys = 0
        self.t0 = time.monotonic()
        self.reset_pacing()

    def reset_pacing(self):
        self.deadline = None
        self.tap_s = 0.0
        self.taps = 0

    def sym(self, ks, down):
        self.conn.call("org.gnome.Mutter.RemoteDesktop", self.session, self.SI, "NotifyKeyboardKeysym", "ub",
                       (ks, down))

    def tap(self, ks):
        # Paced on a fixed schedule (one key every `delay`), so the D-Bus call cost is absorbed instead of
        # added; after a gap (toggle, pause) the schedule restarts from now.
        start = time.monotonic()
        if self.deadline is None or start - self.deadline > self.delay:
            self.deadline = start
        self.sym(ks, True)
        self.sym(ks, False)
        self.keys += 1
        self.deadline += self.delay
        rest = self.deadline - time.monotonic()
        if rest > 0:
            time.sleep(rest)
        self.tap_s += time.monotonic() - start
        self.taps += 1

    def mean_ms(self):
        return self.tap_s * 1000 / max(self.taps, 1)

    def rate_ok(self):
        # AC-2 asks for 15 ms per key; allow 1 ms of jitter over the requested delay.
        return self.taps == 0 or self.mean_ms() <= self.delay * 1000 + 1.0

    def text(self, s):
        for ch in s:
            self.tap(keysym(ch))

    def toggle_raw(self):
        # Ctrl+Shift tapped alone (B4): press both, release both, nothing in between.
        for ks, down in ((0xFFE3, True), (0xFFE1, True), (0xFFE1, False), (0xFFE3, False)):
            self.sym(ks, down)
            time.sleep(0.01)

    def toggle(self):
        self.toggle_raw()
        self.keys += 1
        time.sleep(max(self.delay, 0.03))

    def spec(self, sp):
        """TOGGLE | SLEEP:s | EVAL:js | down:Key | up:Key | click:X,Y | Key (tap; a char or a NAMED key)."""
        if sp == "TOGGLE":
            return self.toggle()
        kind, _, arg = sp.partition(":")
        if arg and kind == "SLEEP":
            return time.sleep(float(arg))
        if arg and kind == "EVAL":
            # Shell JS run inside the session (e.g. a window switch): the virtual keyboard stays, so the
            # focus change is the only thing that happens to a word in progress. Ending the session
            # instead removes the headless seat's only keyboard, and GTK3 im-wayland clients then drop
            # the preedit before the compositor's commit reaches them.
            if shell_eval(self.conn, arg) is None:
                print(f"inject: EVAL failed: {arg}", file=sys.stderr)
            return None
        if arg and kind in ("down", "up"):
            self.sym(spec_keysym(arg), kind == "down")
            time.sleep(0.02)
            return None
        if arg and kind == "click":
            x, y = (int(v) for v in arg.split(","))
            return self.click(x, y)
        return self.tap(spec_keysym(sp))

    def click(self, x, y):
        # Relative motion only (absolute motion needs a screen-cast stream): park the pointer in the
        # top-left corner, then move to the target and press the left button.
        rel = "NotifyPointerMotionRelative"
        self.conn.call("org.gnome.Mutter.RemoteDesktop", self.session, self.SI, rel, "dd", (-10000.0, -10000.0))
        time.sleep(0.05)
        self.conn.call("org.gnome.Mutter.RemoteDesktop", self.session, self.SI, rel, "dd", (float(x), float(y)))
        time.sleep(0.05)
        for down in (True, False):
            self.conn.call("org.gnome.Mutter.RemoteDesktop", self.session, self.SI, "NotifyPointerButton", "ib",
                           (0x110, down))
            time.sleep(0.03)

    def close(self):
        dt = time.monotonic() - self.t0
        time.sleep(0.3)
        self.conn.call("org.gnome.Mutter.RemoteDesktop", self.session, self.SI, "Stop")
        return dt


def cmd_inject(a):
    inj = Injector(a.delay)
    if a.corpus:
        with open(a.corpus, encoding="utf-8") as f:
            lines = json.load(f)["lines"]
        lo, hi = (int(x) for x in a.lines.split(":"))
        for segs in lines[lo:hi]:
            if a.omnibox:
                # Ctrl+L focuses and selects the address bar; Return then runs the line as a search.
                inj.spec("down:Control_L")
                inj.tap(ord("l"))
                inj.spec("up:Control_L")
                time.sleep(0.3)
            for kind, val in line_keys(segs):
                inj.toggle() if kind == "toggle" else inj.text(val)
            if a.enter or a.omnibox:
                inj.tap(0xFF0D)
            if a.omnibox:
                time.sleep(0.8)
            if a.line_pause:
                time.sleep(a.line_pause)
    if a.text is not None:
        inj.text(a.text)
    for sp in a.keys or []:
        inj.spec(sp)
    dt = inj.close()
    ok = inj.rate_ok()
    print(f"inject: {inj.keys} keys in {dt * 1000:.0f} ms; mean {inj.mean_ms():.1f} ms/key over {inj.taps} taps "
          f"(target {a.delay * 1000:.1f}) {'RATE OK' if ok else 'RATE TOO SLOW'}")
    sys.exit(0 if ok else 3)


# ---------------------------------------------------------------- Chrome DevTools (stdlib WebSocket)

def cdp_targets(portfile):
    with open(portfile) as f:
        port = int(f.readline().strip())
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=5) as r:
        return port, [t for t in json.load(r) if t.get("type") == "page"]


class WebSocket:
    def __init__(self, url):
        hostport, _, path = url[len("ws://"):].partition("/")
        host, _, port = hostport.partition(":")
        self.s = socket.create_connection((host, int(port)), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET /{path} HTTP/1.1\r\nHost: {hostport}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = self.s.recv(4096)
            if not chunk:
                raise ConnectionError("websocket handshake failed")
            resp += chunk
        if b" 101 " not in resp.split(b"\r\n")[0]:
            raise ConnectionError(resp.split(b"\r\n")[0].decode())
        self.buf = resp.split(b"\r\n\r\n", 1)[1]

    def send(self, text):
        data = text.encode()
        mask = os.urandom(4)
        n = len(data)
        head = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else
                                bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else
                                bytes([0x80 | 127]) + struct.pack(">Q", n))
        self.s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _need(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise ConnectionError("websocket closed")
            self.buf += chunk

    def recv(self):
        parts = []
        while True:
            self._need(2)
            b0, b1 = self.buf[0], self.buf[1]
            n, off = b1 & 0x7F, 2
            if n == 126:
                self._need(4)
                n, off = struct.unpack(">H", self.buf[2:4])[0], 4
            elif n == 127:
                self._need(10)
                n, off = struct.unpack(">Q", self.buf[2:10])[0], 10
            self._need(off + n)
            payload, self.buf = self.buf[off:off + n], self.buf[off + n:]
            parts.append(payload)
            if b0 & 0x80:
                return b"".join(parts).decode()


def cdp_page(portfile, ref):
    """A page target by id or by a part of its URL."""
    _port, pages = cdp_targets(portfile)
    page = next((p for p in pages if p.get("id") == ref), None) or \
        next((p for p in pages if ref in p.get("url", "")), None)
    if page is None:
        raise SystemExit(f"cdp: no page {ref!r} among {len(pages)} pages")
    return page


def cdp_call(portfile, ref, method, params=None):
    ws = WebSocket(cdp_page(portfile, ref)["webSocketDebuggerUrl"])
    ws.send(json.dumps({"id": 1, "method": method, "params": params or {}}))
    while True:
        msg = json.loads(ws.recv())
        if msg.get("id") == 1:
            if "error" in msg:
                raise SystemExit(f"cdp: {method} failed: {msg['error'].get('message')}")
            return msg.get("result", {})


def cdp_http(portfile, path, method="GET"):
    with open(portfile) as f:
        port = int(f.readline().strip())
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method)
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.read().decode()


def cmd_cdp(a):
    w, pf = a.what, a.portfile
    if w == "list":
        for p in cdp_targets(pf)[1]:
            print(p.get("url", ""))
    elif w == "count":
        print(len(cdp_targets(pf)[1]))
    elif w == "eval":
        res = cdp_call(pf, a.args[0], "Runtime.evaluate", {"expression": a.args[1], "returnByValue": True})
        v = res.get("result", {}).get("value")
        sys.stdout.write(v if isinstance(v, str) else json.dumps(v, ensure_ascii=False))
    elif w == "new":
        print(json.loads(cdp_http(pf, "/json/new?" + urllib.parse.quote(a.args[0], safe=":/"), "PUT"))["id"])
    elif w == "close":
        cdp_http(pf, "/json/close/" + a.args[0])
    elif w == "activate":
        cdp_http(pf, "/json/activate/" + cdp_page(pf, a.args[0])["id"])
    elif w == "close-others":
        keep = cdp_page(pf, a.args[0])["id"]
        for p in cdp_targets(pf)[1]:
            if p["id"] != keep:
                cdp_http(pf, "/json/close/" + p["id"])
    elif w == "navigate":
        # A "typed" visit, as if entered in the address bar: it makes the URL an inline suggestion.
        cdp_call(pf, a.args[0], "Page.navigate", {"url": a.args[1], "transitionType": "typed"})
    elif w == "url":
        # The tab's current URL (where the address bar sent it); a search as "search:<query>",
        # because its other parameters change from one search to the next.
        hist = cdp_call(pf, a.args[0], "Page.getNavigationHistory")
        entries = hist.get("entries", [])
        idx = hist.get("currentIndex", len(entries) - 1)
        url = entries[idx].get("url", "") if 0 <= idx < len(entries) else ""
        u = urllib.parse.urlsplit(url)
        q = urllib.parse.parse_qs(u.query).get("q")
        print(f"search:{q[0]}" if u.path.endswith("/search") and q else url)
    elif w == "history":
        # Each omnibox line became one search navigation; its q parameter is the text Chrome received.
        hist = cdp_call(pf, a.args[0], "Page.getNavigationHistory")
        for e in hist.get("entries", []):
            u = urllib.parse.urlsplit(e.get("url", ""))
            q = urllib.parse.parse_qs(u.query).get("q")
            if u.path.endswith("/search") and q:
                print(q[0])


# ---------------------------------------------------------------- diff

def cmd_diff(a):
    with open(a.expected, encoding="utf-8") as f:
        exp = f.read()
    try:
        with open(a.actual, encoding="utf-8", errors="replace") as f:
            act = f.read()
    except FileNotFoundError:
        act = ""
    if a.strip_final_newline:
        exp, act = exp.rstrip("\n"), act.rstrip("\n")
    lost = extra = replaced = 0
    report = []
    if exp != act:
        sm = difflib.SequenceMatcher(None, exp, act, autojunk=False)
        for op, i1, i2, j1, j2 in sm.get_opcodes():
            if op == "equal":
                continue
            if op == "delete":
                lost += i2 - i1
            elif op == "insert":
                extra += j2 - j1
            else:
                replaced += max(i2 - i1, j2 - j1)
            if len(report) < a.max_report:
                line = exp.count("\n", 0, i1) + 1
                col = i1 - (exp.rfind("\n", 0, i1) + 1) + 1
                ctx = exp[max(0, i1 - 20):i1].replace("\n", "|")
                report.append(f"  line {line} col {col} {op}: after [{ctx}] expected [{exp[i1:i2]}] "
                              f"got [{act[j1:j2]}]".replace("\n", "|"))
    ok = exp == act
    summary = (f"{'PASS' if ok else 'FAIL'} {a.label}: expected {len(exp)} chars, got {len(act)}; "
               f"lost {lost}, extra {extra}, replaced {replaced}")
    with open(a.report, "w", encoding="utf-8") as f:
        f.write(summary + "\n" + "\n".join(report) + ("\n" if report else ""))
    print(summary)
    for r in report[:5]:
        print(r)
    sys.exit(0 if ok else 1)


# ---------------------------------------------------------------- SEC-1 leak scan

def cmd_leakscan(a):
    with open(a.tokens, encoding="utf-8") as f:
        toks = [t for t in f.read().split("\n") if t]
    needles = set()
    for t in toks:
        for form in ("NFC", "NFD"):
            needles.add(unicodedata.normalize(form, t).encode())
    excl = [os.path.realpath(x) for x in a.exclude or []]
    hits, scanned = [], 0

    def scan_bytes(label, data):
        for n in needles:
            if n in data:
                hits.append(f"{label}: contains a typed token ({len(n)} bytes)")
                return

    paths = list(a.file or [])
    if a.tmp:
        # Files of this user in /tmp touched since the run started (a daemon must not write there at all).
        for dp, dns, fns in os.walk("/tmp"):
            dns[:] = [x for x in dns if os.access(os.path.join(dp, x), os.R_OK | os.X_OK)]
            for fn in fns:
                p = os.path.join(dp, fn)
                try:
                    st = os.lstat(p)
                except OSError:
                    continue
                if st.st_uid == os.getuid() and st.st_mtime >= (a.since or 0):
                    paths.append(p)
    for root in a.root or []:
        for dp, dns, fns in os.walk(root):
            rp = os.path.realpath(dp)
            if any(rp == e or rp.startswith(e + os.sep) for e in excl):
                dns[:] = []
                continue
            for fn in fns:
                p = os.path.join(dp, fn)
                if os.path.realpath(p) not in excl:
                    paths.append(p)
    for p in paths:
        try:
            st = os.lstat(p)
            if not os.path.isfile(p) or os.path.islink(p) or st.st_size > 256 * 1024 * 1024:
                continue
            with open(p, "rb") as f:
                scan_bytes(p, f.read())
            scanned += 1
        except OSError:
            continue
    jlines, unreadable = 0, []
    if a.since:
        for scope in (["--user"], []):
            name = "user" if scope else "system"
            try:
                r = subprocess.run(["journalctl", *scope, "--since", f"@{int(a.since)}", "--no-pager", "-o", "cat"],
                                   capture_output=True, timeout=60)
            except (OSError, subprocess.TimeoutExpired):
                unreadable.append(name)
                continue
            # A journal that cannot be read must not pass as a clean scan.
            if r.returncode != 0:
                unreadable.append(name)
            jlines += r.stdout.count(b"\n")
            scan_bytes(f"journal({name})", r.stdout)
    note = "".join(f"; {n} journal unreadable" for n in unreadable)
    print(f"SEC-1 leak scan: {len(toks)} tokens, {scanned} files, {jlines} journal lines since the run started, "
          f"{len(hits)} hits{note}")
    for h in hits:
        print("  LEAK " + h)
    sys.exit(1 if hits else 2 if unreadable else 0)


def cmd_latency(a):
    try:
        with open(a.stats) as f:
            s = json.load(f)
    except (OSError, ValueError):
        print("latency: no timing source (stats file missing)")
        return
    verdict = "PASS" if s.get("p99_us") is not None and s["p99_us"] < 5000 else "FAIL"
    print(f"latency ({s.get('source')}): {s.get('keys')} keys, p50 {s.get('p50_us')} us, p99 {s.get('p99_us')} us, "
          f"max {s.get('max_us')} us -> {verdict} (AC-10: p99 < 5000 us)")


# The current source's label only (same expression as lib.sh CUR_LABEL_JS): with more than one source
# the panel holds one label per source. Upper-cased: the engine shows "vi"/"en" (D32), MODES are upper case.
INDICATOR_JS = ('(k => k._indicatorLabels?.[k._inputSourceManager?.currentSource?.index]?.text ?? "")'
                '(Main.panel.statusArea.keyboard).toUpperCase()')


def shell_eval(conn, js):
    try:
        ok, res = conn.call("org.gnome.Shell", "/org/gnome/Shell", "org.gnome.Shell", "Eval", "s", (js,))
    except (d.DBusError, OSError):
        return None
    return res.strip('"') if ok else None


MODES = ("VI", "EN")


def judge_toggle(before, now, ms):
    """A toggle passes only with two readable, different modes seen within 100 ms."""
    return before in MODES and now in MODES and now != before and ms < 100


def judge_combo(before, after):
    """Ctrl+Shift+<key> passes only when the mode was readable before and after and did not change."""
    return before in MODES and after in MODES and before == after


def cmd_toggle_check(a):
    """AC-4 timing and shortcut checks, from inside one RemoteDesktop session."""
    inj = Injector(0.03)
    shell = d.Connection.session()
    start = shell_eval(shell, INDICATOR_JS)
    times, ok = [], True
    for _ in range(2):
        before = shell_eval(shell, INDICATOR_JS)
        inj.toggle_raw()
        t0 = time.monotonic()
        now = before
        while now == before and time.monotonic() - t0 < 1.0:
            now = shell_eval(shell, INDICATOR_JS)
        ms = (time.monotonic() - t0) * 1000
        times.append(f"{before}->{now} {ms:.0f} ms")
        ok = judge_toggle(before, now, ms) and ok
        time.sleep(0.2)
    print(f"toggle {'PASS' if ok else 'FAIL'}: " + ", ".join(times))
    bad = []
    for key in a.combo:
        before = shell_eval(shell, INDICATOR_JS)
        for ks, down in ((0xFFE3, True), (0xFFE1, True), (keysym(key), True), (keysym(key), False),
                         (0xFFE1, False), (0xFFE3, False)):
            inj.sym(ks, down)
            time.sleep(0.02)
        time.sleep(0.4)
        after = shell_eval(shell, INDICATOR_JS)
        if not judge_combo(before, after):
            bad.append(f"Ctrl+Shift+{key} changed {before}->{after}")
    print(f"combos {'PASS' if not bad else 'FAIL'}: Ctrl+Shift+{'/'.join(a.combo)} left the mode at {start}"
          + ("" if not bad else "; " + "; ".join(bad)))
    inj.close()


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("corpus")
    c.add_argument("--golden", required=True)
    c.add_argument("--words", type=int, default=5000)
    c.add_argument("--seed", type=int, default=20261124)
    c.add_argument("--nonce", required=True)
    c.add_argument("--canaries", type=int, default=20)
    c.add_argument("--scan-words", type=int, default=20)
    c.add_argument("--out", required=True)
    i = sub.add_parser("inject")
    i.add_argument("--corpus")
    i.add_argument("--lines", default="0:999999")
    i.add_argument("--enter", action="store_true")
    i.add_argument("--omnibox", action="store_true")
    i.add_argument("--line-pause", type=float, default=0.0)
    i.add_argument("--text")
    i.add_argument("--keys", nargs="*")
    i.add_argument("--delay", type=float, default=0.015)
    x = sub.add_parser("cdp")
    x.add_argument("portfile")
    x.add_argument("what", choices=["list", "count", "eval", "new", "close", "activate", "close-others", "history",
                                    "navigate", "url"])
    x.add_argument("args", nargs="*")
    f = sub.add_parser("diff")
    f.add_argument("expected")
    f.add_argument("actual")
    f.add_argument("--label", required=True)
    f.add_argument("--report", required=True)
    f.add_argument("--max-report", type=int, default=20)
    f.add_argument("--strip-final-newline", action="store_true")
    s = sub.add_parser("leakscan")
    s.add_argument("--tokens", required=True)
    s.add_argument("--since", type=float)
    s.add_argument("--root", nargs="*")
    s.add_argument("--exclude", nargs="*")
    s.add_argument("--file", nargs="*")
    s.add_argument("--tmp", action="store_true")
    tc = sub.add_parser("toggle-check")
    tc.add_argument("--combo", nargs="*", default=["P", "C", "V", "T"])
    lt = sub.add_parser("latency")
    lt.add_argument("stats")
    a = p.parse_args()
    {"corpus": cmd_corpus, "inject": cmd_inject, "cdp": cmd_cdp, "diff": cmd_diff, "leakscan": cmd_leakscan,
     "latency": cmd_latency, "toggle-check": cmd_toggle_check}[a.cmd](a)


if __name__ == "__main__":
    main()
