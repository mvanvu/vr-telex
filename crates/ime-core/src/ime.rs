//! Input contexts, the key pipeline and the global mode.

use std::collections::HashMap;
use std::fmt;
use std::time::Instant;

use telex_core::{Composer, Lang};
use tokio::sync::watch;
use zeroize::Zeroize;

use crate::action::{Action, Caps, KeyResult};
use crate::key::{KeyClass, KeyEvent, Mods, classify};
use crate::toggle::TapDetector;

/// Longest word, in keys, that is composed. No Vietnamese syllable comes
/// near it; a longer run of letters is committed and the rest of it passes
/// through, which bounds both memory and the work of one key (SEC-18).
pub const MAX_WORD_KEYS: usize = 32;

/// The input mode, one for all contexts (D6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Vi,
    En,
}

impl Mode {
    /// `VI` / `EN`: the content of the state file (the indicator text is the
    /// frontend's).
    pub const fn symbol(self) -> &'static str {
        match self {
            Mode::Vi => "VI",
            Mode::En => "EN",
        }
    }

    pub(crate) fn from_symbol(symbol: &[u8]) -> Option<Self> {
        match symbol {
            b"VI" => Some(Mode::Vi),
            b"EN" => Some(Mode::En),
            _ => None,
        }
    }

    const fn toggled(self) -> Self {
        match self {
            Mode::Vi => Mode::En,
            Mode::En => Mode::Vi,
        }
    }
}

/// Where the mode is kept between runs. The IME only loads from it: saving
/// is file I/O and stays off the key path, with whoever follows a [`ModeWatch`].
pub trait StateStore {
    fn load(&self) -> Mode;
    fn save(&self, m: Mode);
}

/// A store that forgets: for tests and for a session without a home directory.
pub struct MemoryStateStore(Mode);

impl MemoryStateStore {
    pub fn new(mode: Mode) -> Self {
        Self(mode)
    }
}

impl StateStore for MemoryStateStore {
    fn load(&self) -> Mode {
        self.0
    }

    fn save(&self, _: Mode) {}
}

/// Identifies one input context. Never reused within a run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CtxId(u64);

/// Follows the mode, for the indicator.
pub struct ModeWatch {
    rx: watch::Receiver<Mode>,
}

impl ModeWatch {
    pub fn current(&self) -> Mode {
        *self.rx.borrow()
    }

    /// The new mode when it changed since this watch last reported one.
    pub fn try_changed(&mut self) -> Option<Mode> {
        match self.rx.has_changed() {
            Ok(true) => Some(*self.rx.borrow_and_update()),
            _ => None,
        }
    }

    /// Waits for the next change. `None` once the IME is gone.
    pub async fn changed(&mut self) -> Option<Mode> {
        self.rx.changed().await.ok()?;
        Some(*self.rx.borrow_and_update())
    }
}

/// How the word in progress reaches the client (D10).
#[derive(Clone, Copy, PartialEq, Eq)]
enum Edit {
    /// Shown as preedit, committed at the boundary.
    Preedit,
    /// Committed key by key and rewritten in place with DeleteSurrounding.
    Surrounding,
    /// Kept here and committed at the boundary.
    Hold,
    /// Password field: nothing is composed.
    Off,
}

impl Edit {
    fn of(caps: Caps) -> Self {
        if caps.password {
            Edit::Off
        } else if caps.preedit {
            Edit::Preedit
        } else if caps.surrounding_text {
            Edit::Surrounding
        } else {
            Edit::Hold
        }
    }
}

struct Context {
    caps: Caps,
    composer: Composer,
    tap: TapDetector,
    /// Actions produced outside a key (a capability change), not yet collected.
    pending: Vec<Action>,
    /// The word outgrew [`MAX_WORD_KEYS`]: its remaining letters pass through.
    overflowed: bool,
    /// Language of the last word ended in this context, which decides an
    /// overlap word (AC-3). Only the language is kept, never the text.
    last: Lang,
}

impl Context {
    fn new() -> Self {
        Self {
            caps: Caps::default(),
            composer: Composer::new(),
            tap: TapDetector::default(),
            pending: Vec::new(),
            overflowed: false,
            last: Lang::Unknown,
        }
    }

    /// Ends the word at a key, with the cursor still right after it: the
    /// client gets all of it as [`Composer::finish`] decides, nothing of it
    /// stays here, and its language becomes `last`.
    fn flush(&mut self, out: &mut Vec<Action>) {
        self.end_word(out, true);
    }

    /// Ends the word on a click, a focus change, a switch-off or a teardown.
    /// The client may have moved its cursor already, so a surrounding-text
    /// client keeps the word it shows and nothing is rewritten (D13).
    fn flush_away(&mut self, out: &mut Vec<Action>) {
        self.end_word(out, false);
    }

    fn end_word(&mut self, out: &mut Vec<Action>, at_cursor: bool) {
        self.overflowed = false;
        if self.composer.is_empty() {
            return;
        }
        let shown = self.composer.text();
        let finished = self.composer.finish(self.last);
        match Edit::of(self.caps) {
            Edit::Preedit => {
                out.push(Action::HidePreedit);
                if !finished.text.is_empty() {
                    out.push(Action::Commit(finished.text.to_owned()));
                }
            }
            Edit::Hold if !finished.text.is_empty() => {
                out.push(Action::Commit(finished.text.to_owned()));
            }
            // The client already holds the shown text: it is replaced only
            // when the finished word differs and the cursor is known.
            Edit::Surrounding if at_cursor && finished.text != shown => {
                let stale = shown.chars().count();
                if stale > 0 {
                    out.push(Action::DeleteSurrounding {
                        offset: -i32::try_from(stale).unwrap_or(i32::MAX),
                        chars: stale.try_into().unwrap_or(u32::MAX),
                    });
                }
                if !finished.text.is_empty() {
                    out.push(Action::Commit(finished.text.to_owned()));
                }
            }
            Edit::Hold | Edit::Surrounding | Edit::Off => {}
        }
        self.last = finished.lang;
        self.composer.clear();
    }

    /// As [`Context::flush_away`], then the next word starts with no
    /// language: the field or the cursor changed.
    fn flush_away_and_forget(&mut self, out: &mut Vec<Action>) {
        self.flush_away(out);
        self.last = Lang::Unknown;
    }

    /// Changes the word with `change` and tells the client what to show.
    fn compose(&mut self, change: impl FnOnce(&mut Composer), out: &mut Vec<Action>) {
        match Edit::of(self.caps) {
            Edit::Preedit => {
                change(&mut self.composer);
                let text = self.composer.text();
                if text.is_empty() {
                    out.push(Action::HidePreedit);
                } else {
                    out.push(Action::UpdatePreedit {
                        text: text.to_owned(),
                        cursor: text.chars().count().try_into().unwrap_or(u32::MAX),
                    });
                }
            }
            Edit::Surrounding => {
                let mut before = self.composer.text().to_owned();
                change(&mut self.composer);
                let after = self.composer.text();
                let kept: usize = before
                    .chars()
                    .zip(after.chars())
                    .take_while(|(old, new)| old == new)
                    .map(|(old, _)| old.len_utf8())
                    .sum();
                let stale = before[kept..].chars().count();
                if stale > 0 {
                    let chars = stale.try_into().unwrap_or(u32::MAX);
                    out.push(Action::DeleteSurrounding {
                        offset: -i32::try_from(stale).unwrap_or(i32::MAX),
                        chars,
                    });
                }
                if kept < after.len() {
                    out.push(Action::Commit(after[kept..].to_owned()));
                }
                before.zeroize();
            }
            Edit::Hold => change(&mut self.composer),
            Edit::Off => {}
        }
        if self.composer.text().is_empty() {
            self.composer.clear();
        }
    }
}

/// The IME: one mode, many contexts. Wrap it in a [`crate::SharedIme`].
pub struct Ime {
    mode: Mode,
    /// Off while the desktop has another input source selected (D33): every
    /// key passes untouched and the mode is kept for when it comes back.
    enabled: bool,
    clock: Box<dyn Fn() -> Instant + Send>,
    mode_tx: watch::Sender<Mode>,
    contexts: HashMap<CtxId, Context>,
    next_id: u64,
    /// The context a shared call is working on, to know whose state a panic
    /// left half done.
    in_call: Option<CtxId>,
}

impl Ime {
    /// Starts in the mode the store remembers (AC-8).
    pub fn new(store: &dyn StateStore) -> Self {
        Self::with_clock(store, Box::new(Instant::now))
    }

    /// As [`Ime::new`] with the clock that times the Ctrl+Shift tap.
    pub fn with_clock(store: &dyn StateStore, clock: Box<dyn Fn() -> Instant + Send>) -> Self {
        let mode = store.load();
        Self {
            mode,
            enabled: true,
            clock,
            mode_tx: watch::Sender::new(mode),
            contexts: HashMap::new(),
            next_id: 0,
            in_call: None,
        }
    }

    pub fn create_context(&mut self) -> CtxId {
        self.next_id += 1;
        let id = CtxId(self.next_id);
        self.contexts.insert(id, Context::new());
        id
    }

    /// Removes the context and returns the commit of its word (B3).
    pub fn destroy_context(&mut self, id: CtxId) -> Vec<Action> {
        let Some(mut ctx) = self.contexts.remove(&id) else {
            return Vec::new();
        };
        let mut out = std::mem::take(&mut ctx.pending);
        ctx.flush_away(&mut out);
        out
    }

    /// Sets what the client can do. A word typed under the old capabilities
    /// is committed under them first (SEC-13); the actions wait in the
    /// context for [`Ime::take_pending`], or lead its next result.
    pub fn set_caps(&mut self, id: CtxId, caps: Caps) {
        let Some(ctx) = self.contexts.get_mut(&id) else {
            return;
        };
        if Edit::of(ctx.caps) != Edit::of(caps) {
            let mut out = std::mem::take(&mut ctx.pending);
            // No key drives this, so the cursor may be elsewhere: a
            // surrounding-text client keeps the shown word (D13, D17). `last`
            // stays: the field and the cursor did not change.
            ctx.flush_away(&mut out);
            ctx.pending = out;
        }
        ctx.caps = caps;
    }

    /// Collects the actions [`Ime::set_caps`] left for the context.
    pub fn take_pending(&mut self, id: CtxId) -> Vec<Action> {
        self.contexts
            .get_mut(&id)
            .map(|ctx| std::mem::take(&mut ctx.pending))
            .unwrap_or_default()
    }

    pub fn focus_in(&mut self, id: CtxId) {
        if let Some(ctx) = self.contexts.get_mut(&id) {
            // Modifier presses or releases may have gone to another context.
            ctx.tap.reset();
            // A new focus starts a new run of words.
            ctx.last = Lang::Unknown;
        }
    }

    /// Commits the word, never drops it (B3).
    pub fn focus_out(&mut self, id: CtxId) -> Vec<Action> {
        let Some(ctx) = self.contexts.get_mut(&id) else {
            return Vec::new();
        };
        ctx.tap.reset();
        let mut out = std::mem::take(&mut ctx.pending);
        ctx.flush_away_and_forget(&mut out);
        out
    }

    /// Commits the word, never drops it: a click or a cursor move (B3).
    /// A preedit client that commits its shown preedit on reset keeps the
    /// shown text instead of the finished one (D12).
    pub fn reset(&mut self, id: CtxId) -> Vec<Action> {
        let Some(ctx) = self.contexts.get_mut(&id) else {
            return Vec::new();
        };
        // Ctrl+Shift+click is a shortcut of the application, not a tap.
        ctx.tap.spoil();
        let mut out = std::mem::take(&mut ctx.pending);
        ctx.flush_away_and_forget(&mut out);
        out
    }

    /// Handles one key. Synchronous; the work is bounded by [`MAX_WORD_KEYS`].
    pub fn process_key(&mut self, id: CtxId, ev: KeyEvent) -> KeyResult {
        let Some(ctx) = self.contexts.get_mut(&id) else {
            return KeyResult {
                handled: false,
                actions: Vec::new(),
            };
        };
        let mut actions = std::mem::take(&mut ctx.pending);
        let pass = |actions| KeyResult {
            handled: false,
            actions,
        };
        if !self.enabled {
            // Another input source is selected: not even Ctrl+Shift is looked at.
            return pass(actions);
        }
        let release = ev.released();
        let class = classify(ev.keysym);

        // Modifiers always go on to the application (D7).
        match class {
            KeyClass::Chord(key) => {
                let foreign = ev.state.intersects(Mods::FOREIGN_TO_TAP);
                if ctx.tap.chord_key(key, release, foreign, (self.clock)()) {
                    // The word belongs to the mode it was typed in (B3).
                    ctx.flush(&mut actions);
                    ctx.last = Lang::Unknown;
                    self.mode = self.mode.toggled();
                    self.mode_tx.send_replace(self.mode);
                }
                return pass(actions);
            }
            KeyClass::Modifier => {
                ctx.tap.spoil();
                return pass(actions);
            }
            KeyClass::Letter(_) | KeyClass::BackSpace | KeyClass::Boundary => ctx.tap.spoil(),
        }
        if release {
            return pass(actions);
        }

        // English mode and password fields: the key is not looked at any
        // further and nothing of it is kept (SEC-12).
        if self.mode == Mode::En || Edit::of(ctx.caps) == Edit::Off {
            ctx.flush(&mut actions);
            return pass(actions);
        }
        if ev.state.intersects(Mods::COMMAND) {
            ctx.flush(&mut actions);
            return pass(actions);
        }

        match class {
            KeyClass::Letter(_) if ctx.overflowed => pass(actions),
            KeyClass::Letter(_) if ctx.composer.raw().len() >= MAX_WORD_KEYS => {
                ctx.flush(&mut actions);
                ctx.overflowed = true;
                // A run of letters this long is no Vietnamese word.
                ctx.last = Lang::En;
                pass(actions)
            }
            KeyClass::Letter(ch) => {
                ctx.compose(
                    |word| {
                        word.push(ch);
                    },
                    &mut actions,
                );
                KeyResult {
                    handled: true,
                    actions,
                }
            }
            KeyClass::BackSpace if !ctx.composer.is_empty() => {
                ctx.compose(
                    |word| {
                        word.pop();
                    },
                    &mut actions,
                );
                KeyResult {
                    handled: true,
                    actions,
                }
            }
            KeyClass::BackSpace => {
                // The client deletes text this context no longer tracks, so
                // the previous word may be gone (D16).
                ctx.flush(&mut actions);
                ctx.last = Lang::Unknown;
                pass(actions)
            }
            _ => {
                ctx.flush(&mut actions);
                pass(actions)
            }
        }
    }

    /// Characters of the word in progress of a context (a length: safe to log).
    pub fn buffered_len(&self, id: CtxId) -> usize {
        self.contexts
            .get(&id)
            .map_or(0, |ctx| ctx.composer.text().chars().count())
    }

    pub fn mode(&self) -> Mode {
        self.mode
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    /// Switches the IME off or on for every context (D33). Switching off ends
    /// each word in progress: its commit waits in the context and leads that
    /// context's next result, or comes with [`Ime::take_pending`],
    /// [`Ime::focus_out`], [`Ime::reset`] or [`Ime::destroy_context`] (B3).
    /// Either way a Ctrl+Shift tap under way is forgotten.
    pub fn set_enabled(&mut self, on: bool) {
        if self.enabled == on {
            return;
        }
        self.enabled = on;
        for ctx in self.contexts.values_mut() {
            if !on {
                let mut out = std::mem::take(&mut ctx.pending);
                ctx.flush_away_and_forget(&mut out);
                ctx.pending = out;
            }
            ctx.tap.reset();
        }
    }

    /// A watch that reports every mode change, for the indicator.
    pub fn subscribe_mode(&mut self) -> ModeWatch {
        ModeWatch {
            rx: self.mode_tx.subscribe(),
        }
    }

    /// Marks the context a shared call is about to work on.
    pub(crate) fn enter(&mut self, id: CtxId) {
        self.in_call = Some(id);
    }

    pub(crate) fn leave(&mut self) {
        self.in_call = None;
    }

    /// After a panic inside a call: the context it was working on may be half
    /// changed, so its word is forgotten. Every other context was not touched;
    /// its word is kept as a commit that leads its next result (B3).
    pub(crate) fn recover(&mut self) {
        let broken = self.in_call.take();
        for (id, ctx) in &mut self.contexts {
            if broken == Some(*id) {
                ctx.composer.clear();
                ctx.pending.clear();
                ctx.overflowed = false;
                ctx.last = Lang::Unknown;
            } else {
                let mut out = std::mem::take(&mut ctx.pending);
                ctx.flush_away(&mut out);
                ctx.pending = out;
            }
            ctx.tap.reset();
        }
    }
}

/// Counts only: no word of any context is printed (SEC-2).
impl fmt::Debug for Ime {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Ime")
            .field("mode", &self.mode)
            .field("contexts", &self.contexts.len())
            .finish()
    }
}
