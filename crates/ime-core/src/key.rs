//! Key events as the frontends deliver them: X11 keysyms and modifier mask.

use std::fmt;
use std::ops::BitOr;

/// The X11 keysyms the pipeline tells apart. Everything else is a word boundary.
pub mod keysym {
    pub const SPACE: u32 = 0x0020;
    pub const BACKSPACE: u32 = 0xff08;
    pub const TAB: u32 = 0xff09;
    pub const RETURN: u32 = 0xff0d;
    pub const ESCAPE: u32 = 0xff1b;
    pub const HOME: u32 = 0xff50;
    pub const LEFT: u32 = 0xff51;
    pub const UP: u32 = 0xff52;
    pub const RIGHT: u32 = 0xff53;
    pub const DOWN: u32 = 0xff54;
    pub const END: u32 = 0xff57;
    pub const MODE_SWITCH: u32 = 0xff7e;
    pub const NUM_LOCK: u32 = 0xff7f;
    pub const DELETE: u32 = 0xffff;
    pub const SHIFT_L: u32 = 0xffe1;
    pub const SHIFT_R: u32 = 0xffe2;
    pub const CONTROL_L: u32 = 0xffe3;
    pub const CONTROL_R: u32 = 0xffe4;
    pub const CAPS_LOCK: u32 = 0xffe5;
    pub const SHIFT_LOCK: u32 = 0xffe6;
    pub const META_L: u32 = 0xffe7;
    pub const META_R: u32 = 0xffe8;
    pub const ALT_L: u32 = 0xffe9;
    pub const ALT_R: u32 = 0xffea;
    pub const SUPER_L: u32 = 0xffeb;
    pub const SUPER_R: u32 = 0xffec;
    pub const HYPER_L: u32 = 0xffed;
    pub const HYPER_R: u32 = 0xffee;
    /// `ISO_Lock` .. `ISO_Level5_Lock`: the ISO shift, latch and group keys.
    pub(crate) const ISO_MODIFIERS: std::ops::RangeInclusive<u32> = 0xfe01..=0xfe13;
}

/// Modifier mask in the X11 layout, which IBus, fcitx and XIM all share.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Mods(pub u32);

impl Mods {
    pub const NONE: Mods = Mods(0);
    pub const SHIFT: Mods = Mods(1 << 0);
    pub const LOCK: Mods = Mods(1 << 1);
    pub const CONTROL: Mods = Mods(1 << 2);
    /// Mod1.
    pub const ALT: Mods = Mods(1 << 3);
    /// Mod2.
    pub const NUM_LOCK: Mods = Mods(1 << 4);
    /// Mod4, and the virtual Super bit IBus and fcitx add.
    pub const SUPER: Mods = Mods(1 << 6 | 1 << 26);
    pub const HYPER: Mods = Mods(1 << 27);
    pub const META: Mods = Mods(1 << 28);
    /// IBus marks a key release with this bit instead of a separate flag.
    pub const RELEASE: Mods = Mods(1 << 30);

    /// Modifiers that turn a key into a shortcut or belong to another chord.
    pub(crate) const COMMAND: Mods =
        Mods(Self::CONTROL.0 | Self::ALT.0 | Self::SUPER.0 | Self::HYPER.0 | Self::META.0);
    /// As [`Mods::COMMAND`] without Ctrl: what must not be down during the toggle tap.
    pub(crate) const FOREIGN_TO_TAP: Mods =
        Mods(Self::ALT.0 | Self::SUPER.0 | Self::HYPER.0 | Self::META.0);

    /// True when any bit of `other` is set.
    pub const fn intersects(self, other: Mods) -> bool {
        self.0 & other.0 != 0
    }

    /// True when every bit of `other` is set.
    pub const fn contains(self, other: Mods) -> bool {
        self.0 & other.0 == other.0
    }
}

impl BitOr for Mods {
    type Output = Mods;

    fn bitor(self, other: Mods) -> Mods {
        Mods(self.0 | other.0)
    }
}

/// One key press or release of a client.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct KeyEvent {
    pub keysym: u32,
    pub keycode: u32,
    pub state: Mods,
    pub is_release: bool,
}

impl KeyEvent {
    pub const fn press(keysym: u32, state: Mods) -> Self {
        Self {
            keysym,
            keycode: 0,
            state,
            is_release: false,
        }
    }

    pub const fn release(keysym: u32, state: Mods) -> Self {
        Self {
            keysym,
            keycode: 0,
            state,
            is_release: true,
        }
    }

    pub(crate) fn released(&self) -> bool {
        self.is_release || self.state.contains(Mods::RELEASE)
    }
}

/// A key event is typed text: which key it was is never printed (SEC-1, SEC-2).
impl fmt::Debug for KeyEvent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(if self.released() {
            "KeyEvent { <redacted>, release }"
        } else {
            "KeyEvent { <redacted>, press }"
        })
    }
}

/// The two modifiers of the toggle chord, each with its left and right key.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) struct ChordKey(pub(crate) u8);

impl ChordKey {
    pub(crate) const CTRL: u8 = 0b0011;
    pub(crate) const SHIFT: u8 = 0b1100;
}

pub(crate) enum KeyClass {
    /// Ctrl or Shift.
    Chord(ChordKey),
    /// Any other modifier, lock or group key.
    Modifier,
    Letter(char),
    BackSpace,
    /// Everything else ends the word.
    Boundary,
}

pub(crate) fn classify(sym: u32) -> KeyClass {
    match sym {
        keysym::CONTROL_L => KeyClass::Chord(ChordKey(0b0001)),
        keysym::CONTROL_R => KeyClass::Chord(ChordKey(0b0010)),
        keysym::SHIFT_L => KeyClass::Chord(ChordKey(0b0100)),
        keysym::SHIFT_R => KeyClass::Chord(ChordKey(0b1000)),
        keysym::CAPS_LOCK..=keysym::HYPER_R | keysym::MODE_SWITCH | keysym::NUM_LOCK => {
            KeyClass::Modifier
        }
        s if keysym::ISO_MODIFIERS.contains(&s) => KeyClass::Modifier,
        0x41..=0x5a | 0x61..=0x7a => match char::from_u32(sym) {
            Some(ch) => KeyClass::Letter(ch),
            None => KeyClass::Boundary,
        },
        keysym::BACKSPACE => KeyClass::BackSpace,
        _ => KeyClass::Boundary,
    }
}
