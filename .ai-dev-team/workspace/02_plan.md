# Design: vr-talex — standalone Telex IME daemon for Ubuntu 24.04+ GNOME

Spec: `.ai-dev-team/workspace/01_spec.md` · Decisions: `.ai-dev-team/workspace/decisions.md` (D1–D13) · Threat model: `02_threat-model.md` (SEC-n).
Planned with `ai-dev-team:technical-design` (the superpowers step-by-step code plan format does not fit a multi-agent board; each task brief carries its own detail).

## Overview
One Rust binary, `vr-talex`, run as a systemd **user** service. It contains:
- a pure Telex engine (`telex-core`), no I/O;
- an IME core (`ime-core`): input contexts, one serial key pipeline per context, global VI/EN state, Ctrl+Shift tap detector, preedit/commit policy;
- frontends that translate client protocols into `ime-core` calls:
  - `fe-ibus`: a private D-Bus bus speaking the IBus protocol (serves gnome-shell → all Wayland text-input-v3 apps; the GNOME indicator);
  - `fe-fcitx`: the fcitx5 D-Bus frontend on the session bus (serves apps started with `GTK_IM_MODULE=fcitx` / `QT_IM_MODULE=fcitx`, which is every app on this machine until next login — F2);
  - `fe-xim`: an XIM server for X11 apps using XIM (built only if spike T1 shows it is reached);
- `install.sh` / `uninstall.sh` at the repo root (D1, D11).

No libibus, no ibus-daemon, no fcitx code. Pure-Rust crates only.

## Components (all new)
```
Cargo.toml                (workspace)
crates/telex-core/        lib: Telex state machine, syllable validation, tone placement
crates/ime-core/          lib: Context, KeyEvent, Action, Engine pipeline, Toggle, StateStore
crates/fe-ibus/           lib: mini D-Bus broker + IBus objects (serialization of IBusEngineDesc, IBusText, IBusProperty)
crates/fe-fcitx/          lib: org.fcitx.Fcitx.InputMethod1 / InputContext1 + portal names
crates/fe-xim/            lib: XIM server on x11rb (conditional)
crates/vr-talex/          bin: main, wires frontends to ime-core, systemd notify, address-file writing
packaging/                vr-talex.service, environment.d conf, engine metadata
install.sh, uninstall.sh
tests/e2e/                headless GNOME stress harness (T9)
```

## Contracts between modules
### telex-core
```rust
pub struct Composer { /* per word */ }
impl Composer {
    pub fn new() -> Self;
    /// Feed one printable char (a-z, A-Z). Returns the full current word.
    pub fn push(&mut self, ch: char) -> Outcome;
    /// BackSpace inside a word: removes the last shown character; right after a
    /// tone key it removes that tone instead (T2 quick pass 1).
    pub fn pop(&mut self) -> Outcome;
    pub fn text(&self) -> &str;      // rendered word (Vietnamese or raw fallback)
    pub fn raw(&self) -> &str;       // keys as typed
    pub fn is_empty(&self) -> bool;
    pub fn clear(&mut self);
}
pub enum Outcome { Composing, Invalid /* word now raw passthrough */ }
```
Pure, no allocation surprises, no logging. Rules: spec §4 + D13.

### ime-core
```rust
pub struct KeyEvent { pub keysym: u32, pub keycode: u32, pub state: Mods, pub is_release: bool }
pub enum Action {                      // emitted in order, per key
    UpdatePreedit { text: String, cursor: u32 },
    HidePreedit,
    Commit(String),
    DeleteSurrounding { offset: i32, chars: u32 },
}
pub struct KeyResult { pub handled: bool, pub actions: Vec<Action> }
pub struct Caps { pub preedit: bool, pub surrounding_text: bool, pub password: bool }
pub trait StateStore { fn load(&self) -> Mode; fn save(&self, m: Mode); }
pub enum Mode { Vi, En }

pub struct Ime { /* global mode, contexts */ }
impl Ime {
    pub fn create_context(&mut self) -> CtxId;
    pub fn destroy_context(&mut self, id: CtxId) -> Vec<Action>;  // commits pending text
    pub fn set_caps(&mut self, id: CtxId, caps: Caps);
    pub fn focus_in(&mut self, id: CtxId);
    pub fn focus_out(&mut self, id: CtxId) -> Vec<Action>;      // commit, never drop (B3)
    pub fn reset(&mut self, id: CtxId) -> Vec<Action>;          // commit, never drop
    pub fn process_key(&mut self, id: CtxId, ev: KeyEvent) -> KeyResult; // synchronous, B2
    pub fn mode(&self) -> Mode;
    pub fn subscribe_mode(&mut self) -> ModeWatch;                // for the indicator
}
```
`process_key` is synchronous and O(word length); each frontend calls it from one task per connection and replies to the client before reading the next message for that context (B2). Toggle (D7) lives here; modifier events always return `handled: false`.

### fe-ibus (private bus)
- Listens on `unix:path=$XDG_RUNTIME_DIR/vr-talex/ibus-<rand>` (0700 dir, 0600 socket, SO_PEERCRED uid check — SEC-n).
- Writes `~/.config/ibus/bus/<machine-id>-unix-<wayland-0|:0>` (`IBUS_ADDRESS=…`, `IBUS_DAEMON_PID=…`) atomically; removes it on exit.
- Implements: `org.freedesktop.DBus` (Hello, RequestName, ReleaseName, GetNameOwner, NameHasOwner, AddMatch, RemoveMatch, ListNames; NameOwnerChanged signal; message routing between peers), `org.freedesktop.IBus` (ListEngines, ListActiveEngines, GetEngineByName, CreateInputContext, SetGlobalEngine, GetGlobalEngine, Exit, properties `Engines`, `ActiveEngines`, `GlobalEngine`, `PreloadEngines`, `UseGlobalEngine`, `EmbedPreeditText`), `org.freedesktop.IBus.InputContext` (ProcessKeyEvent, SetCursorLocation*, FocusIn, FocusOut, Reset, SetCapabilities, SetEngine, GetEngine, SetSurroundingText, SetContentType, signals CommitText, UpdatePreeditText(WithMode), ShowPreeditText, HidePreeditText, DeleteSurroundingText, ForwardKeyEvent (never used for editing)).
- Panel: forwards `RegisterProperties` / `UpdateProperty` with key `InputMode`, symbol `VI` / `EN` to `org.freedesktop.IBus.Panel` owned by gnome-shell.
- One engine: name `vr-talex`, longname `Vietnamese (Telex)`, language `vi`, symbol `VI`, layout `us`.
- Exact wire formats are taken from the IBus source (`src/ibusserializable.c`, `ibustext.c`, `ibusenginedesc.c`, `ibusproperty.c`, `bus/ibusimpl.c`, `bus/inputcontext.c`) read online; no code copied (licence), behaviour reimplemented.

### fe-fcitx (session bus)
- Owns `org.fcitx.Fcitx5` and `org.freedesktop.portal.Fcitx` (only after the real fcitx5 has quit).
- `/org/freedesktop/portal/inputmethod`: `org.fcitx.Fcitx.InputMethod1.CreateInputContext(a(ss)) -> (o, ay)`; `/inputcontext/N`: `org.fcitx.Fcitx.InputContext1` FocusIn, FocusOut, Reset, SetCursorRect(V2), SetCapability(t), SetSurroundingText(Position), ProcessKeyEvent(uuubu) -> b, DestroyIC; signals CommitString(s), UpdateFormattedPreedit(a(si)i), DeleteSurroundingText(iu), ForwardKey (unused). Also the older `/inputmethod` `org.fcitx.Fcitx.InputMethod1` path used by fcitx5-gtk.
- Capability bits mapped to `Caps` (preedit, surrounding text, password).

### fe-xim (conditional)
- x11rb + the `xim` crate (server side), styles PreeditCallbacks|StatusNothing and PreeditNothing; registers under the server name in `XMODIFIERS` at install time.

### vr-talex (bin)
- Starts frontends, persists mode in `$XDG_STATE_HOME/vr-talex/mode`, never logs key data (SEC), exits cleanly on SIGTERM and removes the IBus address file.

## Decisions
| Decision | Options | Choice | Why |
|---|---|---|---|
| Async runtime | tokio, async-io (zbus default), threads | tokio (current-thread per frontend) + zbus `tokio` feature | one runtime, simple serial per-connection tasks |
| D-Bus | zbus, dbus-rs (libdbus C) | zbus 6.x | pure Rust, no libdbus (G2) |
| IBus private bus | reuse session bus, own broker | own minimal broker | gnome-shell talks to a private bus by address file (F1) |
| X11 | x11rb + xim crate, Xlib | x11rb + xim | pure Rust |
| Edit model | preedit / surrounding delete / fake backspace | preedit first, surrounding delete second, never fake keys (D10) | the reason the project exists |
| Install | .deb/PPA, git repo script | git repo user-level script (D1) | no sudo, reversible |

## Toolchain
| Tool | Version | Source |
|---|---|---|
| Rust | 1.100.0 stable, edition 2024 | `rustc --version` on this machine |
| zbus | 6.5.0 | `cargo search` 2026-11-24 |
| tokio | 1.54.1 | `cargo search` |
| x11rb | 0.14.0 | `cargo search` |
| xim | 0.6.0 | `cargo search` |
Lockfile committed. `cargo deny` / `cargo audit` in CI-less local check (SEC).

## Risks
- R1 hot apply (spike T1 first; fallback D9).
- R2 IBus protocol surface — mitigated by T1 recording the exact calls gnome-shell 46 makes (dbus-monitor on the private bus of a real ibus or by logging in the prototype broker).
- R3 Chrome/VS Code route — T1 measures which frontend they use on this machine (fcitx module vs Wayland text-input vs XIM).
- R4 E2E automation — T9 on headless gnome-shell + RemoteDesktop API (D12).

## Tasks
See `02_tasks.md`.
Critical path: `T1 ∥ T2 → T4 → T5 → T9 run → sign-off → Phase 5`.
Integration points: the workspace `Cargo.toml` members list and the `crates/vr-talex/src/main.rs` frontend wiring are written by T2 (all crates created empty with a `pub async fn run(ime: SharedIme) -> Result<()>` stub per frontend); T5/T6/T7 only fill their own crate. `Cargo.lock` is shared → T5, T6, T7 run each in its own git worktree, merged by the leader one at a time.
