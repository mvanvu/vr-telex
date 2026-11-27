# T1 spike — hot apply and client routes on GNOME 46

Date 2026-11-24. Machine: Ubuntu 24.04.5, GNOME Shell 46.0 / mutter 46.2 (Wayland session), fcitx5 5.1.7 running, ibus-daemon not installed (but `libibus-1.0.so.5` 1.5.29 is — gnome-shell links it), Chrome 157.0.8103.50, VS Code 1.145.2, Rust 1.100.

Everything ran in a throwaway session (SEC-29): `dbus-run-session`, own `HOME`/`XDG_*`/`XDG_RUNTIME_DIR` under `.ai-dev-team/workspace/qa-artifacts/T1/`, `GSETTINGS_BACKEND=keyfile`, a guard that aborts on live values (`lib.sh: guard`). Live desktop after all runs: fcitx5 pid 6881 unchanged, `~/.config/ibus/bus/*` mtime still 2026-11-22, no tagged process left.

All scripts: `.ai-dev-team/workspace/qa-artifacts/T1/` (`lib.sh`, `rd.py`, `fake_ibus.py`, `fake_fcitx.py`, `fake_systemd.py`, `q1.sh` … `q5.sh`, `broker/`). Run one with `$TEAM_BIN/run-heavy.sh bash <script> <arg>`. Raw logs: `qa-artifacts/T1/logs/<run>/`.

## Summary

| # | Answer |
|---|---|
| Q1 | Yes. `gnome-shell --headless --wayland --virtual-monitor 1280x800` runs under `dbus-run-session`; gnome-terminal, Chrome and VS Code open in it. X11 clients need one extra: a stand-in `org.freedesktop.systemd1` on that bus (see Q1). |
| Q2 | Yes. Mutter RemoteDesktop works headless without privileges; 614 keys at 18.7 ms and 7.4 ms per key arrived complete and in order. |
| Q3 | **Hot apply works.** libibus watches the address file with a `GFileMonitor`; gnome-shell connected 3–100 ms after the file appeared, set the engine after 0.3–0.5 s, and an already-running gnome-terminal got the IME — no shell restart. A zbus 6.5.0 p2p server is accepted by gnome-shell. |
| Q4 | Chrome and VS Code are **native Wayland** clients here and use text-input-v3 → gnome-shell → IBus in both environments (they ignore `GTK_IM_MODULE`). gnome-terminal uses the fcitx5 D-Bus frontend when `GTK_IM_MODULE=fcitx`, and text-input-v3 → IBus when it is unset. Nothing uses XIM. |
| Q5 | Both reconnect without restart: the fcitx GTK module re-creates its context when a new process takes `org.fcitx.Fcitx5`; gnome-shell reconnects when the address file content changes (also while the old publisher is alive). |
| Q6 | (a) this machine: `fe-ibus` + `fe-fcitx`. (b) default Ubuntu Wayland: `fe-ibus` only. `fe-xim` is not on the path of any AC-2 app. D9's fallback is **not needed**. |

Corrections to the plan's facts: F2 is only half right — Chrome 157 and VS Code 1.145 no longer run under XWayland, so they do not load the fcitx module; only GTK apps (gnome-terminal) take the fcitx route.

---

## Q1. Headless GNOME Shell with apps

```
$ run-heavy.sh bash q1.sh
shell pid 28075; runtime dir: dbus-1 gnome-shell gvfs gvfsd wayland-0 wayland-0.lock
      CreateSession(out o session_path);
      readonly u SupportedDeviceTypes = 7;
(true, '"gnome-terminal-server/wayland/focus=true"')
typed file: [hello world 123 Viet Nam]
```
```
$ run-heavy.sh bash q1c.sh ""          # Chrome alone
t=3s (true, '"google-chrome:1214:true:about:blank - Google Chrome"')     # class:width:focus:title
$ ps … | grep ozone
/opt/google/chrome/chrome --type=gpu-process … --ozone-platform=wayland
/usr/share/code/code --type=gpu-process --ozone-platform=wayland
```
The live Chrome and VS Code processes of this desktop also run `--ozone-platform=wayland` (9 live processes, none x11; read from `ps`, nothing changed).

Findings the e2e harness (T9, D12) needs:
- `--unsafe-mode` gives `org.gnome.Shell.Eval` (focus a window, read titles, hide the overview) and `org.gnome.Shell.Screenshot`.
- Xwayland: mutter logs `Using public X11 display :2`, but without a systemd user manager on the isolated bus gnome-shell logs `Error starting X11 services … org.freedesktop.systemd1 exited with status 1` / `Failed to initialize X11 display`, and then every X11 client hangs — including Chrome when `DISPLAY` is exported (its window stayed 0 px wide for 30 s). `fake_systemd.py` (answers `StartUnit('gnome-session-x11-services-ready.target','fail')` with a job path, `GetUnit` with `NoSuchUnit`) fixes it: Chrome mapped in ~3 s with `DISPLAY=:2` set.
- Windows opened from outside the shell do not get focus when another window has it; the harness activates them (`lib.sh: wait_win` — waits for a frame width > 0, then `meta_window.activate()`).
- VS Code needs `--password-store=basic`, otherwise a shell "Choose password for new keyring" dialog takes the keys. Chrome: `--password-store=basic --no-first-run --disable-search-engine-choice-screen`.
- The isolated bus activates ~30 helper services (tracker, portals, gvfs…); `lib.sh: cleanup` stops exactly the processes carrying the run's `VRT1_TAG` environment value.

## Q2. Key injection through Mutter RemoteDesktop

`rd.py`: `org.gnome.Mutter.RemoteDesktop.CreateSession` → `Session.Start` → `NotifyKeyboardKeysym(u keysym, b state)`. No privileges, no portal dialog.

- The first event of a new session is not delivered to the client (first run typed `ello world…`). A Shift tap as warm-up plus 0.3 s fixes it (`rd.py`).
- Each D-Bus call costs 1–3 ms, so a 15 ms sleep gives 16–19 ms per key; 5 ms gives 7–11 ms.
- Ordering through the full path shell → IBus → toy engine (preedit per letter, commit at space) → gnome-terminal:
```
$ run-heavy.sh bash q2b.sh
rd: type 614 keys in 11473 ms (18.7 ms/key)
rd: type 614 keys in 4534 ms (7.4 ms/key)
run 1: 613 chars, expected 613, equal=True
run 2: 613 chars, expected 613, equal=True
ProcessKeyEvent seen: 2456
```

## Q3. Hot apply: gnome-shell and the IBus address file

### How libibus finds and watches the bus (ibus 1.5.29, `src/ibusbus.c`, `src/ibusshare.c`)
- `ibus_bus_constructor` (ibusbus.c:708-711): `file = g_file_new_for_path (ibus_get_socket_path ()); _bus->priv->monitor = g_file_monitor_file (file, 0, NULL, NULL); g_signal_connect (_bus->priv->monitor, "changed", (GCallback) _changed_cb, _bus);`
- `_changed_cb` (ibusbus.c:556-567): on `CHANGED`, `CREATED` or `DELETED` it calls `ibus_bus_connect_async (bus)`.
- `ibus_bus_connect_async` (ibusbus.c:481-505): reads the address; returns when it is `NULL`; **returns when it equals the current address**; otherwise closes the current connection and calls `g_dbus_connection_new_for_address (…, AUTHENTICATION_CLIENT | MESSAGE_BUS_CONNECTION, …)`.
- `ibus_get_socket_path` (ibusshare.c:110-153): `$IBUS_ADDRESS_FILE`, else `$XDG_CONFIG_HOME/ibus/bus/<machine-id>-unix-<display>` where display is `$WAYLAND_DISPLAY` when set (`…-unix-wayland-0`), else the number of `$DISPLAY` (`…-unix-0`). Machine id: `/var/lib/dbus/machine-id`, else `/etc/machine-id`.
- `ibus_get_address` (ibusshare.c:196-250): `$IBUS_ADDRESS` wins; else the file's `IBUS_ADDRESS=` line; returns `NULL` unless `IBUS_DAEMON_PID=` names a live process (`kill (pid, 0)`).

Consequences: the file must hold a live pid; a new address string is what triggers a reconnect; deleting the file or emptying it does not disconnect an existing connection (only the socket closing does).

What the live fcitx5 does (read only): it publishes its own IBus frontend on the **session bus** and writes both names:
```
~/.config/ibus/bus/5105…-unix-0 and …-unix-wayland-0:
IBUS_ADDRESS=unix:path=/run/user/1000/bus,fcitx_random_string=c25a22428f554f47b307cb0814e0ff7d
IBUS_DAEMON_PID=6881
```
So on this machine the live gnome-shell is already an IBus client of fcitx5, found through this file.

### Experiment (`q3.sh private|session|rust`)
Shell started first with `sources=[('ibus','vr-talex')]` and no address file; gnome-terminal running `cat > file`; then the service starts and writes the file.

```
$ run-heavy.sh bash q3.sh private          # separate dbus-daemon on a path socket + fake_ibus.py
state before (connected|source|indicator|visible): (true, '"false|us|en|false"')
typed before service: [abc def|]
address file: 5105d960568448fda641980dd0896fde-unix-wayland-0
  IBUS_ADDRESS=unix:path=…/qa-artifacts/T1/r/vrt-ibus
  IBUS_DAEMON_PID=52654
state after service start: (true, '"true|vr-talex|VI|true"')
typed after service (same running terminal): [abc def|XIN CHAO|]
state after service death: (true, '"false|us|en|false"')
typed after service death: [abc def|XIN CHAO|dead svc|]
state after second service: (true, '"true|vr-talex|VI|true"')
typed after second service: [abc def|XIN CHAO|dead svc|SECOND SVC|]
```
Timing from the service log (seconds after the service connected; file written at 0.003):
```
   0.003 ADDRESS FILE WRITTEN …/h/.config/ibus/bus/5105…-unix-wayland-0
   0.106 CALL :1.2 /org/freedesktop/IBus org.freedesktop.IBus.CreateInputContext (s) ('gnome-shell',)
   0.473 CALL :1.2 /org/freedesktop/IBus org.freedesktop.IBus.SetGlobalEngine (s) ('vr-talex',)
```
The top bar shows the engine symbol `VI` (screenshot `qa-artifacts/T1/logs/q4-ibus/code.png`).

### Private socket versus session bus
```
$ run-heavy.sh bash q3.sh session          # service on the session bus, the fcitx5 way
typed after service (same running terminal): [abc def|XIN CHAO|]
state after service death: (true, '"true|vr-talex|VI|true"')
typed after service death: [abc def|XIN CHAO|]                  <- "dead svc" was LOST
typed after second service: [abc def|XIN CHAO|SECOND SVC|]
shell.log: Error processing key on IM: Cannot invoke method; proxy is for the well-known name org.freedesktop.IBus without an owner
```
With the session bus the connection survives the service, gnome-shell keeps sending keys to a name without owner and drops every key (`misc/inputMethod.js` `vfunc_filter_key_event` returns `true` and only logs the error). With a private socket the connection closes, gnome-shell emits `disconnected`, falls back to `xkb us` and keys pass. **Keep the private socket (plan as written): a crash then fails open instead of eating the keyboard.**

### Rust mini broker (`qa-artifacts/T1/broker/`, zbus 6.5.0, features `tokio`, `p2p`, `bus-impl`)
`UnixListener` on a 0600 path socket, per connection `Builder::unix_stream(std_stream).server(Guid::generate()).p2p().auth_mechanism(AuthMechanism::External).build_message_stream()`, then answers `org.freedesktop.DBus` and `org.freedesktop.IBus` itself and writes the address file after `bind`.

```
$ run-heavy.sh bash q3.sh rust
state after service start: (true, '"true|vr-talex|VI|false"')
typed after service (same running terminal): [abc def|xin chao|]      # this broker answers ProcessKeyEvent = false
typed after service death: [abc def|xin chao|dead svc|]
typed after second service: [abc def|xin chao|dead svc|second svc|]
   0.001 listening on …/r/vrt-ibus; ADDRESS FILE WRITTEN …
   0.003 [:1.1] authenticated (EXTERNAL), peer uid Some(1000)
   0.004 [:1.1] MethodCall dest=org.freedesktop.DBus … org.freedesktop.DBus.Hello sig=''
```
Notes for T5: `build_message_stream` needs `bus-impl`; `Message::with_sender` exists for routing but was not needed; `to_owned_variant(&T)` (`zbus::wire::as_variant`) serializes a `#[derive(Serialize, Type)]` struct as the `v` IBus wants; zvariant is now inside zbus (`zbus::wire`, `zbus::Variant`).

No routing between peers was needed: the only peer is gnome-shell, every call it makes targets `org.freedesktop.DBus` or `org.freedesktop.IBus`, and panel calls go from the daemon to that same connection. `fe-ibus` can be a one-service pseudo bus (as ibus-daemon itself is), not a general broker.

### Exact calls gnome-shell 46 makes, in order (signature, arguments)
Bus level (`org.freedesktop.DBus`, path `/org/freedesktop/DBus`):
1. `Hello ()` → `s`; then expects signal `NameAcquired (s)`.
2. `AddMatch (s)` `type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',path='/org/freedesktop/DBus',arg0='org.freedesktop.IBus'`
3. `GetNameOwner (s)` `org.freedesktop.IBus` → `s` (unique name; signals must carry it as sender).
4. `AddMatch (s)` `type='signal',sender='org.freedesktop.IBus',interface='org.freedesktop.IBus',member='GlobalEngineChanged',path='/org/freedesktop/IBus'`
5. `AddMatch (s)` same with `member='GlobalShortcutKeyResponded'`.
6. `RequestName (su)` `('org.freedesktop.IBus.Panel', 2)` → `u` 1, then `NameAcquired`.
7. `AddMatch (s)` `…interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='/org/freedesktop/IBus/InputContext_1',arg0='org.freedesktop.IBus.InputContext'`
8. `AddMatch (s)` `type='signal',sender='org.freedesktop.IBus',interface='org.freedesktop.IBus.InputContext',path='/org/freedesktop/IBus/InputContext_1'`, then `GetNameOwner` again.

`org.freedesktop.IBus` at `/org/freedesktop/IBus`:
- `CreateInputContext (s)` `'gnome-shell'` → `o`.
- `org.freedesktop.DBus.Properties.Get (ss)` `('org.freedesktop.IBus','Engines')` → `v` holding `av` of `(sa{sv}ssssssssussssssss)` (IBusEngineDesc: typename, attachments, name, longname, description, language, license, author, icon, layout, rank, hotkeys, symbol, setup, layout_variant, layout_option, version, textdomain, icon_prop_key). `ListEngines` is not called.
- `Properties.Get (ss)` `(…,'GlobalEngine')` → `v` holding `v` holding the engine desc (an error is fine when none is set).
- `SetGlobalEngine (s)` `'vr-talex'` → `()`; the shell then waits for signal `GlobalEngineChanged (s)` and for `RegisterProperties (v)` (IBusPropList `(sa{sv}av)`) called on `org.freedesktop.IBus.Panel` `/org/freedesktop/IBus/Panel` — that is what fills the indicator.
- About 30 s after connecting: one `Properties.Set` of `PreloadEngines` (seen once in a member count; its signature was not captured — `misc/ibusManager.js` calls `preload_engines_async` after `_PRELOAD_ENGINES_DELAY_TIME = 30`).

Input context `/org/freedesktop/IBus/InputContext_1` (destination is the unique name):
- `Properties.GetAll (s)` `'org.freedesktop.IBus.InputContext'` → `a{sv}`.
- `Properties.Set (ssv)` `ClientCommitPreedit` = `(b)` `(true,)`.
- `SetCapabilities (u)` `41` (PREEDIT_TEXT 1 | FOCUS 8 | SURROUNDING_TEXT 32).
- On focus of a text field: `SetCapabilities (u) 41`, `Properties.Set ContentType (uu)` (`(10, 0)` = TERMINAL for gnome-terminal, `(0, 0)` for Chrome/VS Code), `FocusIn ()`, `SetCursorLocation (iiii)`.
- Per key: `ProcessKeyEvent (uuu)` `(keyval, evdev keycode, state)` → `b`; release has bit 30 set (`1073741824`). Press and release are sent back to back **without waiting for the first reply**, so the daemon must process strictly in arrival order (B2). Example `x`: `(120, 45, 0)` then `(120, 45, 1073741824)`.
- `SetCursorLocation (iiii)` after each preedit change; `Reset ()`, `FocusOut ()` on focus loss.
- Never seen in any run: `SetSurroundingText` (clients send it only when the engine asks), `ListEngines`, `SetEngine`, `GetEngine`, `PropertyActivate`.

Signals the shell consumed correctly from the toy engine: `UpdatePreeditTextWithMode (vubu)` (IBusText `(sa{sv}sv)`, cursor, visible, mode), `CommitText (v)`, `GlobalEngineChanged (s)`; panel calls `RegisterProperties (v)`, `FocusIn (o)`.

## Q4. Which route each app takes

Method (`q4.sh fcitx|ibus`): the whole isolated session gets the environment; both fakes run at once; the fake IBus engine commits words UPPER-CASED, the fake fcitx frontend commits `[word]`; no IME leaves the text unchanged. Typed: `xin chao`.

| Environment | gnome-terminal | Chrome 157 (page textarea) | VS Code 1.145 (editor) |
|---|---|---|---|
| this machine: `GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx XMODIFIERS=@im=fcitx SDL_IM_MODULE=fcitx` | `[xin] [chao]` — fcitx D-Bus (18 `ProcessKeyEvent`, 0 via IBus); `im-fcitx5.so` + `libFcitx5GClient` loaded | `XIN CHAO` — text-input-v3 → shell → IBus (20 via IBus, 0 via fcitx) | `XIN CHAO ` — text-input-v3 → shell → IBus (20 via IBus, 0 via fcitx) |
| Ubuntu default: no `GTK_IM_MODULE`, `XMODIFIERS=@im=ibus` | `XIN CHAO` — `im-wayland.so` → shell → IBus | `XIN CHAO` — same as above | `XIN CHAO ` — same as above |

- All three windows are Wayland clients (`get_client_type() == wayland`); `xlsclients` on the isolated display lists only `mutter-x11-frames`. No app opened an X connection, so **none can use XIM**.
- Chrome: `Google Chrome 157.0.8103.50`, `--ozone-platform=wayland` by default (no flag given). It has `im-fcitx5.so` mapped (GTK4 loads it) but never called the fcitx service. Composition events fired (`#comp=2` in the page), so preedit works.
- VS Code: `1.145.2`, `--ozone-platform=wayland` by default; no IM module loaded.

fcitx5 frontend calls made by gnome-terminal (fcitx5-gtk 5.1.1), in order:
```
org.freedesktop.portal.Fcitx /org/freedesktop/portal/inputmethod org.fcitx.Fcitx.InputMethod1.Version () -> u
…InputMethod1.CreateInputContext (a(ss)) [('display','wayland:'),('program','gnome-terminal-server')] -> (o, ay)
/org/freedesktop/portal/inputcontext/1 org.fcitx.Fcitx.InputContext1.SetCapability (t) 962089451570
…InputContext1.SetCursorRectV2 (iiiid) (25, 69, 0, 0, 1.0)
…InputContext1.FocusIn ()
…InputContext1.ProcessKeyEvent (uuubu) (120, 53, 0, false, 94762095) -> b      # keyval, X keycode (evdev+8), state, isRelease, time
…InputContext1.FocusOut ()
```
- Capability `962089451570` = `0xE001000032`, bits 1, 4, 5, 24, 37, 38, 39 = Preedit, FormattedPreedit, ClientUnfocusCommit, RelativeRect, KeyEventOrderFix, ReportKeyRepeat, ClientSideInputPanel (names from fcitx5 5.1.7 `src/lib/fcitx-utils/capabilityflags.h`). **SurroundingText (bit 6) is not set** for VTE; Password is bit 3, Terminal bit 32 (not set by VTE either).
- Only the portal name and path were used (`org.freedesktop.portal.Fcitx`, `/org/freedesktop/portal/inputmethod`); the `/inputmethod` path on `org.fcitx.Fcitx5` got no call. The module still watches `org.fcitx.Fcitx5` (see Q5), so own both names.
- Signals the module consumed from the toy: `UpdateFormattedPreedit (a(si)i)`, `CommitString (s)`, sent to the caller's unique name.
- Keycode differs per frontend: IBus gets the evdev code (45 for `x`), fcitx gets the X code (53).

## Q5. Already-running apps

```
$ run-heavy.sh bash q5.sh fake
1 typed with first owner: [[first] [owner]|]
2 typed with no fcitx owner (same terminal): [[first] [owner]|no owner|]
3 typed after a new process took org.fcitx.Fcitx5 (same terminal): [[first] [owner]|no owner|{second} {owner}|]
  new owner saw: 1 CreateInputContext, 26 ProcessKeyEvent
shell state after: (true, '"true|us|en"'); new IBus service saw 1 CreateInputContext from the shell
first IBus publisher still alive: yes
```
With a real fcitx5 as first owner (a second, isolated instance: own bus, own HOME, own Wayland display; the live pid 6881 was not touched):
```
$ run-heavy.sh bash q5.sh real
isolated fcitx5 pid 134204 owns org.fcitx.Fcitx5: (':1.28',); live fcitx5 pid(s) untouched: 6881
address files written by fcitx5:
  5105…-unix-2:         IBUS_ADDRESS=unix:path=/tmp/dbus-7EA2sk5Mww,guid=…,fcitx_random_string=708b… IBUS_DAEMON_PID=134204
  5105…-unix-wayland-0: (same)
after fcitx5-remote -e: process alive=no; name owner: … NameHasNoOwner
address files after fcitx5 quit:
  5105…-unix-2: IBUS_ADDRESS= IBUS_DAEMON_PID=
  5105…-unix-wayland-0: IBUS_ADDRESS= IBUS_DAEMON_PID=
2 typed with no fcitx owner (same terminal): [first owner|no owner|]
3 typed after a new process took org.fcitx.Fcitx5 (same terminal): [first owner|no owner|{second} {owner}|]
shell state after: (true, '"true|us|en"'); new IBus service saw 1 CreateInputContext from the shell
```
- fcitx GTK module: with no owner it passes keys through untouched (no fallback to text-input-v3); when a new owner appears it calls `CreateInputContext` again on its own. An app started under fcitx5 keeps working with vr-talex without a restart.
- gnome-shell: reconnects whenever the address string in the file changes, also while the previous publisher is still alive.
- fcitx5 quits cleanly on `fcitx5-remote -e` and leaves both address files in place with empty values, so the installer can stop fcitx5 first and write the file afterwards without a race over deletion.

## Q6. Recommendation

Frontends:
- **(a) this machine (session started with the fcitx5 environment), until the next login:** `fe-ibus` (Chrome, VS Code, every text-input-v3 client, the GNOME indicator, shell entries) **and** `fe-fcitx` (gnome-terminal and every GTK3/GTK4 app, because they inherit `GTK_IM_MODULE=fcitx` from the running shell and have no fallback). Both are needed for AC-5 ("newly opened gnome-terminal and Chrome").
- **(b) default Ubuntu 24.04 Wayland session (ibus environment):** `fe-ibus` alone serves all three AC-2 apps.
- **`fe-xim`: not needed for AC-2 or AC-5** — no AC-2 app is an X11 client in a Wayland session. Per D8 it can be dropped from this feature; it would only matter for XIM-only X11 apps (xterm, some Java/Wine apps) and was not measured in an X11 session.
- **D9's fallback is not needed**: gnome-shell is reached without restart.

Design points for the build tasks:
1. Keep the private path socket for IBus (fail-open on crash, SEC-6); it does not need message routing between peers. Add `Restart=always` to the unit: while the daemon is down, fcitx-route apps and IBus-route apps both get raw keys, nothing is lost.
2. Address file: write `<machine-id>-unix-$WAYLAND_DISPLAY` and `<machine-id>-unix-<DISPLAY number>` (fcitx5 writes both), atomically, with the daemon's own live pid, after the socket listens. Use a new socket path or a changed address string on every start — an identical string is ignored by a client that still holds the old address.
3. On exit close the socket; removing the file is optional (a dead pid already makes libibus ignore it).
4. Install order on a fcitx5 machine: `fcitx5-remote -e` → wait for `org.fcitx.Fcitx5` to lose its owner → start vr-talex (takes `org.fcitx.Fcitx5` + `org.freedesktop.portal.Fcitx`, writes the address files). Measured in the isolated session: shell connected and engine set within 0.5 s of the file; the fcitx module reconnected within the 2 s the script waited. AC-5's 5 s is reachable.
5. `org.fcitx.Fcitx5` has a D-Bus service file (`/usr/share/dbus-1/services/org.fcitx.Fcitx5.service`): if vr-talex is not running, any activation request for that name starts the real fcitx5 again. The installer must keep vr-talex running before anything asks, and T8 should check what `Hidden=true` autostart does not cover.
6. D10: all three apps accepted preedit; none sent surrounding text. VTE via fcitx declares Preedit but not SurroundingText, so the "commit + DeleteSurroundingText" branch has no client among the AC-2 apps.
7. B5: content purpose arrives as `ContentType (uu)` on the IBus side (TERMINAL = 10 seen). gnome-shell's own password dialog also sends its keys through the IBus context (the toy engine received them), so the password check must cover shell entries too.
8. T9 harness: reuse `lib.sh` (guard, tagged cleanup, `wait_win`), `rd.py` (warm-up key), `fake_systemd.py`, the app flags listed in Q1. Chrome text can be read from the window title without DevTools (`q4.sh` page), VS Code from the auto-saved file.

## Open items (need the live desktop or software not on this machine)
- **O1 (user, on return):** one manual run on the real desktop — install, then type in an already-open and a newly opened gnome-terminal, Chrome and VS Code. Everything above was proven only in the isolated session.
- **O2:** stock Ubuntu with ibus-daemon installed could not be reproduced (ibus is not installed; nothing was installed, BASE-17). Unknown: gnome-shell spawns `ibus-daemon` at login (or the unit `org.freedesktop.IBus.session.GNOME.service` does) and it rewrites the address file. The installer needs a tested way to keep it from starting or to publish after it (T8).
- **O3:** X11 session (not Wayland) routes were not measured: GTK apps would use the `ibus` GTK module (libibus client of the same private bus, so several clients connect to `fe-ibus`), Chrome/VS Code the GTK module too, XIM only for XIM-only apps.
- **O4:** Qt apps: Qt5 has no text-input-v3; they need `QT_IM_MODULE=ibus` (Qt's own IBus client, uses the address file) or `fcitx` (served by `fe-fcitx`). Not measured.
- **O5:** environment for the next login (D11's `environment.d` file): on Wayland leaving `GTK_IM_MODULE` unset sends GTK apps through text-input-v3 → IBus; then `fe-fcitx` is only needed for the hot-apply session. Leader/user decision, not made here.
