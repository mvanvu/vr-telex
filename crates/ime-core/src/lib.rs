//! IME core: input contexts, key pipeline, global VI/EN mode.
//!
//! Placeholder until T4: only the types the frontends and the binary are wired with.
#![forbid(unsafe_code)]

/// Error returned by frontends. Messages must never carry typed text (SEC-1).
pub type Error = Box<dyn std::error::Error + Send + Sync + 'static>;

/// Result type shared by the frontends.
pub type Result<T> = std::result::Result<T, Error>;

/// Handle to the IME shared by every frontend. T4 replaces this placeholder.
#[derive(Clone, Default)]
pub struct SharedIme;

impl SharedIme {
    pub fn new() -> Self {
        Self
    }
}
