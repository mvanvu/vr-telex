//! The handle every frontend holds.

use std::fmt;
use std::sync::{Arc, Mutex, MutexGuard};

use crate::action::{Action, Caps, KeyResult};
use crate::ime::{CtxId, Ime, Mode, ModeWatch};
use crate::key::KeyEvent;

/// One [`Ime`] behind one lock, shared by all frontends.
///
/// Each method is one whole call under the lock: the lock is never handed
/// out, so it cannot be held across an `.await` or a client round trip, and a
/// call waits at most for another call of bounded work. The calls of one
/// context stay in order because its frontend makes them from one task and
/// answers the client before reading the next key; see the crate docs.
#[derive(Clone)]
pub struct SharedIme {
    inner: Arc<Mutex<Ime>>,
}

impl SharedIme {
    pub fn new(ime: Ime) -> Self {
        Self {
            inner: Arc::new(Mutex::new(ime)),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Ime> {
        match self.inner.lock() {
            Ok(ime) => ime,
            // A call panicked half way (unwinding builds only; a release build
            // aborts). Go on from a state that is known to be whole.
            Err(poisoned) => {
                let mut ime = poisoned.into_inner();
                ime.recover();
                self.inner.clear_poison();
                ime
            }
        }
    }

    /// Runs one call for a context, remembering which one while it runs.
    fn call<R>(&self, id: CtxId, f: impl FnOnce(&mut Ime) -> R) -> R {
        let mut ime = self.lock();
        ime.enter(id);
        let out = f(&mut ime);
        ime.leave();
        out
    }

    pub fn create_context(&self) -> CtxId {
        self.lock().create_context()
    }

    /// Returns the commit of the word in progress; send it if the client is still there.
    pub fn destroy_context(&self, id: CtxId) -> Vec<Action> {
        self.call(id, |ime| ime.destroy_context(id))
    }

    /// Sets the capabilities and returns what must be sent first: the commit
    /// of a word typed under the old ones (SEC-13).
    pub fn set_caps(&self, id: CtxId, caps: Caps) -> Vec<Action> {
        self.call(id, |ime| {
            ime.set_caps(id, caps);
            ime.take_pending(id)
        })
    }

    pub fn focus_in(&self, id: CtxId) {
        self.call(id, |ime| ime.focus_in(id));
    }

    pub fn focus_out(&self, id: CtxId) -> Vec<Action> {
        self.call(id, |ime| ime.focus_out(id))
    }

    pub fn reset(&self, id: CtxId) -> Vec<Action> {
        self.call(id, |ime| ime.reset(id))
    }

    pub fn process_key(&self, id: CtxId, ev: KeyEvent) -> KeyResult {
        self.call(id, |ime| ime.process_key(id, ev))
    }

    /// Characters of the word in progress: a length, safe to log.
    pub fn buffered_len(&self, id: CtxId) -> usize {
        self.lock().buffered_len(id)
    }

    pub fn mode(&self) -> Mode {
        self.lock().mode()
    }

    pub fn subscribe_mode(&self) -> ModeWatch {
        self.lock().subscribe_mode()
    }
}

impl fmt::Debug for SharedIme {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SharedIme")
    }
}
