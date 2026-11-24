# vr-talex

A standalone Vietnamese Telex input method daemon for Ubuntu 24.04+ (GNOME, Wayland and X11).
One Rust binary serves the IBus protocol (gnome-shell), the fcitx5 D-Bus protocol and XIM,
without ibus-daemon or fcitx5.

Status: **in development** — not usable yet.

## Build

Requires the stable Rust toolchain (1.100 or newer).

```sh
cargo build --release --locked
cargo test --workspace --locked
```

License: MIT.
