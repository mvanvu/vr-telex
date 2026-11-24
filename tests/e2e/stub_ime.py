#!/usr/bin/env python3
"""Stub IBus engine for the e2e harness (stdlib only), used by `run.sh --ime stub`.

It stands in for vr-talex's fe-ibus until the real frontends exist, so the harness can be proven
end to end (inject -> gnome-shell -> IBus -> app -> readback -> diff). It is a one-service pseudo
bus on a private path socket (the shape spike T1 proved and the plan chose), writes the IBus address
file, and implements a word-level Telex by looking up the golden list (keys -> expected); words not
in the list pass through raw. Behaviours the harness scenarios rely on, mirroring the spec:
preedit while typing, commit at a word boundary, commit on FocusOut/Reset (B3), Ctrl+Shift tapped
alone toggles VI/EN and updates the panel indicator (B4/B6), password/PIN purpose passes through (B5).

Like the daemon it must never log typed text (SEC-1): the log carries method names and counts only.

usage: stub_ime.py <golden.tsv> <socket path> <log file> <stats json> [--mode VI|EN]
"""
import json
import os
import selectors
import signal
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dbuslite as d  # noqa: E402

GOLDEN, SOCK, LOG, STATS = sys.argv[1:5]
MODE = sys.argv[sys.argv.index("--mode") + 1] if "--mode" in sys.argv else "VI"
# Preedit mode sent with UpdatePreeditTextWithMode: "commit" (1) lets the client commit the preedit itself when
# it loses focus or resets, so the engine then only drops its buffer; "clear" (0) makes the engine commit.
PREEDIT = os.environ.get("E2E_STUB_PREEDIT", "commit")

RELEASE = 1 << 30
SHIFT, CTRL, ALT, SUPER = 1, 4, 8, 1 << 26
CTRL_KEYS = {0xFFE3, 0xFFE4}
SHIFT_KEYS = {0xFFE1, 0xFFE2}
MODIFIER_KEYS = CTRL_KEYS | SHIFT_KEYS | {0xFFE5, 0xFFE6, 0xFFE7, 0xFFE8, 0xFFE9, 0xFFEA, 0xFFEB, 0xFFEC,
                                         0xFE03, 0xFFED, 0xFFEE}
BACKSPACE = 0xFF08
PURPOSE_PASSWORD, PURPOSE_PIN = 8, 9
OWNER = ":1.0"
IC_IFACE = "org.freedesktop.IBus.InputContext"

logf = open(LOG, "a", buffering=1)
T0 = time.monotonic()


def log(*a):
    logf.write(f"{time.monotonic() - T0:9.3f} " + " ".join(str(x) for x in a) + "\n")


def load_golden(path):
    table = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or "\t" not in line:
                continue
            keys, expected = line.rstrip("\n").split("\t", 1)
            table.setdefault(keys, expected)
    return table


TABLE = load_golden(GOLDEN)


def text_v(s):
    return d.Variant("(sa{sv}sv)", ("IBusText", {}, s, d.Variant("(sa{sv}av)", ("IBusAttrList", {}, []))))


ENGINE = d.Variant("(sa{sv}ssssssssussssssss)", (
    "IBusEngineDesc", {}, "vr-talex", "Telex", "e2e stub engine", "vi", "", "", "", "us", 0,
    "", "VI", "", "", "", "", "", ""))


def prop_v(symbol):
    return d.Variant("(sa{sv}suvsvbbuvv)", (
        "IBusProperty", {}, "InputMode", 0, text_v("Mode"), "", text_v(""), True, True, 0,
        d.Variant("(sa{sv}av)", ("IBusPropList", {}, [])), text_v(symbol)))


class Stats:
    def __init__(self):
        self.durations_ns = []
        self.commits = 0
        self.toggles = 0

    def dump(self):
        ds = sorted(self.durations_ns)

        def pct(p):
            return round(ds[min(len(ds) - 1, int(p * len(ds)))] / 1000, 1) if ds else None
        data = {"source": "stub-ime", "keys": len(ds), "p50_us": pct(0.50), "p99_us": pct(0.99),
                "max_us": round(ds[-1] / 1000, 1) if ds else None, "commits": self.commits, "toggles": self.toggles}
        tmp = STATS + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, STATS)


STATS_DATA = Stats()


class Client:
    def __init__(self, server, sock, name):
        self.server = server
        self.sock = sock
        self.name = name
        self.buf = bytearray()
        self.serial = 0

    def send(self, mtype, fields, body=(), flags=0):
        self.serial += 1
        msg = d.Message(mtype, fields, body, flags, self.serial)
        try:
            self.sock.sendall(msg.encode())
        except OSError:
            pass

    def reply(self, call, sig="", body=(), sender=OWNER):
        if call.flags & d.NO_REPLY_EXPECTED:
            return
        self.send(d.METHOD_RETURN, {d.F_REPLY_SERIAL: call.serial, d.F_DESTINATION: self.name,
                                    d.F_SENDER: sender, d.F_SIGNATURE: sig}, body)

    def error(self, call, name, text="", sender=OWNER):
        if call.flags & d.NO_REPLY_EXPECTED:
            return
        self.send(d.ERROR, {d.F_REPLY_SERIAL: call.serial, d.F_DESTINATION: self.name, d.F_SENDER: sender,
                            d.F_ERROR_NAME: name, d.F_SIGNATURE: "s"}, (text,))

    def signal(self, path, iface, member, sig="", body=(), sender=OWNER):
        # Unicast to the owning connection only (the shape SEC-9 asks of the daemon).
        self.send(d.SIGNAL, {d.F_PATH: path, d.F_INTERFACE: iface, d.F_MEMBER: member, d.F_DESTINATION: self.name,
                             d.F_SENDER: sender, d.F_SIGNATURE: sig}, body)

    def call_panel(self, member, sig, body):
        self.send(d.METHOD_CALL, {d.F_PATH: "/org/freedesktop/IBus/Panel", d.F_INTERFACE: "org.freedesktop.IBus.Panel",
                                  d.F_MEMBER: member, d.F_DESTINATION: self.name, d.F_SENDER: OWNER,
                                  d.F_SIGNATURE: sig}, body, d.NO_REPLY_EXPECTED)


class InputContext:
    def __init__(self, client, path):
        self.client = client
        self.path = path
        self.word = ""
        self.purpose = 0

    def preedit(self, text):
        self.client.signal(self.path, IC_IFACE, "UpdatePreeditTextWithMode", "vubu",
                           (text_v(text), len(text), bool(text), 1 if PREEDIT == "commit" else 0))

    def commit(self):
        if not self.word:
            return
        word, self.word = self.word, ""
        self.preedit("")
        self.client.signal(self.path, IC_IFACE, "CommitText", "v", (text_v(TABLE.get(word, word)),))
        STATS_DATA.commits += 1


class Server:
    def __init__(self):
        self.sel = selectors.DefaultSelector()
        self.clients = {}
        self.ics = {}
        self.panel = None
        self.next_client = 1
        self.next_ic = 1
        self.mode = MODE
        self.mods = set()
        self.armed = False
        self.global_engine = ""
        self.focused = None
        if os.path.lexists(SOCK):
            os.unlink(SOCK)
        os.makedirs(os.path.dirname(SOCK), mode=0o700, exist_ok=True)
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old = os.umask(0o177)
        self.listener.bind(SOCK)
        os.umask(old)
        self.listener.listen(8)
        self.sel.register(self.listener, selectors.EVENT_READ, None)
        log("listening")

    def accept(self):
        sock, _ = self.listener.accept()
        try:
            left = d.server_auth(sock)
        except (OSError, ConnectionError, PermissionError) as e:
            log("auth rejected", type(e).__name__)
            sock.close()
            return
        name = f":1.{self.next_client}"
        self.next_client += 1
        c = Client(self, sock, name)
        c.buf += left
        self.clients[sock] = c
        self.sel.register(sock, selectors.EVENT_READ, c)
        log("client authenticated", name)
        self.drain(c)

    def drop(self, c):
        log("client gone", c.name)
        for path, ic in list(self.ics.items()):
            if ic.client is c:
                del self.ics[path]
        if self.panel is c:
            self.panel = None
        self.sel.unregister(c.sock)
        c.sock.close()
        del self.clients[c.sock]

    def read(self, c):
        try:
            chunk = c.sock.recv(65536)
        except OSError:
            chunk = b""
        if not chunk:
            self.drop(c)
            return
        c.buf += chunk
        self.drain(c)

    def drain(self, c):
        for msg in d.decode_stream(c.buf):
            if msg.type == d.METHOD_CALL:
                t = time.perf_counter_ns()
                self.dispatch(c, msg)
                if msg.member == "ProcessKeyEvent":
                    STATS_DATA.durations_ns.append(time.perf_counter_ns() - t)

    def dispatch(self, c, m):
        if m.destination == "org.freedesktop.DBus" or m.interface == "org.freedesktop.DBus":
            return self.bus_method(c, m)
        if m.interface == "org.freedesktop.DBus.Properties":
            return self.properties(c, m)
        if m.path == "/org/freedesktop/IBus" and m.interface == "org.freedesktop.IBus":
            return self.ibus_method(c, m)
        ic = self.ics.get(m.path)
        if ic is not None:
            if ic.client is not c:
                return c.error(m, "org.freedesktop.DBus.Error.AccessDenied", "not your input context")
            return self.ic_method(ic, m)
        if m.interface == "org.freedesktop.DBus.Peer":
            return c.reply(m)
        log("unknown call", m.interface, m.member)
        c.error(m, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method")

    def bus_method(self, c, m):
        bus = "org.freedesktop.DBus"
        member = m.member
        if member == "Hello":
            c.reply(m, "s", (c.name,), bus)
            c.signal("/org/freedesktop/DBus", bus, "NameAcquired", "s", (c.name,), bus)
        elif member in ("AddMatch", "RemoveMatch"):
            c.reply(m, sender=bus)
        elif member == "GetNameOwner":
            name = m.body[0]
            if name == "org.freedesktop.IBus":
                c.reply(m, "s", (OWNER,), bus)
            elif name == "org.freedesktop.IBus.Panel" and self.panel:
                c.reply(m, "s", (self.panel.name,), bus)
            else:
                c.error(m, "org.freedesktop.DBus.Error.NameHasNoOwner", "no owner", bus)
        elif member == "NameHasOwner":
            c.reply(m, "b", (m.body[0] == "org.freedesktop.IBus" or (m.body[0].endswith(".Panel") and bool(self.panel)),), bus)
        elif member == "RequestName":
            if m.body[0] == "org.freedesktop.IBus.Panel":
                self.panel = c
            c.reply(m, "u", (1,), bus)
            c.signal("/org/freedesktop/DBus", bus, "NameAcquired", "s", (m.body[0],), bus)
        elif member == "ReleaseName":
            c.reply(m, "u", (1,), bus)
        elif member == "GetId":
            c.reply(m, "s", ("0" * 32,), bus)
        elif member == "ListNames":
            c.reply(m, "as", ([bus, "org.freedesktop.IBus"] + [x.name for x in self.clients.values()],), bus)
        else:
            c.error(m, "org.freedesktop.DBus.Error.UnknownMethod", "unknown bus method", bus)

    def properties(self, c, m):
        if m.member == "Get":
            iface, name = m.body
            if m.path == "/org/freedesktop/IBus":
                if name in ("Engines", "ActiveEngines"):
                    return c.reply(m, "v", (d.Variant("av", [ENGINE]),))
                if name == "GlobalEngine":
                    if not self.global_engine:
                        return c.error(m, "org.freedesktop.DBus.Error.Failed", "no global engine")
                    return c.reply(m, "v", (d.Variant("v", ENGINE),))
                if name == "EmbedPreeditText":
                    return c.reply(m, "v", (d.Variant("b", True),))
            return c.error(m, "org.freedesktop.DBus.Error.InvalidArgs", "no such property")
        if m.member == "GetAll":
            return c.reply(m, "a{sv}", ({},))
        if m.member == "Set":
            _iface, name, value = m.body
            ic = self.ics.get(m.path)
            if ic is not None and ic.client is c and name == "ContentType":
                ic.purpose = value.value[0]
            return c.reply(m)
        c.error(m, "org.freedesktop.DBus.Error.UnknownMethod", "unknown properties method")

    def ibus_method(self, c, m):
        if m.member == "CreateInputContext":
            path = f"/org/freedesktop/IBus/InputContext_{self.next_ic}"
            self.next_ic += 1
            self.ics[path] = InputContext(c, path)
            log("CreateInputContext", path)
            c.reply(m, "o", (path,))
        elif m.member == "SetGlobalEngine":
            self.global_engine = m.body[0]
            c.reply(m)
            c.signal("/org/freedesktop/IBus", "org.freedesktop.IBus", "GlobalEngineChanged", "s", (self.global_engine,))
            self.announce_mode(register=True)
            log("SetGlobalEngine")
        elif m.member in ("ListEngines", "ListActiveEngines", "GetEnginesByNames"):
            c.reply(m, "av", ([ENGINE],))
        elif m.member == "GetGlobalEngine":
            c.reply(m, "v", (ENGINE,))
        elif m.member in ("IsGlobalEngineEnabled", "GetUseGlobalEngine"):
            c.reply(m, "b", (True,))
        elif m.member == "Ping":
            c.reply(m, "v", m.body)
        else:
            c.reply(m)

    def announce_mode(self, register=False):
        if not self.panel:
            return
        if register:
            self.panel.call_panel("RegisterProperties", "v",
                                  (d.Variant("(sa{sv}av)", ("IBusPropList", {}, [prop_v(self.mode)])),))
        else:
            self.panel.call_panel("UpdateProperty", "v", (prop_v(self.mode),))

    def toggle(self):
        if self.focused:
            self.focused.commit()
        self.mode = "EN" if self.mode == "VI" else "VI"
        STATS_DATA.toggles += 1
        log("toggle ->", self.mode)
        self.announce_mode()

    def ic_method(self, ic, m):
        c = ic.client
        member = m.member
        if member == "ProcessKeyEvent":
            keyval, _keycode, state = m.body
            c.reply(m, "b", (self.key(ic, keyval, state),))
        elif member == "FocusIn":
            self.focused = ic
            c.reply(m)
            if self.panel:
                self.panel.call_panel("FocusIn", "o", (ic.path,))
        elif member in ("FocusOut", "Reset"):
            if PREEDIT == "commit":
                ic.word = ""  # the client commits the preedit it shows
            else:
                ic.commit()
            if member == "FocusOut" and self.focused is ic:
                self.focused = None
            c.reply(m)
        elif member == "Destroy":
            ic.commit()
            self.ics.pop(ic.path, None)
            c.reply(m)
        elif member == "GetEngine":
            c.reply(m, "v", (ENGINE,))
        else:
            c.reply(m)

    def key(self, ic, keyval, state):
        release = bool(state & RELEASE)
        if keyval in CTRL_KEYS | SHIFT_KEYS:
            kind = "ctrl" if keyval in CTRL_KEYS else "shift"
            if not release:
                self.mods.add(kind)
                if self.mods == {"ctrl", "shift"}:
                    self.armed = True
            else:
                self.mods.discard(kind)
                if self.armed and not self.mods:
                    self.armed = False
                    self.toggle()
            return False
        if keyval in MODIFIER_KEYS:
            return False
        if not release:
            self.armed = False
        if release:
            return False
        if self.mode == "EN" or ic.purpose in (PURPOSE_PASSWORD, PURPOSE_PIN):
            return False
        if state & (CTRL | ALT | SUPER):
            ic.commit()
            return False
        if 0x41 <= keyval <= 0x5A or 0x61 <= keyval <= 0x7A:
            ic.word += chr(keyval)
            ic.preedit(TABLE.get(ic.word, ic.word))
            return True
        if keyval == BACKSPACE and ic.word:
            ic.word = ic.word[:-1]
            ic.preedit(TABLE.get(ic.word, ic.word))
            return True
        ic.commit()
        return False

    def run(self):
        while True:
            for key, _ in self.sel.select():
                if key.data is None:
                    self.accept()
                else:
                    self.read(key.data)


def write_address_file():
    mid = ""
    for p in ("/var/lib/dbus/machine-id", "/etc/machine-id"):
        try:
            with open(p) as f:
                mid = f.read().strip()
                break
        except OSError:
            continue
    disp = os.environ.get("WAYLAND_DISPLAY") or "unix-" + os.environ.get("DISPLAY", ":0").lstrip(":").split(".")[0]
    name = f"{mid}-unix-{disp}" if os.environ.get("WAYLAND_DISPLAY") else f"{mid}-{disp}"
    bus_dir = os.path.join(os.environ["XDG_CONFIG_HOME"], "ibus", "bus")
    os.makedirs(bus_dir, mode=0o700, exist_ok=True)
    path = os.path.join(bus_dir, name)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(f"IBUS_ADDRESS=unix:path={SOCK}\nIBUS_DAEMON_PID={os.getpid()}\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    log("address file written")


def on_term(_sig, _frame):
    STATS_DATA.dump()
    log("stopping; keys", len(STATS_DATA.durations_ns), "commits", STATS_DATA.commits)
    sys.exit(0)


signal.signal(signal.SIGTERM, on_term)
signal.signal(signal.SIGINT, on_term)
server = Server()
write_address_file()
server.run()
