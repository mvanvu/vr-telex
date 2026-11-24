//! The listener: who may connect, and how many.

use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;
use std::time::Duration;

use ime_core::{Ready, SharedIme};
use tokio::net::UnixListener;
use tokio::sync::Semaphore;
use zbus::Guid;

use crate::Config;
use crate::address::{self, PrepareError, Published};
use crate::session::{self, Shared};
use crate::socket::Peer;

/// A listener that fails this often in a row is broken: the daemon restarts.
const MAX_ACCEPT_FAILURES: u32 = 10;
const ACCEPT_RETRY: Duration = Duration::from_millis(100);

/// Only the daemon's own user may talk to it (SEC-8). The D-Bus handshake
/// alone does not ensure that: `EXTERNAL` without an identity is accepted.
pub(crate) fn uid_allowed(peer: u32, own: u32) -> bool {
    peer == own
}

/// Listens, publishes the address and serves clients until a fatal error.
///
/// [`crate::run`] with the places and limits given instead of read from the
/// environment.
pub async fn serve(config: Config, ime: SharedIme, ready: Ready) -> ime_core::Result<()> {
    let peer_uid = config.uid;
    serve_with_peer_uid(config, ime, ready, peer_uid).await
}

/// [`serve`] with the user whose processes may connect named apart from the
/// user that owns the directories. Only the tests build it (feature
/// `test-support`): a test cannot connect as another user, so it runs the
/// bus as if it belonged to one. The daemon can never name it.
#[cfg(feature = "test-support")]
#[doc(hidden)]
pub async fn serve_peers_of(
    config: Config,
    ime: SharedIme,
    ready: Ready,
    peer_uid: u32,
) -> ime_core::Result<()> {
    serve_with_peer_uid(config, ime, ready, peer_uid).await
}

async fn serve_with_peer_uid(
    config: Config,
    ime: SharedIme,
    ready: Ready,
    peer_uid: u32,
) -> ime_core::Result<()> {
    let prepared = match address::prepare_socket(&config.runtime_dir, config.uid) {
        Ok(prepared) => prepared,
        // A second daemon must fail (the process exits FAILURE) and leave the
        // running one alone (SEC-7).
        Err(PrepareError::Running) => return Err("fe-ibus: another instance is running".into()),
        Err(PrepareError::Unsafe) => return Err("fe-ibus: cannot use the socket directory".into()),
    };
    let socket = prepared.socket.clone();
    let guid = Guid::generate();
    let bus_address = address::bus_address(&socket, guid.as_str())
        .ok_or("fe-ibus: the runtime directory path cannot be a bus address")?;
    let content = address::file_content(&bus_address, std::process::id());

    let listener = UnixListener::bind(&socket).map_err(|_| "fe-ibus: cannot listen")?;
    let mut published = Published::new(prepared, content.clone());
    // The directory is already closed to others; this is the second lock.
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))
        .map_err(|_| "fe-ibus: cannot restrict the socket")?;

    // Only now: a client that reads the file must find the socket listening.
    for name in &config.address_files {
        let file = address::write_address_file(&config.bus_dir, name, &content, config.uid)
            .map_err(|_| "fe-ibus: cannot write the address file safely")?;
        published.add(file);
    }
    ready.notify();

    let shared = Arc::new(Shared::new(ime, config.limits, guid));
    let slots = Arc::new(Semaphore::new(config.limits.connections));
    let mut next_id: u64 = 0;
    let mut failures = 0;
    loop {
        let stream = match listener.accept().await {
            Ok((stream, _)) => stream,
            Err(_) => {
                failures += 1;
                if failures >= MAX_ACCEPT_FAILURES {
                    return Err("fe-ibus: the listener failed".into());
                }
                tokio::time::sleep(ACCEPT_RETRY).await;
                continue;
            }
        };
        failures = 0;
        // Dropping the stream closes it: over the limit, or not this user.
        let Ok(slot) = Arc::clone(&slots).try_acquire_owned() else {
            continue;
        };
        let Ok(cred) = stream.peer_cred() else {
            continue;
        };
        if !uid_allowed(cred.uid(), peer_uid) {
            continue;
        }
        let peer = Peer {
            uid: cred.uid(),
            pid: cred.pid(),
        };
        next_id += 1;
        let id = next_id;
        let shared = Arc::clone(&shared);
        // One task per client: a client that stalls holds up only itself.
        tokio::spawn(async move {
            session::serve(stream, id, peer, shared).await;
            drop(slot);
        });
    }
}

#[cfg(test)]
mod tests {
    use super::uid_allowed;

    #[test]
    fn only_the_own_user_is_allowed() {
        assert!(uid_allowed(1000, 1000));
        assert!(!uid_allowed(1001, 1000));
        // Root is another user too.
        assert!(!uid_allowed(0, 1000));
    }
}
