//! Translation between fcitx5 wire values and `ime-core` types. Pure, no I/O.
//!
//! Values come from fcitx5 5.1.7: `src/lib/fcitx-utils/capabilityflags.h`
//! (`CapabilityFlag`), `src/lib/fcitx-utils/keysym.h` (`KeyState`),
//! `src/lib/fcitx-utils/textformatflags.h` (`TextFormatFlag`) and
//! `src/frontend/dbusfrontend/dbusfrontend.cpp` (method signatures).

use ime_core::{Caps, KeyEvent, Mods};

/// `CapabilityFlag` bits this frontend reads.
pub(crate) mod cap {
    pub const PREEDIT: u64 = 1 << 1;
    pub const PASSWORD: u64 = 1 << 3;
    pub const SURROUNDING_TEXT: u64 = 1 << 6;
    pub const SENSITIVE: u64 = 1 << 36;
    /// The client asks for raw keys only.
    pub const DISABLE: u64 = 1 << 40;
}

/// `TextFormatFlag::Underline`: how the word in progress is shown.
pub(crate) const FORMAT_UNDERLINE: i32 = 1 << 3;

/// What a client's capability word means for the IME.
///
/// A password or sensitive field, or a client that asks for the IME to be
/// disabled, gets every key passed through untouched (SEC-12).
pub(crate) fn caps_from_fcitx(bits: u64) -> Caps {
    Caps {
        preedit: bits & cap::PREEDIT != 0,
        surrounding_text: bits & cap::SURROUNDING_TEXT != 0,
        password: bits & (cap::PASSWORD | cap::SENSITIVE | cap::DISABLE) != 0,
    }
}

/// `ProcessKeyEvent(keyval, keycode, state, isRelease, time)` as an IME key.
///
/// fcitx says press or release in its own argument, so the IBus-style release
/// bit in `state` is cleared: a stray bit must not turn a press into a release.
pub(crate) fn key_event(keyval: u32, keycode: u32, state: u32, is_release: bool) -> KeyEvent {
    KeyEvent {
        keysym: keyval,
        keycode,
        state: Mods(state & !Mods::RELEASE.0),
        is_release,
    }
}

/// The preedit cursor as fcitx sends it: a byte offset into the UTF-8 text.
/// `ime-core` counts characters; a cursor past the end lands on the end.
pub(crate) fn byte_cursor(text: &str, chars: u32) -> i32 {
    let bytes = usize::try_from(chars)
        .ok()
        .and_then(|n| text.char_indices().nth(n))
        .map_or(text.len(), |(at, _)| at);
    i32::try_from(bytes).unwrap_or(i32::MAX)
}

/// Longest `CreateInputContext` argument list and string accepted. fcitx5-gtk
/// sends two short pairs (`display`, `program`); nothing is kept from them.
pub(crate) const MAX_CREATE_ARGS: usize = 16;
pub(crate) const MAX_CREATE_ARG_LEN: usize = 512;

pub(crate) fn create_args_ok(args: &[(String, String)]) -> bool {
    args.len() <= MAX_CREATE_ARGS
        && args
            .iter()
            .all(|(k, v)| k.len() <= MAX_CREATE_ARG_LEN && v.len() <= MAX_CREATE_ARG_LEN)
}

/// A caller is served only when the bus says it runs as our own user (SEC-8).
pub(crate) fn peer_allowed(peer_uid: Option<u32>, own_uid: u32) -> bool {
    peer_uid == Some(own_uid)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What gnome-terminal (VTE, fcitx5-gtk 5.1.1) sent in spike T1 Q4.
    const VTE_CAPS: u64 = 962_089_451_570;

    #[test]
    fn vte_capability_is_preedit_without_surrounding_text() {
        assert_eq!(VTE_CAPS, 0xE0_0100_0032);
        assert_eq!(
            caps_from_fcitx(VTE_CAPS),
            Caps {
                preedit: true,
                surrounding_text: false,
                password: false
            }
        );
    }

    // 1 << 4 is FormattedPreedit: not a preedit capability on its own.
    #[test]
    fn each_capability_bit_maps_alone() {
        assert_eq!(caps_from_fcitx(0), Caps::default());
        assert!(caps_from_fcitx(cap::PREEDIT).preedit);
        assert!(!caps_from_fcitx(1 << 4).preedit);
        assert!(caps_from_fcitx(cap::SURROUNDING_TEXT).surrounding_text);
        assert!(caps_from_fcitx(cap::PASSWORD).password);
        assert!(caps_from_fcitx(cap::SENSITIVE).password);
        assert!(caps_from_fcitx(cap::DISABLE).password);
        assert!(caps_from_fcitx(VTE_CAPS | cap::PASSWORD).password);
    }

    #[test]
    fn key_mapping_keeps_fields_and_trusts_the_release_argument() {
        let press = key_event(120, 53, 0, false);
        assert_eq!(press.keysym, 120);
        assert_eq!(press.keycode, 53);
        assert_eq!(press.state, Mods::NONE);
        assert!(!press.is_release);

        let release = key_event(120, 53, Mods::SHIFT.0, true);
        assert!(release.is_release);
        assert_eq!(release.state, Mods::SHIFT);

        // A release bit in the state of a press is dropped.
        let odd = key_event(120, 53, Mods::RELEASE.0 | Mods::CONTROL.0, false);
        assert_eq!(odd.state, Mods::CONTROL);
        assert!(!odd.is_release);
    }

    #[test]
    fn cursor_is_a_byte_offset() {
        assert_eq!(byte_cursor("việt", 4), 6);
        assert_eq!(byte_cursor("việt", 3), 5);
        assert_eq!(byte_cursor("việt", 2), 2);
        assert_eq!(byte_cursor("việt", 0), 0);
        assert_eq!(byte_cursor("việt", 99), 6);
        assert_eq!(byte_cursor("", 0), 0);
    }

    #[test]
    fn create_args_are_bounded() {
        let pair = |k: &str, v: &str| (k.to_owned(), v.to_owned());
        assert!(create_args_ok(&[]));
        assert!(create_args_ok(&[
            pair("display", "wayland:"),
            pair("program", "gnome-terminal-server")
        ]));
        let many: Vec<_> = (0..=MAX_CREATE_ARGS).map(|_| pair("k", "v")).collect();
        assert!(!create_args_ok(&many));
        let long = "x".repeat(MAX_CREATE_ARG_LEN + 1);
        assert!(!create_args_ok(&[pair("program", &long)]));
        assert!(!create_args_ok(&[pair(&long, "v")]));
    }

    #[test]
    fn only_the_same_uid_is_served() {
        assert!(peer_allowed(Some(1000), 1000));
        assert!(!peer_allowed(Some(1001), 1000));
        assert!(!peer_allowed(Some(0), 1000));
        assert!(!peer_allowed(None, 1000));
    }
}
