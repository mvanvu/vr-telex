//! IBus frontend: a private D-Bus bus speaking the IBus protocol.
//!
//! GNOME Shell (through libibus), the GTK IBus module and Qt's IBus plugin
//! find an input method through an address file and then talk to a message
//! bus on which a service named `org.freedesktop.IBus` lives. This crate is
//! both at once: a one-service pseudo bus on a private path socket. It
//! answers the few `org.freedesktop.DBus` calls those clients make and
//! serves the IBus objects itself; nothing is routed between clients.
//!
//! - `address`: the socket directory and the address files.
//! - `socket`: per-message and handshake size limits under the D-Bus library.
//! - `server`: the listener, the peer check and the connection limit.
//! - `session`: one client connection — its input contexts live and die with
//!   it and only it can name them or receives their signals (SEC-9).
//! - `ibus`: the IBus value layouts.
//!
//! Nothing here logs: a failure is a static error returned from [`run`]
//! (SEC-1).
#![forbid(unsafe_code)]

mod address;
mod ibus;
mod server;
mod session;
mod socket;

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use ime_core::{Ready, SharedIme};

pub use address::address_file_names;
pub use server::serve;
#[cfg(feature = "test-support")]
pub use server::serve_peers_of;

/// Upper bounds on what clients can make the frontend hold (SEC-16).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// Client connections at a time; further ones are closed at once.
    pub connections: usize,
    /// Input contexts one connection may hold.
    pub contexts_per_connection: usize,
    /// Size of one message, header included.
    pub message_bytes: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            connections: 256,
            contexts_per_connection: 64,
            // The largest message a client sends is a surrounding text.
            message_bytes: 128 * 1024,
        }
    }
}

/// Where the frontend lives on this machine and whom it serves.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    /// `$XDG_RUNTIME_DIR`; the socket goes to `vr-talex/ibus` below it.
    pub runtime_dir: PathBuf,
    /// `$XDG_CONFIG_HOME/ibus/bus`, where clients look for address files.
    pub bus_dir: PathBuf,
    /// Names of the address files to write, see [`address_file_names`].
    pub address_files: Vec<String>,
    /// The user the daemon runs as; no other user may connect (SEC-8).
    pub uid: u32,
    pub limits: Limits,
}

/// The environment values [`Config::from_values`] looks at.
#[derive(Debug, Clone, Copy, Default)]
pub struct Environment<'a> {
    pub xdg_runtime_dir: Option<&'a OsStr>,
    pub xdg_config_home: Option<&'a OsStr>,
    pub home: Option<&'a OsStr>,
    pub wayland_display: Option<&'a OsStr>,
    pub display: Option<&'a OsStr>,
    /// Content of the machine id file.
    pub machine_id: Option<&'a str>,
}

impl Config {
    /// `Ok(None)` when there is no display to serve; `Err` when there is one
    /// but the frontend cannot be set up for it.
    pub fn from_values(env: Environment<'_>, uid: u32) -> ime_core::Result<Option<Self>> {
        let absolute = |value: Option<&OsStr>| {
            value
                .map(Path::new)
                .filter(|path| path.is_absolute())
                .map(Path::to_path_buf)
        };
        let wayland = env.wayland_display.and_then(OsStr::to_str);
        let x = env.display.and_then(OsStr::to_str);
        if wayland.is_none_or(str::is_empty) && x.is_none_or(str::is_empty) {
            return Ok(None);
        }
        let machine_id = env
            .machine_id
            .and_then(address::parse_machine_id)
            .ok_or("fe-ibus: no machine id")?;
        let address_files = address_file_names(&machine_id, wayland, x);
        if address_files.is_empty() {
            return Err("fe-ibus: the display name cannot be used in a file name".into());
        }
        let runtime_dir =
            absolute(env.xdg_runtime_dir).ok_or("fe-ibus: XDG_RUNTIME_DIR is not set")?;
        let config_home = absolute(env.xdg_config_home)
            .or_else(|| absolute(env.home).map(|home| home.join(".config")))
            .ok_or("fe-ibus: no home directory")?;
        Ok(Some(Self {
            runtime_dir,
            bus_dir: config_home.join("ibus").join("bus"),
            address_files,
            uid,
            limits: Limits::default(),
        }))
    }

    fn from_env() -> ime_core::Result<Option<Self>> {
        let var = std::env::var_os;
        // The order libibus reads them in.
        let machine_id = std::fs::read_to_string("/var/lib/dbus/machine-id")
            .or_else(|_| std::fs::read_to_string("/etc/machine-id"))
            .ok();
        Self::from_values(
            Environment {
                xdg_runtime_dir: var("XDG_RUNTIME_DIR").as_deref(),
                xdg_config_home: var("XDG_CONFIG_HOME").as_deref(),
                home: var("HOME").as_deref(),
                wayland_display: var("WAYLAND_DISPLAY").as_deref(),
                display: var("DISPLAY").as_deref(),
                machine_id: machine_id.as_deref(),
            },
            rustix::process::getuid().as_raw(),
        )
    }
}

/// Serves the frontend until it stops or fails.
///
/// The contract with the daemon (`vr-talex` main), the same for every frontend:
/// - `ready.notify()` is called once clients can reach the frontend: the
///   socket listens and the address files are written.
/// - `Ok(())` is returned only when the frontend is not needed on this
///   machine: there is neither a Wayland nor an X display and the daemon
///   was not started by systemd (`without_display`).
/// - `Err` on any failure. The daemon then exits with a failure and systemd
///   restarts it, all frontends together. The error text is static and
///   carries no typed text (SEC-1).
pub async fn run(ime: SharedIme, ready: Ready) -> ime_core::Result<()> {
    match Config::from_env()? {
        Some(config) => serve(config, ime, ready).await,
        None => {
            let supervised = std::env::var_os("NOTIFY_SOCKET").is_some();
            without_display(supervised, NO_DISPLAY_WAIT, ready).await
        }
    }
}

/// How long a start without a display is held before it fails. It stays
/// below the unit's `TimeoutStartSec=10`; the unit has no start limit
/// (`StartLimitIntervalSec=0`), so systemd keeps retrying with its back-off.
const NO_DISPLAY_WAIT: Duration = Duration::from_secs(7);

/// A start with neither a Wayland nor an X display in the environment.
///
/// Run by hand that means there is nothing to serve. Under systemd the unit
/// belongs to a graphical session, so it only means the session has not
/// handed its display to the user manager yet (a start through D-Bus
/// activation or `systemctl --user start` can come that early). Reporting
/// "not needed" then would leave GNOME Shell without an input method for
/// the whole session; failing makes systemd start the daemon again, with
/// the environment of that moment. The daemon logs the error text.
async fn without_display(supervised: bool, wait: Duration, ready: Ready) -> ime_core::Result<()> {
    if !supervised {
        ready.notify();
        return Ok(());
    }
    tokio::time::sleep(wait).await;
    Err("fe-ibus: no display in the environment".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0123456789abcdef0123456789abcdef\n";

    fn env<'a>() -> Environment<'a> {
        Environment {
            xdg_runtime_dir: Some(OsStr::new("/run/user/1000")),
            xdg_config_home: None,
            home: Some(OsStr::new("/home/u")),
            wayland_display: Some(OsStr::new("wayland-0")),
            display: Some(OsStr::new(":0")),
            machine_id: Some(ID),
        }
    }

    #[test]
    fn config_follows_the_xdg_rules() {
        let config = Config::from_values(env(), 1000).unwrap().unwrap();
        assert_eq!(config.runtime_dir, Path::new("/run/user/1000"));
        assert_eq!(config.bus_dir, Path::new("/home/u/.config/ibus/bus"));
        assert_eq!(config.address_files.len(), 2);
        assert_eq!(config.uid, 1000);

        let moved = Environment {
            xdg_config_home: Some(OsStr::new("/cfg")),
            ..env()
        };
        let config = Config::from_values(moved, 1000).unwrap().unwrap();
        assert_eq!(config.bus_dir, Path::new("/cfg/ibus/bus"));
    }

    fn block_on<F: Future>(test: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap()
            .block_on(test)
    }

    #[test]
    fn outside_systemd_a_start_without_a_display_means_not_needed() {
        block_on(async {
            let (ready, watch) = Ready::channel();
            let result = without_display(false, Duration::from_secs(60), ready).await;
            assert!(result.is_ok());
            assert!(watch.wait().await, "not needed counts as ready");
        });
    }

    #[test]
    fn under_systemd_a_start_without_a_display_fails_after_a_wait() {
        block_on(async {
            let (ready, watch) = Ready::channel();
            let wait = Duration::from_millis(60);
            let start = std::time::Instant::now();
            let error = without_display(true, wait, ready).await.unwrap_err();
            assert!(
                start.elapsed() >= wait,
                "failing at once would be a restart storm"
            );
            assert_eq!(error.to_string(), "fe-ibus: no display in the environment");
            assert!(!watch.wait().await, "the daemon must not report ready");
        });
    }

    #[test]
    fn without_a_display_the_frontend_is_not_needed() {
        let none = Environment {
            wayland_display: None,
            display: Some(OsStr::new("")),
            ..env()
        };
        assert_eq!(Config::from_values(none, 1000).unwrap(), None);
    }

    #[test]
    fn a_display_without_the_rest_is_an_error() {
        for broken in [
            Environment {
                xdg_runtime_dir: None,
                ..env()
            },
            Environment {
                xdg_runtime_dir: Some(OsStr::new("relative")),
                ..env()
            },
            Environment {
                machine_id: Some("not an id"),
                ..env()
            },
            Environment {
                machine_id: None,
                ..env()
            },
            Environment {
                home: None,
                ..env()
            },
            Environment {
                wayland_display: Some(OsStr::new("../x")),
                display: None,
                ..env()
            },
        ] {
            assert!(Config::from_values(broken, 1000).is_err());
        }
    }
}
