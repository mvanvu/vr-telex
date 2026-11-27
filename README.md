# vr-telex

A standalone Vietnamese Telex input method for Ubuntu 24.04+ GNOME (Wayland). It is one
Rust binary that speaks the IBus and fcitx5 D-Bus protocols itself, so GNOME and apps
talk to it directly; it uses no ibus, fcitx or bamboo libraries. It runs as a systemd
user service for the current user only.

## Requirements

- Ubuntu 24.04 or newer with GNOME (tested on GNOME 46, Wayland).
- To build: the stable Rust toolchain (rustup, 1.100 or newer).
- `ibus-daemon` must not be running. Install refuses, and changes nothing, while it is.
  Stop it first, for example `ibus exit`, or end the process that started it (an
  `im-config` autostart, for instance), then run `./install.sh` again.
- fcitx5 needs no action: install stops it and takes over; uninstall starts it again.

## Install

### From the latest release (Ubuntu 24.04+, amd64)

Run as your own user, without `sudo`:

```sh
wget -qO- https://github.com/mvanvu/vr-telex/releases/latest/download/vr-telex-install.sh | sh
```

The script is piped into `sh`. To read it first, download it with
`wget -qO vr-telex-install.sh https://github.com/mvanvu/vr-telex/releases/latest/download/vr-telex-install.sh`
and run `sh vr-telex-install.sh`.

The script downloads the latest release's `SHA256SUMS`, its signature `SHA256SUMS.asc`
and the `.deb` into a temp dir, checks the signature against the release key built into
the script (fingerprint `2C30E91F97E5A566BEFF373736C30B9165329B85`, also in this repository
at `packaging/apt/vr-telex.asc`) and the `.deb`'s SHA-256, and stops before `sudo` if any
check fails. Then it runs `sudo apt install -y` on the `.deb` (sudo asks for your
password) and `vr-telex-setup`, and removes the temp dir. It refuses to run as root.

The first run does not check the script itself: `vr-telex-install.sh` is trusted on
HTTPS alone, and the signature only protects the steps after it (the `.deb`, and later
`vr-telex-update`). To check it by hand first, download `vr-telex-install.sh`,
`SHA256SUMS` and `SHA256SUMS.asc` from the release page and `packaging/apt/vr-telex.asc`
from this repository, then run `gpg --import vr-telex.asc`,
`gpg --verify SHA256SUMS.asc SHA256SUMS` (check that it reports the key
`2C30E91F97E5A566BEFF373736C30B9165329B85`) and `sha256sum -c --ignore-missing SHA256SUMS`.

The package installs files system-wide (`/usr/bin/vr-telex`, `/usr/bin/vr-telex-setup`,
`/usr/bin/vr-telex-update`, the `vr-telex.service` user unit, the release key as
`/usr/share/keyrings/vr-telex.gpg`), adds the apt source
`/etc/apt/sources.list.d/vr-telex.sources` (see Update) and does not touch running
sessions. `vr-telex-setup` does the per-user part, as your own user without `sudo`: it
starts `vr-telex.service`, sets the input sources and saves the previous setup, as
`./install.sh` does below. Each other user who wants vr-telex runs `vr-telex-setup` once.
It works at once; Qt and X11 apps pick it up after the next login.

**Update:** new releases come with the system updates:

```sh
sudo apt update && sudo apt upgrade
```

If you installed vr-telex 0.1.1 or older, run `vr-telex-update` once (see below): those
versions do not add the apt source. From 0.1.2 on, apt updates vr-telex.

The package's apt source points at the apt repository published with each GitHub release
(the latest one only), and apt checks it with the release key above, used for this source
only. Run `sudo apt update` right before `sudo apt upgrade`, as above: once a newer release
is out, package lists read before it can make the download fail (`404 Not Found` or a hash
mismatch), and another `sudo apt update` fixes that. The upgrade replaces the program but does not restart the vr-telex you are running,
so then run, as your own user:

```sh
vr-telex-setup
```

It reloads your systemd user manager, writes the per-user files again from the new package
(`~/.config/environment.d/90-vr-telex.conf`, `~/.xinputrc`, the fcitx5 autostart override
and D-Bus service file; a copy you edited since is moved aside, not overwritten), keeps the
backup from the first run, puts Vietnamese (Telex) first again and restarts vr-telex on the
new version. Until you run it (or restart the computer) the old version keeps running.
Other users of the machine run `vr-telex-setup` again themselves.

To stop apt from updating vr-telex, add the line `Enabled: no` to
`/etc/apt/sources.list.d/vr-telex.sources`; the package keeps a file you edited.

Alternatively, update without apt by running the install script the package installs:

```sh
vr-telex-update
```

It checks the latest release the same way as the install command, prints
`already up to date` when you have it, and otherwise installs the new version and runs
`vr-telex-setup` for you.

**Remove:** first undo the per-user setup while the package is still installed, then remove
the package:

```sh
vr-telex-setup --remove
sudo apt remove vr-telex
```

`sudo apt remove vr-telex` also removes the apt source and the release key, so
`apt update` stops checking for vr-telex. `sudo apt purge vr-telex` removes nothing more
from the system: the package keeps no configuration of its own, and the per-user files are
what `vr-telex-setup --remove` restores.

### From source

```sh
git clone https://github.com/mvanvu/vr-telex.git
cd vr-telex
./install.sh
```

Run it as your own user, without `sudo`. It works at once; Qt and X11 apps pick it up
after the next login. It:

1. builds the release binary (`cargo build --release --locked`);
2. installs it to `~/.local/bin/vr-telex` and starts the `vr-telex.service` systemd user
   unit;
3. makes the input sources English (US) and "Vietnamese (Telex)" and selects
   Vietnamese (Telex);
4. saves the previous setup (input sources, fcitx5 state, the files it replaces) under
   `~/.local/share/vr-telex/backup/`.

If the daemon does not come up healthy, install rolls everything back and exits
non-zero. Running it again changes no file; it only restarts the daemon (about 1 s).
One install kind per user is active at a time, and switching needs no uninstall first:

- From source to the package: run the install command above (it runs
  `vr-telex-setup`). It replaces the from-source install (its `~/.local/bin/vr-telex`
  and user unit go; a copy you edited is moved aside) and keeps the backup from the first
  install, so `vr-telex-setup --remove` still restores the setup from before vr-telex.
- From the package back to source: run `./install.sh`. It takes over with its own
  binary and unit and keeps the same backup, so `./uninstall.sh` restores the setup from
  before either; then `sudo apt remove vr-telex` if you no longer want the package.

### Upgrading from vr-talex

The project was first published as `vr-talex`. If that install is present, `./install.sh`
and `vr-telex-setup` move it to `vr-telex` automatically: they stop and remove
`vr-talex.service`, move the saved setup from `~/.local/share/vr-talex/backup/` to
`~/.local/share/vr-telex/backup/` (so uninstalling still restores the setup from before
vr-talex), rename the input source in place so Vietnamese (Telex) stays selected, and keep
your VI/EN mode. Files at vr-talex paths that are not what the vr-talex installer wrote are
left in place with a warning. If the new daemon does not come up, the vr-talex install is
put back and started again. `./uninstall.sh` also removes a vr-talex install directly.

## Usage

| Keys | Effect |
|---|---|
| Ctrl+Space | Switch input source between English (US) and Vietnamese (Telex). This is GNOME's "switch input source" shortcut; on stock GNOME it is Super+Space, so set it to Ctrl+Space in Settings > Keyboard if you want that. |
| Ctrl+Shift, tapped alone | With Vietnamese (Telex) selected: toggle Vietnamese and English. The top-bar indicator shows `vi` or `en`. Ctrl+Shift+T, Ctrl+Shift+C and other shortcuts are not affected. |

With English (US) selected the IME is off and keys pass through unchanged. The word being
typed is shown underlined and committed at the next space, punctuation or focus change.
Password fields receive keys unchanged.

Telex rules:

| Keys | Result |
|---|---|
| `s` `f` `r` `x` `j` | sắc, huyền, hỏi, ngã, nặng; the tone key can come anywhere after the vowel (`vieetj` → việt) |
| `z` | removes the tone |
| `aa` `ee` `oo` | â ê ô |
| `aw` `ow` `uw` | ă ơ ư |
| `w` alone at a vowel position | ư |
| `uow`, `uwow` | ươ |
| `dd` | đ |
| the same key again | undoes the change and types the key (`ass` → as, `ddd` → dd) |

The tone goes on the modern position (`hoà`, `thuý`). Upper case is kept per letter
(`Vieetj` → Việt). A word that cannot be Vietnamese (`class`, `https`, `git`) stays exactly
as typed.

### English words

When a word ends (space, punctuation, Enter, focus change), the IME checks it once more:

- a word that is only the start of a Vietnamese syllable goes back to the keys typed
  (`use`, `user`, `two`, `aw`); words without a vowel keep their letters (`dd` → đ);
- an English word whose Vietnamese form is not a real syllable goes back to the keys
  typed, in the case typed;
- a word that is both (`best` / bét, `list` / lít) follows the previous word in the same
  field: after an English word it stays English (`the best`, `use the best`), otherwise it
  stays Vietnamese (`rất bét`, or first in the field). A common English word typed as is
  (`the`, `with`, `would`) counts as English; any other word typed as is (`ba`, `to`) does
  not change the previous word's language; focus changes and toggles reset it.

There is no setting and nothing to undo: retype the word if it came out wrong. The word
lists are built into the binary (sources and licences in `tools/wordlists/README.md`
and `THIRD-PARTY-NOTICES.md`); nothing is read or downloaded at run time.

## Known limits

| Limit | Detail |
|---|---|
| `aa` `ee` `oo` must be adjacent | The two keys must be next to each other to change the vowel. |
| Some words cannot be typed | `uow` always gives `ươ`, so `thuở` and `huơ` are not possible. |
| VS Code integrated terminal | Letters can be lost when keys arrive faster than about 30 ms apart. This is an xterm.js limitation; human typing is far slower. |
| Chrome address bar | Tab moves focus to the suggestion's remove button (Chrome's own behaviour, in English too). Use Enter, or → / End then Enter. |
| Qt apps | They need the fcitx5 Qt frontend package (`fcitx5-frontend-qt5` and/or `fcitx5-frontend-qt6`). Without it Qt apps have no Vietnamese input. Qt apps started before install keep receiving raw keys until restarted; nothing is lost. |

## Uninstall

```sh
./uninstall.sh
```

Stops and removes everything install wrote, restores the saved input sources and files,
and starts fcitx5 again if it was in use and is still installed. A file you changed after
install is kept as `<file>.vr-telex-saved-<date>` (with a warning) before the original
is restored.

## Troubleshooting

Keys pass through unchanged while the daemon is down, so plain English typing keeps
working.

```sh
systemctl --user status vr-telex.service
systemctl --user restart vr-telex.service
journalctl --user -u vr-telex.service
```

The unit restarts the daemon after a crash and never gives up. The delay grows with each
crash in the session, from 1 s up to 15 s; `restart` resets it.

If typing breaks and you want it gone:

```sh
systemctl --user disable --now vr-telex.service
./uninstall.sh
```

## Security and residual risks

The daemon opens only Unix sockets, writes no keystrokes to disk or logs, disables core
dumps, and serves only processes of your own user. These risks remain and are accepted:

- Same-user processes can read keystrokes. On X11 any process of your user can already
  record keys through the X server, and on both X11 and Wayland a process of your user
  can watch the session bus (next point). vr-telex does not add isolation the session
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

## Development

```sh
cargo build --release --locked
cargo test --workspace --locked
bash tests/install/run.sh   # install/uninstall in a throwaway sandbox HOME and bus
tests/e2e/run.sh            # end-to-end run; see tests/e2e/README.md
```

License: MIT.
