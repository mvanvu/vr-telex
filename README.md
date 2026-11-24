# vr-talex

A Vietnamese Telex input method daemon for Ubuntu 24.04+ GNOME (Wayland and X11).
One Rust binary serves the IBus protocol that gnome-shell uses and the fcitx5 D-Bus
protocol, so neither ibus-daemon nor fcitx5 needs to run. It runs as a systemd user
service for the current user only.

## Supported environment

- Ubuntu 24.04 or newer with GNOME (tested on GNOME 46).
- The stable Rust toolchain (1.100 or newer) to build from this checkout.
- Install refuses, and changes nothing, while ibus-daemon is running. An existing
  fcitx5 is stopped during install and started again by uninstall. Known limit: an
  ibus-daemon started outside GNOME's IBus unit (e.g. by im-config) while fcitx5 also
  runs is not detected; stop it before installing.

## Install

From the root of this checkout, as your own user (no `sudo`):

```sh
./install.sh
```

The script builds the release binary, installs it to `~/.local/bin/vr-talex`, starts the
`vr-talex.service` user unit, adds "Vietnamese (Telex)" to the GNOME input sources and
selects it. It saves the previous setup first (input sources, fcitx5 state, the files it
replaces) under `~/.local/share/vr-talex/backup/`. Running it again changes nothing.
If the daemon does not come up healthy, install rolls everything back and exits non-zero.

It applies without logging out:

- Apps on the IBus route (gnome-shell, GTK 4 apps, Chrome, the VS Code editor) reconnect
  on their own.
- Apps on the fcitx route (for example gnome-terminal, a GTK 3 app started with
  `GTK_IM_MODULE=fcitx`) reconnect on their own.
- Qt apps started before install keep receiving raw keys until they are restarted or you
  log in again. Nothing is lost; the keys are just not composed.

## Uninstall

```sh
./uninstall.sh
```

Stops and removes everything install wrote, restores the saved input sources and files,
and starts fcitx5 again if it ran before. A file you edited after install is not deleted:
it is moved aside as `<name>.vr-talex-saved-<date>` and the script names it.

## Usage

- Tap Ctrl+Shift alone (press both, release with no other key in between) to switch
  between Vietnamese (`VI`) and English (`EN`) in all windows. The top-bar indicator
  shows the mode, and the last mode is kept across logins. Ctrl+Shift+T, Ctrl+Shift+C
  and other shortcuts reach the app and do not switch the mode.
- The word being typed is shown underlined and committed at the next space, punctuation
  or focus change.
- Fields the app marks as password fields receive keys unchanged.

Telex rules:

| Keys | Result |
|---|---|
| `s` `f` `r` `x` `j` | sắc, huyền, hỏi, ngã, nặng (anywhere after the vowel: `vieetj` → việt) |
| `z` | removes the tone |
| `aa` `ee` `oo` | â ê ô |
| `aw` `ow` `uw` | ă ơ ư |
| `w` alone at a vowel position | ư |
| `uow`, `uwow` | ươ |
| `dd` | đ |
| the same key again | undoes the change and types the key (`ass` → as, `ddd` → dd) |

Upper case is kept per letter (`Vieetj` → Việt). A word that cannot be Vietnamese
(`class`, `https`, `git`) is left exactly as typed.

Known limits:

- `aa`, `ee`, `oo` change the vowel only when the two keys are next to each other.
- `uow` always gives `ươ`, so `thuở` and `huơ` cannot be typed.
- After undo by repeating a key, the rest of the word stays raw, so `xoong` cannot be
  typed.
- VS Code integrated terminal: letters can be lost at high key rates. Under
  investigation.

## If typing breaks

Keys pass through unchanged while the daemon is down, so plain English typing keeps
working. To check or restart the daemon:

```sh
systemctl --user status vr-talex.service
systemctl --user restart vr-talex.service
journalctl --user -u vr-talex.service
```

The unit restarts the daemon by itself after a crash and never gives up. The delay grows
with each crash in the session, from 1 s up to 15 s; `systemctl --user restart
vr-talex.service` resets it.

To remove it completely without typing in Vietnamese mode:

```sh
systemctl --user disable --now vr-talex.service
./uninstall.sh
```

## Security and residual risks

The daemon opens only Unix sockets, writes no keystrokes to disk or logs, disables core
dumps, and serves only processes of your own user. These risks remain and are accepted:

- Same-user processes can read keystrokes. On X11 any process of your user can already
  record keys through the X server, and on both X11 and Wayland a process of your user
  can watch the session bus (next point). vr-talex does not add isolation the session
  lacks.
- Text on the fcitx route crosses the session bus. Any unconfined process of your user
  can monitor the session bus and see the composed text of apps on that route, as with
  stock fcitx5. The IBus route uses a private socket instead.
- Flatpak apps reach the daemon through `org.freedesktop.portal.Fcitx`, which the default
  Flatpak policy allows. Such an app cannot read the text of other apps, but it can switch
  the global VI/EN mode and observe which mode is active.
- Composed text can remain in freed D-Bus message buffers until the memory is reused; it
  is not wiped. Reading it needs a core dump (disabled) or access to the daemon's memory.
- A crash or restart of the daemon loses the word in progress. Keys typed while it is
  down pass through raw.

## Build and test

```sh
cargo build --release --locked
cargo test --workspace --locked
bash tests/install/run.sh   # install/uninstall in a throwaway sandbox HOME and bus
```

License: MIT.
