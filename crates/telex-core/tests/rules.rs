//! Rule-by-rule tests of the Telex engine (spec §4, D5, D13).

use telex_core::{Composer, Outcome};

fn type_word(keys: &str) -> (String, Outcome) {
    let mut c = Composer::new();
    let mut last = Outcome::Composing;
    for ch in keys.chars() {
        last = c.push(ch);
    }
    (c.text().to_owned(), last)
}

fn check(cases: &[(&str, &str)]) {
    let mut bad = Vec::new();
    for (keys, want) in cases {
        let (got, _) = type_word(keys);
        if got != *want {
            bad.push(format!("{keys:?}: want {want:?}, got {got:?}"));
        }
    }
    assert!(
        bad.is_empty(),
        "{} mismatches:\n{}",
        bad.len(),
        bad.join("\n")
    );
}

#[test]
fn tone_keys() {
    check(&[
        ("as", "á"),
        ("af", "à"),
        ("ar", "ả"),
        ("ax", "ã"),
        ("aj", "ạ"),
        ("asz", "a"),
        ("asf", "à"),
        ("ba", "ba"),
        ("bas", "bá"),
    ]);
}

#[test]
fn tone_anywhere_after_vowel() {
    check(&[
        ("vieetj", "việt"),
        ("vieejt", "việt"),
        ("tieengs", "tiếng"),
        ("tieensg", "tiếng"),
        ("nguwowif", "người"),
        ("nguowfi", "người"),
    ]);
}

#[test]
fn letter_transforms() {
    check(&[
        ("aa", "â"),
        ("ee", "ê"),
        ("oo", "ô"),
        ("aw", "ă"),
        ("ow", "ơ"),
        ("uw", "ư"),
        ("dd", "đ"),
        ("w", "ư"),
        ("tw", "tư"),
        ("nhw", "như"),
        ("uow", "ươ"),
        ("uown", "ươn"),
        ("giwf", "giừ"),
        ("nguowif", "người"),
        ("uwow", "ươ"),
        ("dduwowngf", "đường"),
        ("dduongwf", "đường"),
        ("muaw", "mưa"),
        ("hoawcj", "hoặc"),
        ("cuwus", "cứu"),
        ("huouw", "hươu"),
        ("quow", "quơ"),
    ]);
}

#[test]
fn undo_by_repeat() {
    check(&[
        ("ass", "as"),
        ("aff", "af"),
        ("aaa", "aa"),
        ("eee", "ee"),
        ("ooo", "oo"),
        ("ddd", "dd"),
        ("ww", "w"),
        ("aww", "aw"),
        ("uww", "uw"),
        ("uoww", "uow"),
        ("xooo", "xoo"),
        ("booss", "bôs"),
    ]);
}

#[test]
fn case_per_letter() {
    check(&[
        ("VIEETJ", "VIỆT"),
        ("Vieetj", "Việt"),
        ("DDuwowngf", "Đường"),
        ("Dd", "Đ"),
        ("W", "Ư"),
        ("ASS", "AS"),
        ("Aas", "Ấ"),
        ("vIEETJ", "vIỆT"),
    ]);
}

#[test]
fn modern_tone_placement() {
    check(&[
        ("hoaf", "hoà"),
        ("thuys", "thuý"),
        ("khoer", "khoẻ"),
        ("hoans", "hoán"),
        ("mias", "mía"),
        ("muas", "múa"),
        ("muwaf", "mừa"),
        ("tois", "tói"),
        ("hais", "hái"),
        ("ngoaif", "ngoài"),
        ("khuyur", "khuỷu"),
        ("ddeemf", "đềm"),
        ("muoons", "muốn"),
        ("chuyeenj", "chuyện"),
        ("yeeu", "yêu"),
        ("xoongs", "xống"),
        ("boongs", "bống"),
    ]);
}

#[test]
fn qu_and_gi() {
    check(&[
        ("quys", "quý"),
        ("quas", "quá"),
        ("quoocs", "quốc"),
        ("gias", "giá"),
        ("gif", "gì"),
        ("gifn", "gìn"),
        ("giuwax", "giữa"),
        ("gieengs", "giếng"),
    ]);
}

#[test]
fn invalid_words_pass_through_raw() {
    check(&[
        ("class", "class"),
        ("https", "https"),
        ("git", "git"),
        ("afc", "afc"),
        ("acf", "acf"),
        ("vieetf", "vieetf"),
        ("jaws", "jaws"),
        ("string", "string"),
        ("zoom", "zoom"),
        ("ea", "ea"),
        ("kas", "kas"),
        ("ce", "ce"),
        ("ghas", "ghas"),
        ("az", "az"),
        ("tiw", "tiw"),
        ("windows", "windows"),
    ]);
}

#[test]
fn more_letters_after_undo_restore_raw() {
    check(&[
        ("session", "session"),
        ("array", "array"),
        ("password", "password"),
        ("xooong", "xooong"),
        ("asss", "asss"),
    ]);
}

/// D18: a later `a`/`e`/`o` puts the hat on the matching earlier vowel when
/// the result is a valid syllable.
#[test]
fn free_order_circumflex() {
    check(&[
        ("vieset", "viết"),
        ("vietej", "việt"),
        ("vietje", "việt"),
        ("tiengse", "tiếng"),
        ("tiesnge", "tiếng"),
        ("xono", "xôn"),
        ("tana", "tân"),
        ("muonos", "muốn"),
        ("VIESET", "VIẾT"),
        ("Tana", "Tân"),
        // English words that form a syllable now change (D18 accepts it).
        ("reset", "rết"),
        ("photo", "phôt"),
    ]);
}

#[test]
fn free_order_circumflex_invalid_is_plain_letter() {
    check(&[
        // `oâ` is no nucleus: `a` stays a plain letter, the word goes raw.
        ("toana", "toana"),
        ("bae", "bae"),
        ("hoeo", "hoeo"),
    ]);
}

/// D18: a later `d` turns the initial `d` into `đ`.
#[test]
fn free_order_d() {
    check(&[
        ("dinhd", "đinh"),
        ("duowngd", "đương"),
        ("duowngfd", "đường"),
        ("duowngdf", "đường"),
        ("dad", "đa"),
        ("Dinhd", "Đinh"),
        ("DINHD", "ĐINH"),
        // No initial `d`: a plain letter, and `d` is no final.
        ("band", "band"),
    ]);
}

#[test]
fn free_order_keeps_undo_by_repeat() {
    check(&[
        ("vietee", "viete"),
        ("tanaa", "tana"),
        ("dadd", "dad"),
        ("dinhdd", "dinhd"),
        ("aaa", "aa"),
        ("ass", "as"),
        ("ddd", "dd"),
    ]);
}

#[test]
fn outcome_reports_passthrough() {
    assert_eq!(type_word("vieet").1, Outcome::Composing);
    assert_eq!(type_word("cl").1, Outcome::Invalid);
    assert_eq!(type_word("class").1, Outcome::Invalid);
}

#[test]
fn raw_and_pop() {
    let mut c = Composer::new();
    assert!(c.is_empty());
    for ch in "vieetj".chars() {
        c.push(ch);
    }
    assert_eq!(c.raw(), "vieetj");
    assert_eq!(c.pop(), Outcome::Composing);
    assert_eq!(c.text(), "viêt");
    c.pop();
    c.pop();
    assert_eq!(c.text(), "vi");
    // Popping back out of a raw word re-validates it.
    let mut c = Composer::new();
    for ch in "acf".chars() {
        c.push(ch);
    }
    assert_eq!(c.text(), "acf");
    assert_eq!(c.pop(), Outcome::Composing);
    assert_eq!(c.text(), "ac");
    c.pop();
    c.pop();
    assert!(c.is_empty());
    assert_eq!(c.pop(), Outcome::Composing);
    assert_eq!(c.text(), "");
}

#[test]
fn clear_resets() {
    let mut c = Composer::new();
    for ch in "class".chars() {
        c.push(ch);
    }
    c.clear();
    assert!(c.is_empty());
    assert_eq!(c.text(), "");
    assert_eq!(c.raw(), "");
    c.push('a');
    c.push('s');
    assert_eq!(c.text(), "á");
}

#[test]
fn non_letter_input_never_panics() {
    let mut c = Composer::new();
    for ch in "vieet1".chars() {
        c.push(ch);
    }
    assert_eq!(c.text(), "viêt1");
}

#[test]
fn output_is_precomposed() {
    // Every vowel × tone renders to one precomposed code point (NFC), both cases.
    for v in [
        "a", "aw", "aa", "e", "ee", "i", "o", "oo", "ow", "u", "uw", "y",
    ] {
        for t in ["", "s", "f", "r", "x", "j"] {
            for keys in [format!("{v}{t}"), format!("{v}{t}").to_uppercase()] {
                let (got, _) = type_word(&keys);
                assert_eq!(got.chars().count(), 1, "{keys:?} -> {got:?}");
            }
        }
    }
}

#[test]
fn debug_is_redacted() {
    let mut c = Composer::new();
    for ch in "zqxvieetj".chars() {
        c.push(ch);
    }
    let dbg = format!("{c:?}");
    assert!(!dbg.contains("vie"), "{dbg}");
    assert!(!dbg.contains('ệ'), "{dbg}");
    assert!(dbg.contains("redacted"), "{dbg}");
}

/// Types `keys`; `<` stands for BackSpace (`Composer::pop`).
fn type_with_bs(keys: &str) -> (String, Outcome) {
    let mut c = Composer::new();
    let mut last = Outcome::Composing;
    for ch in keys.chars() {
        last = if ch == '<' { c.pop() } else { c.push(ch) };
    }
    (c.text().to_owned(), last)
}

fn check_bs(cases: &[(&str, &str)]) {
    let mut bad = Vec::new();
    for (keys, want) in cases {
        let (got, _) = type_with_bs(keys);
        if got != *want {
            bad.push(format!("{keys:?}: want {want:?}, got {got:?}"));
        }
    }
    assert!(
        bad.is_empty(),
        "{} mismatches:\n{}",
        bad.len(),
        bad.join("\n")
    );
}

#[test]
fn backspace_after_undo_removes_last_shown_char() {
    check_bs(&[
        ("ass<", "a"),
        ("aaa<", "a"),
        ("ddd<", "d"),
        ("ww<", ""),
        ("uww<", "u"),
        ("booss<", "bô"),
        ("booss<s", "bố"),
        ("ass<s", "á"),
        ("vieet1<", "viêt"),
        ("vieet1<j", "việt"),
    ]);
}

#[test]
fn backspace_after_a_mark_removes_the_marked_letter() {
    check_bs(&[
        ("tuw<", "t"),
        ("aa<", ""),
        ("dd<", ""),
        ("nguowi<", "ngươ"),
        ("nguowif<", "ngươi"),
        ("vieet<", "viê"),
        ("dduongw<", "đươn"),
        ("tuw<a", "ta"),
        ("nguowi<<n", "ngưn"),
    ]);
}

#[test]
fn backspace_after_a_tone_key_removes_the_tone() {
    check_bs(&[
        ("vieets<j", "việt"),
        ("hoaf<s", "hoá"),
        ("asz<", "á"),
        ("vieetj<<", "viê"),
    ]);
}

#[test]
fn backspace_in_raw_words() {
    check_bs(&[
        ("class<", "clas"),
        ("vieetf<", "vieet"),
        ("acf<", "ac"),
        ("acf<s", "ác"),
        ("session<<<<<", "se"),
    ]);
    assert_eq!(type_with_bs("acf<").1, Outcome::Composing);
    assert_eq!(type_with_bs("vieetf<").1, Outcome::Invalid);
}

#[test]
fn backspace_state_stays_consistent() {
    // After BackSpace the composer keeps working on what is shown.
    check_bs(&[
        ("tuw<<<", ""),
        ("Tuw<", "T"),
        ("VIEETJ<", "VIÊT"),
        ("nguowi<f", "ngườ"),
        ("aa<aa", "â"),
    ]);
}

#[test]
fn backspace_after_free_order_marks() {
    check_bs(&[
        ("vieset<", "viế"),
        ("dinhd<", "đin"),
        ("tana<", "tâ"),
        ("vieset<t", "viết"),
    ]);
}

#[test]
fn backspace_after_undo_reports_raw_when_no_syllable_fits() {
    // `w` undoes the mid-word ư, leaving letters t,w,n that no syllable fits.
    let (text, outcome) = type_with_bs("twnw<");
    assert_eq!(text, "twn");
    assert_eq!(outcome, Outcome::Invalid);
    check_bs(&[("twnw<a", "twna")]);
}
