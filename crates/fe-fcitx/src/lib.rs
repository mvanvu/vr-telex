//! fcitx5 D-Bus frontend on the session bus.
//!
//! Placeholder until T6: `run` returns at once.
#![forbid(unsafe_code)]

use ime_core::SharedIme;

/// Serves the frontend until it stops or fails.
pub async fn run(_ime: SharedIme) -> ime_core::Result<()> {
    Ok(())
}
