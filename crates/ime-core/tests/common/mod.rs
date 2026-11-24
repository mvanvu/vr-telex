//! Shared helpers: key builders and a tiny client that applies the actions
//! the way an application would, so tests assert on the text the user sees.
#![allow(dead_code)]

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ime_core::{
    Action, Caps, CtxId, Ime, KeyEvent, KeyResult, MemoryStateStore, Mode, Mods, keysym,
};

pub const PREEDIT: Caps = Caps {
    preedit: true,
    surrounding_text: false,
    password: false,
};
pub const SURROUNDING: Caps = Caps {
    preedit: false,
    surrounding_text: true,
    password: false,
};
pub const HOLD: Caps = Caps {
    preedit: false,
    surrounding_text: false,
    password: false,
};
pub const PASSWORD: Caps = Caps {
    preedit: true,
    surrounding_text: true,
    password: true,
};

pub fn ime_in(mode: Mode) -> Ime {
    Ime::new(&MemoryStateStore::new(mode))
}

pub fn ime() -> Ime {
    ime_in(Mode::Vi)
}

/// A context with the given capabilities, focused.
pub fn ctx(ime: &mut Ime, caps: Caps) -> CtxId {
    let id = ime.create_context();
    ime.set_caps(id, caps);
    ime.focus_in(id);
    id
}

/// Press event for a printable ASCII character.
pub fn key(c: char) -> KeyEvent {
    let state = if c.is_ascii_uppercase() {
        Mods::SHIFT
    } else {
        Mods::NONE
    };
    KeyEvent::press(c as u32, state)
}

pub fn press(sym: u32) -> KeyEvent {
    KeyEvent::press(sym, Mods::NONE)
}

/// A clock the test moves by hand.
#[derive(Clone)]
pub struct TestClock(Arc<Mutex<Instant>>);

impl TestClock {
    pub fn new() -> Self {
        Self(Arc::new(Mutex::new(Instant::now())))
    }

    pub fn advance(&self, by: Duration) {
        *self.0.lock().unwrap() += by;
    }

    pub fn reader(&self) -> Box<dyn Fn() -> Instant + Send> {
        let at = Arc::clone(&self.0);
        Box::new(move || *at.lock().unwrap())
    }
}

/// What an application shows: committed text, the preedit, and the keys it
/// received because the IME did not handle them.
#[derive(Default)]
pub struct App {
    pub text: String,
    pub preedit: String,
    pub keys: Vec<u32>,
}

impl App {
    pub fn apply_actions(&mut self, actions: &[Action]) {
        for action in actions {
            match action {
                Action::UpdatePreedit { text, cursor } => {
                    assert_eq!(*cursor as usize, text.chars().count(), "cursor at the end");
                    self.preedit = text.clone();
                }
                Action::HidePreedit => self.preedit.clear(),
                Action::Commit(text) => {
                    assert!(!text.is_empty(), "empty commit");
                    self.text.push_str(text);
                }
                Action::DeleteSurrounding { offset, chars } => {
                    assert_eq!(*offset, -(*chars as i32), "deletes right before the cursor");
                    for _ in 0..*chars {
                        assert!(self.text.pop().is_some(), "deleted more than the app holds");
                    }
                }
            }
        }
    }

    /// Applies the actions first, then the key itself when it was not handled:
    /// the order a frontend must keep.
    pub fn apply(&mut self, ev: KeyEvent, result: &KeyResult) {
        self.apply_actions(&result.actions);
        if result.handled || ev.is_release {
            return;
        }
        self.keys.push(ev.keysym);
        let plain = !ev.state.intersects(Mods::CONTROL | Mods::ALT | Mods::SUPER);
        if ev.keysym == keysym::BACKSPACE {
            self.text.pop();
        } else if plain && (0x20..0x7f).contains(&ev.keysym) {
            self.text.push(char::from_u32(ev.keysym).unwrap());
        }
    }

    pub fn send(&mut self, ime: &mut Ime, id: CtxId, ev: KeyEvent) -> KeyResult {
        let result = ime.process_key(id, ev);
        self.apply(ev, &result);
        result
    }

    /// Types printable ASCII; `<` stands for BackSpace.
    pub fn type_str(&mut self, ime: &mut Ime, id: CtxId, keys: &str) -> Vec<KeyResult> {
        keys.chars()
            .map(|c| {
                let ev = if c == '<' {
                    press(keysym::BACKSPACE)
                } else {
                    key(c)
                };
                self.send(ime, id, ev)
            })
            .collect()
    }
}

/// Ctrl+Shift tapped alone: Ctrl down, Shift down, Shift up, Ctrl up.
pub fn tap_ctrl_shift(ime: &mut Ime, id: CtxId) -> Vec<KeyResult> {
    [
        KeyEvent::press(keysym::CONTROL_L, Mods::NONE),
        KeyEvent::press(keysym::SHIFT_L, Mods::CONTROL),
        KeyEvent::release(keysym::SHIFT_L, Mods::CONTROL | Mods::SHIFT),
        KeyEvent::release(keysym::CONTROL_L, Mods::CONTROL),
    ]
    .into_iter()
    .map(|ev| ime.process_key(id, ev))
    .collect()
}
