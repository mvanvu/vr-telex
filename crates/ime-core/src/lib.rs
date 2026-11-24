//! IME core: input contexts, the serial key pipeline, the global VI/EN mode.
//!
//! # How a frontend must call this crate
//!
//! Frontends hold a [`SharedIme`] and translate their protocol into its
//! calls. Typed text is never lost, duplicated or reordered only when every
//! frontend keeps these rules (spec B2, B3):
//!
//! 1. **One serial path per context.** All calls for one context come from
//!    one task (one per client connection is enough), in the order the
//!    client sent them. Never spawn a task per message.
//! 2. **Finish key N before reading key N+1.** For each key: call
//!    [`SharedIme::process_key`], send every returned [`Action`] to the
//!    client in order, then send the reply carrying `handled`, and only then
//!    read the next message of that connection. A `Commit` therefore always
//!    reaches the client before the unhandled key that ended the word.
//! 3. **Send what focus and capability calls return.** `focus_out`, `reset`,
//!    `destroy_context` and `set_caps` return the commit of the word in
//!    progress. It goes to the context it came from, before anything else is
//!    sent for that context (SEC-13). Map a mouse click or cursor move to
//!    `reset`, a content-type change to `set_caps`.
//! 4. **Report modifiers too.** The Ctrl+Shift tap is detected from the key
//!    events alone, so presses and releases of modifier keys must be
//!    forwarded like any other key. They always come back `handled: false`.
//! 5. **Never log an event or an action's content.** The `Debug` output of
//!    these types is redacted; keep it that way in wrappers (SEC-1, SEC-2).
//!
//! 6. **Tell the daemon how `run` went.** A frontend is
//!    `async fn run(ime: SharedIme, ready: Ready) -> Result<()>`. It calls
//!    [`Ready::notify`] once clients can reach it; it returns `Ok(())` only
//!    when it is not needed on this machine (that also counts as ready) and
//!    `Err` on any failure, which ends the daemon so that systemd restarts
//!    it whole (decision D22).
//! 7. **One task per client connection.** Never wait for one client on a
//!    loop that other clients share: a frozen application would stall typing
//!    everywhere while the watchdog still sees a live daemon.
//!
//! Every call is synchronous, takes the one lock for its whole duration and
//! does a bounded amount of work (a word is at most [`MAX_WORD_KEYS`] keys).
//! No call waits on a client or does I/O: the mode is saved by whoever
//! follows a [`ModeWatch`], outside the lock.
#![forbid(unsafe_code)]

mod action;
mod ime;
mod key;
mod ready;
mod shared;
mod state;
mod toggle;

pub use action::{Action, Caps, KeyResult};
pub use ime::{CtxId, Ime, MAX_WORD_KEYS, MemoryStateStore, Mode, ModeWatch, StateStore};
pub use key::{KeyEvent, Mods, keysym};
pub use ready::{Ready, ReadyWatch};
pub use shared::SharedIme;
pub use state::{FileStateStore, state_dir};

/// Error returned by frontends. Messages must never carry typed text (SEC-1).
pub type Error = Box<dyn std::error::Error + Send + Sync + 'static>;

/// Result type shared by the frontends.
pub type Result<T> = std::result::Result<T, Error>;
