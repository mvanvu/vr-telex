"""Minimal D-Bus wire protocol (Python 3 stdlib only) for the e2e harness.

Covers what the harness needs: EXTERNAL auth (client and server side), little-endian
marshalling of every basic and container type, method calls, replies, errors and signals.
No unix-fd passing. Values: struct -> tuple, array -> list, dict -> dict, variant -> Variant.
"""
import os
import socket
import struct

METHOD_CALL, METHOD_RETURN, ERROR, SIGNAL = 1, 2, 3, 4
NO_REPLY_EXPECTED = 0x1
F_PATH, F_INTERFACE, F_MEMBER, F_ERROR_NAME, F_REPLY_SERIAL, F_DESTINATION, F_SENDER, F_SIGNATURE = range(1, 9)
_FIELD_SIG = {F_PATH: "o", F_INTERFACE: "s", F_MEMBER: "s", F_ERROR_NAME: "s", F_REPLY_SERIAL: "u",
              F_DESTINATION: "s", F_SENDER: "s", F_SIGNATURE: "g", 9: "u"}
_FIXED = {"y": ("B", 1), "b": ("I", 4), "n": ("h", 2), "q": ("H", 2), "i": ("i", 4), "u": ("I", 4),
          "x": ("q", 8), "t": ("Q", 8), "d": ("d", 8), "h": ("I", 4)}
_ALIGN = {"y": 1, "b": 4, "n": 2, "q": 2, "i": 4, "u": 4, "x": 8, "t": 8, "d": 8, "h": 4,
          "s": 4, "o": 4, "g": 1, "a": 4, "(": 8, "{": 8, "v": 1}


class DBusError(Exception):
    def __init__(self, name, text=""):
        super().__init__(f"{name}: {text}")
        self.name = name
        self.text = text


class Variant:
    __slots__ = ("sig", "value")

    def __init__(self, sig, value):
        self.sig = sig
        self.value = value

    def __repr__(self):
        return f"Variant({self.sig!r}, ...)"


def split_sig(sig):
    """Split a signature into its complete types."""
    out, i = [], 0
    while i < len(sig):
        j = _type_end(sig, i)
        out.append(sig[i:j])
        i = j
    return out


def _type_end(sig, i):
    c = sig[i]
    if c == "a":
        return _type_end(sig, i + 1)
    if c in "({":
        close = ")" if c == "(" else "}"
        depth, j = 0, i
        while True:
            if sig[j] in "({":
                depth += 1
            elif sig[j] in ")}":
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
    return i + 1


class _Writer:
    def __init__(self, offset=0):
        self.buf = bytearray()
        self.base = offset

    def pad(self, n):
        while (self.base + len(self.buf)) % n:
            self.buf.append(0)

    def write(self, t, v):
        c = t[0]
        self.pad(_ALIGN[c])
        if c in _FIXED:
            fmt, _ = _FIXED[c]
            self.buf += struct.pack("<" + fmt, int(bool(v)) if c == "b" else v)
        elif c in "so":
            b = v.encode()
            self.buf += struct.pack("<I", len(b)) + b + b"\0"
        elif c == "g":
            b = v.encode()
            self.buf += struct.pack("<B", len(b)) + b + b"\0"
        elif c == "v":
            self.write("g", v.sig)
            self.write(v.sig, v.value)
        elif c == "a":
            elem = t[1:]
            at = len(self.buf)
            self.buf += b"\0\0\0\0"
            self.pad(_ALIGN[elem[0]])
            start = len(self.buf)
            items = v.items() if elem[0] == "{" else v
            for item in items:
                self.write(elem, item)
            struct.pack_into("<I", self.buf, at, len(self.buf) - start)
        elif c in "({":
            for sub, val in zip(split_sig(t[1:-1]), v):
                self.write(sub, val)
        else:
            raise ValueError(f"unsupported type {t}")


class _Reader:
    def __init__(self, data, pos=0):
        self.data = data
        self.pos = pos

    def align(self, n):
        self.pos += (-self.pos) % n

    def read(self, t):
        c = t[0]
        self.align(_ALIGN[c])
        if c in _FIXED:
            fmt, size = _FIXED[c]
            (v,) = struct.unpack_from("<" + fmt, self.data, self.pos)
            self.pos += size
            return bool(v) if c == "b" else v
        if c in "so":
            (n,) = struct.unpack_from("<I", self.data, self.pos)
            v = bytes(self.data[self.pos + 4:self.pos + 4 + n]).decode()
            self.pos += 4 + n + 1
            return v
        if c == "g":
            n = self.data[self.pos]
            v = bytes(self.data[self.pos + 1:self.pos + 1 + n]).decode()
            self.pos += 1 + n + 1
            return v
        if c == "v":
            sig = self.read("g")
            return Variant(sig, self.read(sig))
        if c == "a":
            (n,) = struct.unpack_from("<I", self.data, self.pos)
            self.pos += 4
            elem = t[1:]
            self.align(_ALIGN[elem[0]])
            end = self.pos + n
            items = []
            while self.pos < end:
                items.append(self.read(elem))
            return dict(items) if elem[0] == "{" else items
        if c in "({":
            return tuple(self.read(sub) for sub in split_sig(t[1:-1]))
        raise ValueError(f"unsupported type {t}")


class Message:
    __slots__ = ("type", "flags", "serial", "fields", "body")

    def __init__(self, mtype, fields, body=(), flags=0, serial=0):
        self.type = mtype
        self.flags = flags
        self.serial = serial
        self.fields = fields
        self.body = tuple(body)

    path = property(lambda s: s.fields.get(F_PATH))
    interface = property(lambda s: s.fields.get(F_INTERFACE))
    member = property(lambda s: s.fields.get(F_MEMBER))
    sender = property(lambda s: s.fields.get(F_SENDER))
    destination = property(lambda s: s.fields.get(F_DESTINATION))
    signature = property(lambda s: s.fields.get(F_SIGNATURE, ""))
    reply_serial = property(lambda s: s.fields.get(F_REPLY_SERIAL))
    error_name = property(lambda s: s.fields.get(F_ERROR_NAME))

    def encode(self):
        sig = self.fields.get(F_SIGNATURE, "")
        bw = _Writer()
        for t, v in zip(split_sig(sig), self.body):
            bw.write(t, v)
        fields = [(k, Variant(_FIELD_SIG[k], v)) for k, v in self.fields.items() if not (k == F_SIGNATURE and not v)]
        hw = _Writer()
        hw.buf += struct.pack("<cBBBII", b"l", self.type, self.flags, 1, len(bw.buf), self.serial)
        hw.write("a(yv)", fields)
        hw.pad(8)
        return bytes(hw.buf + bw.buf)


def _decode(data):
    """Return (message, consumed) or (None, 0) when data holds no complete message."""
    if len(data) < 16:
        return None, 0
    if data[0:1] != b"l":
        raise ValueError("only little-endian peers are supported")
    mtype, flags, _ver, blen, serial, flen = struct.unpack_from("<BBBIII", data, 1)
    hend = 16 + flen
    hend += (-hend) % 8
    total = hend + blen
    if len(data) < total:
        return None, 0
    r = _Reader(data, 12)
    fields = {k: v.value for k, v in r.read("a(yv)")}
    sig = fields.get(F_SIGNATURE, "")
    br = _Reader(memoryview(data)[hend:total].tobytes())
    body = tuple(br.read(t) for t in split_sig(sig))
    return Message(mtype, fields, body, flags, serial), total


def _connect_address(address):
    for part in address.split(";"):
        kind, _, rest = part.partition(":")
        if kind != "unix":
            continue
        kv = dict(p.split("=", 1) for p in rest.split(",") if "=" in p)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        if "path" in kv:
            s.connect(_unescape(kv["path"]))
        elif "abstract" in kv:
            s.connect("\0" + _unescape(kv["abstract"]))
        else:
            continue
        return s
    raise OSError(f"no usable unix address in {address!r}")


def _unescape(v):
    out, i = bytearray(), 0
    while i < len(v):
        if v[i] == "%":
            out.append(int(v[i + 1:i + 3], 16))
            i += 3
        else:
            out += v[i].encode()
            i += 1
    return out.decode()


class Connection:
    """Blocking client connection (bus or p2p)."""

    def __init__(self, sock, bus=True):
        self.sock = sock
        self.buf = bytearray()
        self.serial = 0
        self.pending = []
        self.unique_name = None
        self._auth_client()
        if bus:
            (self.unique_name,) = self.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                                            "org.freedesktop.DBus", "Hello")

    @classmethod
    def session(cls):
        return cls(_connect_address(os.environ["DBUS_SESSION_BUS_ADDRESS"]))

    def _auth_client(self):
        uid = str(os.getuid()).encode().hex()
        self.sock.sendall(b"\0AUTH EXTERNAL " + uid.encode() + b"\r\n")
        line = self._line()
        if not line.startswith(b"OK "):
            raise DBusError("org.freedesktop.DBus.Error.AuthFailed", line.decode(errors="replace"))
        self.sock.sendall(b"BEGIN\r\n")

    def _line(self):
        while b"\r\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("peer closed during auth")
            self.buf += chunk
        line, _, rest = bytes(self.buf).partition(b"\r\n")
        self.buf = bytearray(rest)
        return line

    def send(self, msg):
        self.serial += 1
        msg.serial = self.serial
        self.sock.sendall(msg.encode())
        return msg.serial

    def recv(self):
        while True:
            msg, used = _decode(self.buf)
            if msg:
                del self.buf[:used]
                return msg
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("peer closed")
            self.buf += chunk

    def call(self, dest, path, iface, member, sig="", args=(), timeout=10.0):
        fields = {F_PATH: path, F_INTERFACE: iface, F_MEMBER: member, F_SIGNATURE: sig}
        if dest:
            fields[F_DESTINATION] = dest
        serial = self.send(Message(METHOD_CALL, fields, args))
        self.sock.settimeout(timeout)
        try:
            while True:
                msg = self.recv()
                if msg.reply_serial == serial:
                    if msg.type == ERROR:
                        raise DBusError(msg.error_name, msg.body[0] if msg.body else "")
                    return msg.body
                if msg.type == SIGNAL:
                    self.pending.append(msg)
        finally:
            self.sock.settimeout(None)

    def close(self):
        self.sock.close()


def server_auth(sock):
    """Server side of the auth handshake: EXTERNAL only, peer uid must equal ours.

    Returns leftover bytes read past BEGIN, or raises on failure.
    """
    creds = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    _pid, peer_uid, _gid = struct.unpack("3i", creds)
    if peer_uid != os.getuid():
        raise PermissionError("foreign peer uid")
    buf = bytearray()
    first = sock.recv(1)
    if first != b"\0":
        raise ConnectionError("missing nul byte")
    want_uid = str(os.getuid()).encode().hex().encode()

    def line():
        while b"\r\n" not in buf:
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError("peer closed during auth")
            buf.extend(chunk)
        ln, _, rest = bytes(buf).partition(b"\r\n")
        buf[:] = rest
        return ln

    ok = False
    while True:
        ln = line()
        words = ln.split()
        if not words:
            continue
        if words[0] == b"AUTH":
            if len(words) >= 2 and words[1] == b"EXTERNAL":
                ident = words[2] if len(words) > 2 else None
                if ident is None:
                    sock.sendall(b"DATA\r\n")
                    data = line().split()
                    ident = data[1] if len(data) > 1 else want_uid
                if ident == want_uid:
                    sock.sendall(b"OK " + os.urandom(16).hex().encode() + b"\r\n")
                    ok = True
                    continue
            sock.sendall(b"REJECTED EXTERNAL\r\n")
        elif words[0] == b"NEGOTIATE_UNIX_FD":
            sock.sendall(b"ERROR unix fd passing is not supported\r\n")
        elif words[0] == b"BEGIN" and ok:
            return bytes(buf)
        elif words[0] == b"CANCEL":
            sock.sendall(b"REJECTED EXTERNAL\r\n")
        else:
            sock.sendall(b"ERROR\r\n")


def decode_stream(buf):
    """Pop every complete message from a bytearray buffer."""
    out = []
    while True:
        msg, used = _decode(buf)
        if not msg:
            return out
        del buf[:used]
        out.append(msg)
