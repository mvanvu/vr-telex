---
profiled: 2026-11-24
stack: Rust 1.100 (edition 2024) Cargo workspace; Linux user daemon (D-Bus via zbus, X11 via x11rb); POSIX shell install scripts
has_ui: false
mobile_platform: none
tests: cargo test
test (related): cargo test -p <crate> --locked
test (full): cargo test --workspace --locked
lint: cargo clippy --workspace --all-targets --locked -- -D warnings
format: cargo fmt --check
build: cargo build --release --locked
guard: cargo fmt --check && cargo clippy --workspace --all-targets --locked -- -D warnings
audit: cargo-deny / cargo-audit not installed (deny.toml present)
e2e: tests/e2e (T9, headless nested GNOME Shell) — not yet built
test_isolation: per-crate; crates share one Cargo.lock and target dir (compile unit = workspace)
max_agents: 5
max_verifiers: 4
tooling_policy: keep-existing
---

# Project profile — vr-talex

Standalone Vietnamese Telex input method daemon for Ubuntu 24.04+ GNOME. See `.ai-dev-team/workspace/01_spec.md`.

## Conventions
- `#![forbid(unsafe_code)]` in every crate (SEC-27).
- No Debug/Display impl may print typed text (SEC-2); no logging of key data (SEC-1).
- Heavy cargo commands through `$TEAM_BIN/run-heavy.sh`; cargo is in `~/.cargo/bin` (prepend to PATH).
- Tests that need a desktop run only in an isolated headless GNOME Shell (D2, SEC-29).

## Guard map
- any `crates/**` change → guard command above.
