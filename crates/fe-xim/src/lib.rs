//! XIM server for X11 clients.
//!
//! Placeholder until T7: `run` reports ready and returns at once.
#![forbid(unsafe_code)]

use ime_core::{Ready, SharedIme};

/// Serves the frontend until it stops or fails.
///
/// The contract with the daemon (`vr-telex` main), the same for every frontend:
/// - Call `ready.notify()` once clients can reach the frontend (socket
///   listening, bus names owned, address file written). The daemon sends
///   `READY=1` to systemd only after every frontend is ready.
/// - Return `Ok(())` only when the frontend is not needed on this machine
///   (nothing to serve). That also counts as ready; the others keep running.
/// - Return `Err` on any failure. The daemon then exits with a failure and
///   systemd restarts it, all frontends together. The error text must not
///   carry typed text (SEC-1).
pub async fn run(_ime: SharedIme, ready: Ready) -> ime_core::Result<()> {
    ready.notify();
    Ok(())
}
