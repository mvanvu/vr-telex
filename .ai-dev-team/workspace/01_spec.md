# Spec — vr-talex: standalone Vietnamese Telex input method for Ubuntu

```
has_ui: false            # no screens; only the GNOME top-bar input indicator label (VI / EN)
security_sensitive: true # the daemon sees every keystroke, including passwords
mobile_platform: none
```

## 1. Intent and why
A new Vietnamese input method written from scratch in Rust for Ubuntu 24.04 and later (GNOME, Wayland and X11 sessions).
The reason it exists: existing IBus-based Vietnamese engines (ibus-bamboo, ibus-unikey) **drop or duplicate characters ("nuốt chữ") when typing fast**, mostly in **Chrome, VS Code and terminals**. Root causes we design against:
1. Engines that fix a word by sending fake BackSpace key events and re-typing; under fast typing the real and fake events reach the app out of order.
2. Asynchronous key handling where a later key is answered before an earlier one, and preedit text discarded on focus change, mouse click or app reset.

Success = zero lost, duplicated or reordered characters in the stress test of §6 in Chrome, VS Code and gnome-terminal, while being dead simple to use.

## 2. Goals
- G1. Telex only (standard rules, §4). No other method, no settings UI, no config file the user must touch.
- G2. Fully independent: no libibus, no ibus-daemon, no fcitx, no bamboo/unikey code. Pure-Rust crates (D-Bus, X11 protocol) are allowed.
- G3. Install from this git repo with one command (`./install.sh`), user level, no sudo, **applies immediately** — no logout, no reboot.
- G4. On install, add the Vietnamese input source to GNOME input sources if not already there; make vr-talex the active input method framework (stopping fcitx5 / ibus if running) and restore the previous state on uninstall.
- G5. Toggle Vietnamese/English with **Ctrl+Shift tapped alone** (press both, release with no other key in between). The GNOME top-bar indicator shows `VI` or `EN`. Last state remembered across logins.
- G6. No lost characters (§6 stress test is the main acceptance gate).

## 3. Non-goals / anti-goals
- Non-goals: VNI, VIQR or any other method; spell-checking; macros; tray icon or settings window; KDE/other desktops (may work, untested); .deb/PPA (later, see decisions D1); Ubuntu < 24.04.
- Anti-goals (failure even if it "works"):
  - Any fake BackSpace / synthetic key injection to edit text.
  - Any log, file or debug output that contains typed text or key sequences (keylogger risk).
  - Requiring logout/reboot after install.
  - Breaking Ctrl+Shift+<key> shortcuts (e.g. Ctrl+Shift+T, Ctrl+Shift+P, Ctrl+Shift+C/V in terminals).

## 4. Telex rules (D5)
- Tones: `s` sắc, `f` huyền, `r` hỏi, `x` ngã, `j` nặng, `z` removes tone. Tone keys may come anywhere after the vowel, including at the end of the word (`vieetj` → `việt`).
- Letters: `aa`→â, `ee`→ê, `oo`→ô, `aw`→ă, `ow`→ơ, `uw`→ư, `dd`→đ, `w` alone at a vowel position → ư, `uow`/`uwow` → ươ. Upper case kept per letter (`VIEETJ`→`VIỆT`, `Vieetj`→`Việt`).
- Undo by repeating: pressing the same transform key again removes the transform and outputs the key literally (`ass`→`as`, `aaa`→`aa`, `ddd`→`dd`, `ww`→`w`).
- Modern tone placement: `hoà`, `thuý`, `khoẻ`; `qu`/`gi` handled (`quý`, `giá`).
- Non-Vietnamese words (no valid Vietnamese syllable can be formed, e.g. `class`, `https`, `git`) are left exactly as typed: once a word becomes invalid, the raw keys are restored and the rest of the word passes through.
- Word boundary: space, punctuation, Enter, Tab, digits, arrows, any key with Ctrl/Alt/Super, mouse click, focus change.

## 5. Behaviour
- B1. **Composition**: the current word is shown as preedit (underlined) where the client supports preedit, and committed exactly once at the word boundary. No BackSpace injection. Where a client has no preedit (XIM over-the-spot fallback, terminals that ignore preedit), the client-supported equivalent is chosen by the plan; fake keys are still forbidden.
- B2. **Ordering**: every key event is handled strictly in arrival order by one serial state machine per input context; the reply for key N is sent before key N+1 is processed. Keys the engine does not handle are returned "not handled" in order.
- B3. **Never drop**: on focus-out, reset, mouse click, cursor move, toggle to EN, or client disconnect, the preedit is committed (not discarded).
- B4. **Toggle**: Ctrl+Shift tapped alone toggles VI/EN globally (all windows). Ctrl+Shift followed by any other key does not toggle and the shortcut reaches the app.
- B5. **Password fields**: when the client marks the field as password/hidden (content purpose), the engine passes keys through untouched.
- B6. **Indicator**: the GNOME input-source indicator shows `VI` / `EN`.
- B7. **Install** (`./install.sh`): build release, install binaries to `~/.local`, a systemd user unit, start the daemon now; add the Vietnamese source to `org.gnome.desktop.input-sources sources` if absent and select it; stop and disable fcitx5/ibus autostart for this user (saving the previous settings); set the IM environment for newly launched apps. Idempotent (running twice changes nothing).
- B8. **Uninstall** (`./uninstall.sh`): stop and remove everything installed, restore saved input sources and the previous IM framework, start it again.

## 6. Acceptance criteria
- AC-1 Given VI mode, when Telex sequences of the golden list (≥ 2,000 cases: every tone × vowel nucleus, `ươ`, `qu`/`gi`, caps, undo-by-repeat, English words) are fed to the engine, then output matches the expected string for every case.
- AC-2 Given vr-talex installed in a GNOME 46 session, when ~5,000 mixed Vietnamese/English words are typed at 15 ms per key into gnome-terminal, Chrome (text area and address bar) and VS Code (editor and integrated terminal), then the text in each app equals the expected text character for character (0 lost, 0 duplicated, 0 reordered). Run 3 times per app.
- AC-3 Given a word in preedit, when the user clicks elsewhere, switches window or the app resets the context, then the word is committed, not lost.
- AC-4 Given any mode, when Ctrl+Shift is tapped alone, then the mode toggles and the indicator shows the new mode within 100 ms; when Ctrl+Shift+T (or +P, +C, +V) is pressed, then the mode does not change and the app receives the shortcut.
- AC-5 Given a fresh user session with fcitx5 running and sources `[('xkb','us')]`, when `./install.sh` runs, then without logout typing Vietnamese works in a newly opened gnome-terminal and Chrome within 5 s, and the sources list contains the Vietnamese source exactly once; running it a second time changes nothing.
- AC-6 Given vr-talex installed, when `./uninstall.sh` runs, then the input sources and IM framework are back to the pre-install state and fcitx5 (if it was used) works again without logout.
- AC-7 Given a password field, when typing `matkhau1s`, then the field receives exactly `matkhau1s`.
- AC-8 Given VI mode, when the user logs out and back in, then the mode is still VI (and EN likewise).
- AC-9 Given the daemon running for a typing session, then no file, journal entry or stderr line contains typed characters; the D-Bus/X endpoints are reachable only by the same user.
- AC-10 Key handling latency: p99 < 5 ms per key in the daemon (measured in the stress test).

## 7. Constraints and facts found
- This machine: Ubuntu 24.04.5, GNOME Shell 46, Wayland session, ibus not installed, fcitx5 5.1.7 running, Rust 1.100 in `~/.cargo/bin`.
- On GNOME Wayland, Mutter forwards text input (text-input-v3) only to an IBus D-Bus service; GNOME has no zwp_input_method_v2. So the daemon must implement the IBus D-Bus protocol itself (as fcitx5 does).
- X11 apps (Chrome, VS Code, Electron under XWayland; everything in an X11 session) get input through XIM or a toolkit IM module. No IBus client library is allowed, so the daemon also implements an XIM server in Rust.
- Hot apply depends on how gnome-shell's IBus client finds the bus (IBus address file / env) — risk R1, proven first by a spike.

## 8. Risks
- R1 Hot apply without logout may not reach gnome-shell or already-running X11 apps. Mitigation: spike T1 before anything else; fallback documented (restart only the affected app, never logout).
- R2 IBus protocol surface needed by gnome-shell is large (engine desc, properties, InputContext signals, ContentType, SurroundingText).
- R3 XIM preedit behaviour differs per toolkit (Chrome/Electron).
- R4 Test automation of real apps in a headless GNOME session (input injection, reading back text).

## 9. Decisions
See `decisions.md` D1–D5.
