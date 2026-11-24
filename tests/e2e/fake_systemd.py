#!/usr/bin/env python3
"""Stand-in for org.freedesktop.systemd1 on the isolated session bus (stdlib only).

gnome-shell starts its X11 services through the systemd user manager; with no answer the X11
display never finishes initialising and every X11 client of the headless shell hangs (spike T1, Q1).
StartUnit/StopUnit succeed without doing anything; GetUnit says the unit does not exist.

usage: fake_systemd.py <log file>
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dbuslite as d  # noqa: E402

MANAGER = "org.freedesktop.systemd1.Manager"
log = open(sys.argv[1], "a", buffering=1)
conn = d.Connection.session()
conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", "su",
          ("org.freedesktop.systemd1", 4))
jobs = 0


def reply(m, sig="", body=()):
    conn.send(d.Message(d.METHOD_RETURN, {d.F_REPLY_SERIAL: m.serial, d.F_DESTINATION: m.sender,
                                          d.F_SIGNATURE: sig}, body))


while True:
    m = conn.recv()
    if m.type != d.METHOD_CALL:
        continue
    log.write(f"{m.member}\n")
    if m.member in ("StartUnit", "StopUnit"):
        jobs += 1
        job = f"/org/freedesktop/systemd1/job/{jobs}"
        reply(m, "o", (job,))
        conn.send(d.Message(d.SIGNAL, {d.F_PATH: "/org/freedesktop/systemd1", d.F_INTERFACE: MANAGER,
                                       d.F_MEMBER: "JobRemoved", d.F_SIGNATURE: "uoss"},
                            (jobs, job, m.body[0], "done")))
    elif m.member == "GetUnit":
        conn.send(d.Message(d.ERROR, {d.F_REPLY_SERIAL: m.serial, d.F_DESTINATION: m.sender,
                                      d.F_ERROR_NAME: "org.freedesktop.systemd1.NoSuchUnit", d.F_SIGNATURE: "s"},
                            ("Unit not loaded.",)))
    elif not m.flags & d.NO_REPLY_EXPECTED:
        reply(m)
