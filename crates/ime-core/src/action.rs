//! What a key makes the client do, and what a client can do.

use std::fmt;

use zeroize::Zeroize;

/// One instruction for the client. Emitted in order, per key.
///
/// The text is wiped when the action is dropped (SEC-4), so match on a
/// reference (`match &action`); the text cannot be moved out.
#[derive(Clone, PartialEq, Eq)]
pub enum Action {
    /// Show `text` as the word being composed; `cursor` is in characters.
    UpdatePreedit {
        text: String,
        cursor: u32,
    },
    HidePreedit,
    Commit(String),
    /// Delete `chars` characters starting `offset` characters from the cursor
    /// (always the characters right before it: `offset == -chars`).
    DeleteSurrounding {
        offset: i32,
        chars: u32,
    },
}

impl Drop for Action {
    fn drop(&mut self) {
        match self {
            Action::UpdatePreedit { text, .. } | Action::Commit(text) => text.zeroize(),
            Action::HidePreedit | Action::DeleteSurrounding { .. } => {}
        }
    }
}

/// Prints the kind and the length, never the text (SEC-2).
impl fmt::Debug for Action {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Action::UpdatePreedit { text, .. } => {
                write!(f, "UpdatePreedit(<redacted len={}>)", text.chars().count())
            }
            Action::HidePreedit => f.write_str("HidePreedit"),
            Action::Commit(text) => write!(f, "Commit(<redacted len={}>)", text.chars().count()),
            Action::DeleteSurrounding { chars, .. } => {
                write!(f, "DeleteSurrounding({chars})")
            }
        }
    }
}

/// Answer to one key: `handled: false` means the client delivers the key to
/// the application itself, after it has applied `actions`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyResult {
    pub handled: bool,
    pub actions: Vec<Action>,
}

/// What the client of a context supports and what kind of field has the focus.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Caps {
    /// The client can show a preedit.
    pub preedit: bool,
    /// The client can delete text around the cursor on request.
    pub surrounding_text: bool,
    /// Password, PIN or other private field: keys pass through untouched (SEC-12).
    pub password: bool,
}
