//! IBus values as libibus 1.5 serializes them, and the protocol's constants.
//!
//! Every IBus object travels as a variant holding a struct that starts with
//! its type name and an attachment dictionary (always empty here).

use std::collections::HashMap;

use ime_core::Mode;
use zbus::{Structure, Variant};

pub(crate) const BUS_NAME: &str = "org.freedesktop.DBus";
pub(crate) const BUS_PATH: &str = "/org/freedesktop/DBus";
pub(crate) const IBUS_NAME: &str = "org.freedesktop.IBus";
pub(crate) const IBUS_PATH: &str = "/org/freedesktop/IBus";
/// The unique name the IBus service has on this pseudo bus. Clients ask for
/// it with `GetNameOwner` and match signals by it.
pub(crate) const IBUS_UNIQUE: &str = ":1.0";
pub(crate) const PANEL_NAME: &str = "org.freedesktop.IBus.Panel";
pub(crate) const PANEL_PATH: &str = "/org/freedesktop/IBus/Panel";
pub(crate) const CONTEXT_IFACE: &str = "org.freedesktop.IBus.InputContext";
pub(crate) const SERVICE_IFACE: &str = "org.freedesktop.IBus.Service";
pub(crate) const PROPERTIES_IFACE: &str = "org.freedesktop.DBus.Properties";
pub(crate) const PEER_IFACE: &str = "org.freedesktop.DBus.Peer";
pub(crate) const CONTEXT_PATH_PREFIX: &str = "/org/freedesktop/IBus/InputContext_";

pub(crate) const ENGINE_NAME: &str = "vr-talex";

/// `IBusCapabilite` bits of `SetCapabilities`.
pub(crate) const CAP_PREEDIT_TEXT: u32 = 1 << 0;
pub(crate) const CAP_SURROUNDING_TEXT: u32 = 1 << 5;

/// `IBusInputPurpose` values that mark a secret field (SEC-12).
const PURPOSE_PASSWORD: u32 = 8;
const PURPOSE_PIN: u32 = 9;
/// `IBUS_INPUT_HINT_PRIVATE`: the client asks that nothing be remembered.
const HINT_PRIVATE: u32 = 1 << 11;

/// The release bit of the `ProcessKeyEvent` state.
pub(crate) const RELEASE_MASK: u32 = 1 << 30;

/// `IBusPreeditFocusMode`: who commits a preedit when the field loses focus.
pub(crate) const PREEDIT_CLEAR: u32 = 0;
pub(crate) const PREEDIT_COMMIT: u32 = 1;

/// An IBus keyboard-layout engine as GNOME Shell names it for an xkb input
/// source (`xkb:us::eng`, `xkb:de:nodeadkeys:ger`). The name is echoed back
/// to the client, so it is bounded and plain.
pub(crate) fn is_xkb_engine(name: &str) -> bool {
    name.strip_prefix("xkb:").is_some_and(|rest| {
        !rest.is_empty()
            && name.len() <= 64
            && rest
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b":_+-.".contains(&b))
    })
}

/// True when the content type of a field says its text is secret.
pub(crate) fn is_private(purpose: u32, hints: u32) -> bool {
    matches!(purpose, PURPOSE_PASSWORD | PURPOSE_PIN) || hints & HINT_PRIVATE != 0
}

/// The `(uu)` of the `ContentType` property: purpose and hints.
///
/// Matched by hand: the library's conversion of a variant into a tuple
/// panics when the struct has fewer fields than the tuple, and a client
/// decides what is in the variant (SEC-15).
pub(crate) fn content_type(value: &Variant<'_>) -> Option<(u32, u32)> {
    match value {
        Variant::Structure(pair) => match pair.fields() {
            [Variant::U32(purpose), Variant::U32(hints)] => Some((*purpose, *hints)),
            _ => None,
        },
        _ => None,
    }
}

/// The `(b)` of the `ClientCommitPreedit` property.
pub(crate) fn flag(value: &Variant<'_>) -> Option<bool> {
    match value {
        Variant::Structure(single) => match single.fields() {
            [Variant::Bool(flag)] => Some(*flag),
            _ => None,
        },
        _ => None,
    }
}

fn attachments() -> HashMap<String, Variant<'static>> {
    HashMap::new()
}

fn boxed(value: Variant<'_>) -> Variant<'_> {
    Variant::Variant(Box::new(value))
}

fn object(structure: zbus::Result<Structure<'_>>) -> zbus::Result<Variant<'_>> {
    structure.map(Variant::Structure)
}

/// `IBusAttrList` `(sa{sv}av)`; `underline` chars are underlined from the start.
fn attr_list(underline: u32) -> zbus::Result<Variant<'static>> {
    let mut attrs = Vec::new();
    if underline > 0 {
        // IBusAttribute (sa{sv}uuuu): type 1 = underline, value 1 = single.
        attrs.push(object(
            Structure::builder()
                .add_field("IBusAttribute")
                .add_field(attachments())
                .add_field(1u32)
                .add_field(1u32)
                .add_field(0u32)
                .add_field(underline)
                .build(),
        )?);
    }
    object(
        Structure::builder()
            .add_field("IBusAttrList")
            .add_field(attachments())
            .add_field(attrs)
            .build(),
    )
}

/// `IBusText` `(sa{sv}sv)`.
pub(crate) fn text(text: &str) -> zbus::Result<Variant<'_>> {
    styled_text(text, 0)
}

/// `IBusText` shown as a preedit: underlined over its whole length.
pub(crate) fn preedit_text(text: &str) -> zbus::Result<Variant<'_>> {
    styled_text(text, text.chars().count().try_into().unwrap_or(u32::MAX))
}

fn styled_text(text: &str, underline: u32) -> zbus::Result<Variant<'_>> {
    object(
        Structure::builder()
            .add_field("IBusText")
            .add_field(attachments())
            .add_field(text)
            .append_field(boxed(attr_list(underline)?))
            .build(),
    )
}

/// `IBusEngineDesc` `(sa{sv}ssssssssussssssss)` of the one engine.
pub(crate) fn engine_desc() -> zbus::Result<Variant<'static>> {
    object(
        Structure::builder()
            .add_field("IBusEngineDesc")
            .add_field(attachments())
            .add_field(ENGINE_NAME)
            // GNOME Shell names the source "<language name> (<longname>)".
            .add_field("Telex") // longname
            .add_field("Vietnamese Telex input method") // description
            .add_field("vi") // language
            .add_field("MIT") // license
            .add_field("") // author
            .add_field("") // icon
            .add_field("us") // layout
            .add_field(0u32) // rank
            .add_field("") // hotkeys
            .add_field(indicator_symbol(Mode::Vi)) // symbol
            .add_field("") // setup
            .add_field("") // layout_variant
            .add_field("") // layout_option
            .add_field("") // version
            .add_field("") // textdomain
            .add_field("") // icon_prop_key
            .build(),
    )
}

/// The engine list (`av`) of `Engines`, `ListEngines` and their kin.
pub(crate) fn engine_list() -> zbus::Result<Vec<Variant<'static>>> {
    Ok(vec![engine_desc()?])
}

fn prop_list(props: Vec<Variant<'static>>) -> zbus::Result<Variant<'static>> {
    object(
        Structure::builder()
            .add_field("IBusPropList")
            .add_field(attachments())
            .add_field(props)
            .build(),
    )
}

/// The top-bar text of a mode: lowercase like the shell's own layout labels
/// ("en" for the US layout, D32). The state file keeps [`Mode::symbol`].
pub(crate) const fn indicator_symbol(mode: Mode) -> &'static str {
    match mode {
        Mode::Vi => "vi",
        Mode::En => "en",
    }
}

/// The `InputMode` `IBusProperty` `(sa{sv}suvsvbbuvv)`: GNOME Shell shows its
/// symbol in the top bar (D6).
pub(crate) fn mode_property(mode: Mode) -> zbus::Result<Variant<'static>> {
    let label = match mode {
        Mode::Vi => "Vietnamese (Telex)",
        Mode::En => "English",
    };
    object(
        Structure::builder()
            .add_field("IBusProperty")
            .add_field(attachments())
            .add_field("InputMode") // key
            .add_field(0u32) // type: normal
            .append_field(boxed(text(label)?))
            .add_field("") // icon
            .append_field(boxed(text("")?)) // tooltip
            .add_field(true) // sensitive
            .add_field(true) // visible
            .add_field(0u32) // state: unchecked
            .append_field(boxed(prop_list(Vec::new())?)) // sub properties
            .append_field(boxed(text(indicator_symbol(mode))?)) // symbol
            .build(),
    )
}

/// The `IBusPropList` `(sa{sv}av)` holding the one property.
pub(crate) fn mode_property_list(mode: Mode) -> zbus::Result<Variant<'static>> {
    prop_list(vec![mode_property(mode)?])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn signature(value: &Variant<'_>) -> String {
        value.value_signature().to_string()
    }

    fn fields<'a>(value: &'a Variant<'a>) -> &'a [Variant<'a>] {
        match value {
            Variant::Structure(structure) => structure.fields(),
            _ => panic!("not a structure"),
        }
    }

    fn unboxed<'a>(value: &'a Variant<'a>) -> &'a Variant<'a> {
        match value {
            Variant::Variant(inner) => inner,
            _ => panic!("not a variant"),
        }
    }

    fn string(value: &Variant<'_>) -> String {
        match value {
            Variant::Str(text) => text.as_str().to_owned(),
            _ => panic!("not a string"),
        }
    }

    #[test]
    fn text_has_the_libibus_layout() {
        let value = text("việt").unwrap();
        assert_eq!(signature(&value), "(sa{sv}sv)");
        let fields = fields(&value);
        assert_eq!(string(&fields[0]), "IBusText");
        assert_eq!(string(&fields[2]), "việt");
        let attrs = unboxed(&fields[3]);
        assert_eq!(signature(attrs), "(sa{sv}av)");
        assert_eq!(string(&self::fields(attrs)[0]), "IBusAttrList");
    }

    #[test]
    fn preedit_text_is_underlined_over_its_characters() {
        let value = preedit_text("việt").unwrap();
        let attrs = unboxed(&fields(&value)[3]);
        let Variant::Array(list) = &fields(attrs)[2] else {
            panic!("not an array");
        };
        assert_eq!(list.len(), 1);
        let attr = unboxed(&list[0]);
        assert_eq!(signature(attr), "(sa{sv}uuuu)");
        let attr = fields(attr);
        assert_eq!(string(&attr[0]), "IBusAttribute");
        assert_eq!(
            [&attr[2], &attr[3], &attr[4], &attr[5]],
            [
                &Variant::U32(1),
                &Variant::U32(1),
                &Variant::U32(0),
                &Variant::U32(4)
            ]
        );
    }

    #[test]
    fn engine_desc_has_the_libibus_layout() {
        let value = engine_desc().unwrap();
        assert_eq!(signature(&value), "(sa{sv}ssssssssussssssss)");
        let fields = fields(&value);
        assert_eq!(string(&fields[0]), "IBusEngineDesc");
        assert_eq!(string(&fields[2]), "vr-talex");
        // GNOME Shell names the source "<language name> (<longname>)" (ui/status/keyboard.js):
        // language "vi" and longname "Telex" read "Vietnamese (Telex)".
        assert_eq!(string(&fields[3]), "Telex");
        assert_eq!(string(&fields[5]), "vi");
        assert_eq!(string(&fields[9]), "us");
        assert_eq!(string(&fields[12]), "vi");
    }

    #[test]
    fn mode_property_carries_the_symbol_of_each_mode() {
        for (mode, symbol) in [(Mode::Vi, "vi"), (Mode::En, "en")] {
            let value = mode_property(mode).unwrap();
            assert_eq!(signature(&value), "(sa{sv}suvsvbbuvv)");
            let fields = fields(&value);
            assert_eq!(string(&fields[0]), "IBusProperty");
            assert_eq!(string(&fields[2]), "InputMode");
            assert_eq!(fields[8], Variant::Bool(true));
            assert_eq!(signature(unboxed(&fields[10])), "(sa{sv}av)");
            assert_eq!(string(&self::fields(unboxed(&fields[11]))[2]), symbol);
        }
    }

    #[test]
    fn property_list_holds_the_one_property() {
        let value = mode_property_list(Mode::En).unwrap();
        assert_eq!(signature(&value), "(sa{sv}av)");
        let fields = fields(&value);
        assert_eq!(string(&fields[0]), "IBusPropList");
        let Variant::Array(list) = &fields[2] else {
            panic!("not an array");
        };
        assert_eq!(list.len(), 1);
        assert_eq!(signature(unboxed(&list[0])), "(sa{sv}suvsvbbuvv)");
    }

    #[test]
    fn property_values_of_any_other_shape_are_refused() {
        let pair = |fields: &[u32]| {
            let mut builder = Structure::builder();
            for field in fields {
                builder.push_field(*field);
            }
            Variant::Structure(builder.build().unwrap())
        };
        assert_eq!(content_type(&pair(&[8, 1])), Some((8, 1)));
        assert_eq!(content_type(&pair(&[8])), None);
        assert_eq!(content_type(&pair(&[8, 1, 2])), None);
        assert_eq!(content_type(&Variant::U32(8)), None);
        assert_eq!(content_type(&Variant::from("password")), None);

        let single = |value: Variant<'static>| {
            Variant::Structure(Structure::builder().append_field(value).build().unwrap())
        };
        assert_eq!(flag(&single(Variant::Bool(true))), Some(true));
        assert_eq!(flag(&single(Variant::Bool(false))), Some(false));
        assert_eq!(flag(&single(Variant::U32(1))), None);
        assert_eq!(flag(&Variant::Bool(true)), None);
        assert_eq!(flag(&pair(&[1, 1])), None);
    }

    #[test]
    fn password_pin_and_private_fields_are_private() {
        assert!(is_private(8, 0));
        assert!(is_private(9, 0));
        assert!(is_private(0, 1 << 11));
        assert!(!is_private(0, 0));
        // Terminal purpose, spell-check hint.
        assert!(!is_private(10, 1));
    }
}
