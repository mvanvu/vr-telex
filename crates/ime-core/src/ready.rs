//! How a frontend tells the daemon that it can serve clients.

use tokio::sync::oneshot;

/// Given to a frontend's `run`. Call [`Ready::notify`] once, when clients can
/// reach the frontend: the daemon reports itself started to systemd only
/// after every frontend did so, or returned `Ok(())` as "not needed here".
pub struct Ready {
    tx: oneshot::Sender<()>,
}

/// The daemon's end of a [`Ready`].
pub struct ReadyWatch {
    rx: oneshot::Receiver<()>,
}

impl Ready {
    pub fn channel() -> (Ready, ReadyWatch) {
        let (tx, rx) = oneshot::channel();
        (Ready { tx }, ReadyWatch { rx })
    }

    /// The frontend is reachable now.
    pub fn notify(self) {
        // The daemon may already be stopping; then nobody listens.
        let _ = self.tx.send(());
    }
}

impl ReadyWatch {
    /// True once the frontend reported ready; false when it dropped its
    /// [`Ready`] without doing so (its `run` result then tells what happened).
    pub async fn wait(self) -> bool {
        self.rx.await.is_ok()
    }
}
