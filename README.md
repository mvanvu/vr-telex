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

### With apt (Ubuntu 24.04+, amd64)

First download the repository key and check it. The last line checks that the file
holds exactly one key, with fingerprint `2C30E91F97E5A566BEFF373736C30B9165329B85`;
otherwise it prints `vr-telex: wrong key, stopping`, deletes the file and fails. Do not
go on in that case.

```sh
sudo install -d -m 0755 /etc/apt/keyrings
sudo wget -qO /etc/apt/keyrings/vr-telex.gpg https://mvanvu.github.io/vr-telex/vr-telex.gpg
[ "$(gpg --show-keys --with-colons /etc/apt/keyrings/vr-telex.gpg 2>/dev/null | grep "^fpr")" = "fpr:::::::::2C30E91F97E5A566BEFF373736C30B9165329B85:" ] || { echo "vr-telex: wrong key, stopping" >&2; sudo rm -f /etc/apt/keyrings/vr-telex.gpg; false; }
```

Then add the repository, install the package and turn it on for your user:

```sh
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/vr-telex.gpg] https://mvanvu.github.io/vr-telex stable main" |
  sudo tee /etc/apt/sources.list.d/vr-telex.list
sudo apt update
sudo apt install vr-telex
vr-telex-setup
```

The same public key is in this repository at `packaging/apt/vr-telex.asc`. apt checks the
repository signature with this key only (`signed-by`); it is not added to the keys apt
trusts for other repositories.

The package installs files system-wide (`/usr/bin/vr-telex`, `/usr/bin/vr-telex-setup`,
the `vr-telex.service` user unit) and does not touch running sessions. `vr-telex-setup`
does the per-user part, as your own user without `sudo`: it starts `vr-telex.service`,
sets the input sources and saves the previous setup, as `./install.sh` does below. Each
user who wants vr-telex runs it once. It works at once; Qt and X11 apps pick it up after the
next login.

**Update:** `sudo apt update && sudo apt upgrade`, then run `vr-telex-setup` again as your
user. It reloads your systemd user manager (so a changed `vr-telex.service` is loaded),
writes the per-user files again from the new package (`~/.config/environment.d/90-vr-telex.conf`,
`~/.xinputrc`, the fcitx5 autostart override and D-Bus service file; a copy you edited since
is moved aside, not overwritten), keeps the backup from the first run, puts Vietnamese
(Telex) first again and restarts vr-telex on the new version. Without it the new version
starts only at the next login, and those files keep their old content. If `apt update`
reports `EXPKEYSIG` for vr-telex, the repository key was renewed: run the first block above
again (same fingerprint, so the check still passes).

**Remove:** first undo the per-user setup while the package is still installed, then remove
the package:

```sh
vr-telex-setup --remove
sudo apt remove vr-telex
```

To drop the repository as well: `sudo rm /etc/apt/sources.list.d/vr-telex.list
/etc/apt/keyrings/vr-telex.gpg`.

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

- From source to the apt package: install the package and run `vr-telex-setup`. It
  replaces the from-source install (its `~/.local/bin/vr-telex` and user unit go; a copy
  you edited is moved aside) and keeps the backup from the first install, so
  `vr-telex-setup --remove` still restores the setup from before vr-telex.
- From the apt package back to source: run `./install.sh`. It takes over with its own
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
