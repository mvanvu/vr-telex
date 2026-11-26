//! fcitx5 D-Bus frontend on the session bus.
//!
//! Serves applications that load the fcitx5 IM module (`GTK_IM_MODULE=fcitx`),
//! which on a machine that ran fcitx5 is every app started before the next
//! login (decisions D8, D19). It owns `org.fcitx.Fcitx5` and
//! `org.freedesktop.portal.Fcitx` and speaks the part of the fcitx5 D-Bus
//! frontend protocol (`org.fcitx.Fcitx.InputMethod1`,
//! `org.fcitx.Fcitx.InputContext1`) that the fcitx5-gtk module uses.
//!
//! How the `ime-core` rules are kept:
//! - One reader takes every message off the bus and hands it to the task of
//!   the connection that sent it; nothing else is done there, so no client
//!   can hold up another (rule 7, D22).
//! - That task handles its messages one by one, in arrival order, and for
//!   each sends the signals first, then the reply (rules 1–3, B2).
//! - A context belongs to the connection that created it: only that
//!   connection finds it, and its signals go to that connection alone (SEC-9).
//! - Callers must run as our own user (SEC-8). Nothing typed is ever logged
//!   (SEC-1); errors carry static text only.
#![forbid(unsafe_code)]

mod contexts;
mod server;
mod wire;

use std::num::NonZeroUsize;
use std::path::Path;
use std::time::Duration;

use ime_core::{Ready, SharedIme};

pub use server::serve;

/// The bus names fcitx5 owns; apps with the fcitx IM module look for both.
pub const FCITX_NAME: &str = "org.fcitx.Fcitx5";
pub const PORTAL_NAME: &str = "org.freedesktop.portal.Fcitx";

/// Limits and identity for [`serve`].
#[derive(Debug, Clone)]
pub struct Options {
    /// Only callers running as this uid are served (SEC-8).
    pub uid: u32,
    /// How long to wait for a running fcitx5 to give up the names before
    /// failing. Shorter than the unit's `TimeoutStartSec` (10 s).
    pub name_wait: Duration,
    /// Client connections served at once (SEC-16).
    pub max_clients: usize,
    /// Input contexts per client connection (SEC-16).
    pub max_contexts_per_client: usize,
    /// Messages of one client waiting to be handled; more are refused.
    pub queue_per_client: usize,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            uid: rustix::process::getuid().as_raw(),
            name_wait: Duration::from_secs(8),
            max_clients: 256,
            max_contexts_per_client: 128,
            queue_per_client: 256,
        }
    }
}

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
///
/// Not needed here means: no session bus is configured at all.
pub async fn run(ime: SharedIme, ready: Ready) -> ime_core::Result<()> {
    if !session_bus_configured() {
        return Ok(());
    }
    let conn = zbus::conn::Builder::session()
        // The reader hands messages on at once; room for bursts of key events.
        .max_queued(NonZeroUsize::new(1024).unwrap_or(NonZeroUsize::MIN))
        .build()
        .await
        .map_err(|_| "fcitx: cannot connect to the session bus")?;
    serve(conn, ime, ready, Options::default()).await
}

/// The same places the D-Bus client libraries look for the session bus.
fn session_bus_configured() -> bool {
    let set = |name| std::env::var_os(name).is_some_and(|v| !v.is_empty());
    set("DBUS_SESSION_BUS_ADDRESS")
        || std::env::var_os("XDG_RUNTIME_DIR")
            .is_some_and(|dir| !dir.is_empty() && Path::new(&dir).join("bus").exists())
}
