//! Word-end decision (`Composer::finish`): complete-syllable check (AC-1),
//! English restore (AC-2), overlap by previous word (AC-3) and the language
//! of the result (AC-4).

use std::path::PathBuf;

use telex_core::{Composer, Lang, Outcome};

fn composed(keys: &str) -> Composer {
    let mut c = Composer::new();
    for ch in keys.chars() {
        c.push(ch);
    }
    c
}

fn finish(keys: &str, prev: Lang) -> (String, Lang) {
    let c = composed(keys);
    let f = c.finish(prev);
    (f.text.to_owned(), f.lang)
}

fn check(prev: Lang, cases: &[(&str, &str, Lang)]) {
    let mut bad = Vec::new();
    for &(keys, want, lang) in cases {
        let got = finish(keys, prev);
        if got != (want.to_owned(), lang) {
            bad.push(format!(
                "{keys:?} prev {prev:?}: want ({want:?}, {lang:?}), got {got:?}"
            ));
        }
    }
    assert!(
        bad.is_empty(),
        "{} mismatches:\n{}",
        bad.len(),
        bad.join("\n")
    );
}

const ALL: [Lang; 3] = [Lang::Unknown, Lang::En, Lang::Vi];

#[test]
fn lang_defaults_to_unknown() {
    assert_eq!(Lang::default(), Lang::Unknown);
}

#[test]
fn incomplete_syllable_commits_raw_keys() {
    for prev in ALL {
        check(
            prev,
            &[
                ("use", "use", Lang::En),
                ("user", "user", Lang::En),
                ("two", "two", Lang::En),
                ("aw", "aw", Lang::En),
                ("aa", "aa", Lang::En),
                ("uow", "uow", Lang::En),
                ("Uow", "Uow", Lang::En),
                ("tuow", "tuow", Lang::En),
                ("ues", "ues", Lang::En),
                ("USER", "USER", Lang::En),
            ],
        );
    }
}

#[test]
fn words_without_vowel_keep_their_text() {
    for prev in ALL {
        check(
            prev,
            &[
                ("dd", "đ", Lang::Vi),
                ("DD", "Đ", Lang::Vi),
                ("d", "d", prev),
                ("ngh", "ngh", prev),
            ],
        );
    }
}

#[test]
fn complete_vietnamese_syllables_stay() {
    for prev in ALL {
        check(
            prev,
            &[
                ("vieetj", "việt", Lang::Vi),
                ("Vieetj", "Việt", Lang::Vi),
                ("nguwowif", "người", Lang::Vi),
                ("w", "ư", Lang::Vi),
                ("tw", "tư", Lang::Vi),
                ("awn", "ăn", Lang::Vi),
                ("hoaf", "hoà", Lang::Vi),
                ("ddi", "đi", Lang::Vi),
            ],
        );
    }
}

#[test]
fn overlap_follows_the_previous_word() {
    let vi = [
        ("best", "bét", Lang::Vi),
        ("list", "lít", Lang::Vi),
        ("has", "há", Lang::Vi),
        ("Best", "Bét", Lang::Vi),
    ];
    check(Lang::Unknown, &vi);
    check(Lang::Vi, &vi);
    check(
        Lang::En,
        &[
            ("best", "best", Lang::En),
            ("list", "list", Lang::En),
            ("has", "has", Lang::En),
            ("Best", "Best", Lang::En),
            ("BEST", "BEST", Lang::En),
        ],
    );
}

#[test]
fn passthrough_and_undo_words_are_english() {
    for prev in ALL {
        check(
            prev,
            &[
                ("class", "class", Lang::En),
                ("https", "https", Lang::En),
                ("ass", "as", Lang::En),
                ("lisst", "list", Lang::En),
                ("asss", "asss", Lang::En),
                ("ddd", "dd", Lang::En),
            ],
        );
    }
}

#[test]
fn passthrough_text_with_vietnamese_letters_is_vietnamese() {
    // Undo of the tone keeps the marked letters shown (`viêts`).
    for prev in ALL {
        let (text, lang) = finish("vieetss", prev);
        assert_eq!(text, composed("vieetss").text());
        assert!(!text.is_ascii());
        assert_eq!(lang, Lang::Vi);
    }
}

#[test]
fn unchanged_ascii_words_keep_the_previous_language() {
    for prev in ALL {
        check(
            prev,
            &[("ba", "ba", prev), ("to", "to", prev), ("can", "can", prev)],
        );
    }
}

#[test]
fn empty_word_keeps_the_previous_language() {
    for prev in ALL {
        let c = Composer::new();
        let f = c.finish(prev);
        assert_eq!((f.text, f.lang), ("", prev));
    }
}

#[test]
fn finish_does_not_change_the_shown_text() {
    let c = composed("best");
    let shown = c.text().to_owned();
    let _ = c.finish(Lang::En);
    assert_eq!(c.text(), shown);
    assert_eq!(c.raw(), "best");
}

#[test]
fn finished_debug_hides_the_text() {
    let c = composed("user");
    let f = c.finish(Lang::Unknown);
    let dbg = format!("{f:?}");
    assert!(!dbg.contains("user"), "{dbg}");
    assert!(dbg.contains("En"), "{dbg}");
}

fn data(name: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("data")
        .join(name);
    match std::fs::read_to_string(&path) {
        Ok(d) => d,
        Err(err) => panic!("cannot read {}: {err}", path.display()),
    }
}

/// Every English-list word: restored unless its Vietnamese form is a real
/// syllable, in which case the previous word decides.
#[test]
fn every_english_list_word_follows_the_rules() {
    let en = data("en.txt");
    let vi = data("vi.txt");
    let vi: std::collections::HashSet<&str> = vi.lines().collect();
    let mut bad = Vec::new();
    let mut words = 0;
    let mut passthrough = 0;
    let mut no_vowel = 0;
    for word in en.lines() {
        words += 1;
        let mut c = Composer::new();
        let last = word.chars().map(|ch| c.push(ch)).last();
        if last == Some(Outcome::Invalid) {
            // Undo-by-repeat words keep the text shown (D37-D40); only its
            // language is decided.
            passthrough += 1;
            for prev in ALL {
                if c.finish(prev).text != c.text() {
                    bad.push(format!("{word}: passthrough text changed"));
                }
            }
            continue;
        }
        if c.text().chars().all(|ch| "bcdđghklmnpqrstvx".contains(ch)) {
            // AC-1: a word without a vowel keeps its text (`dd` → đ).
            no_vowel += 1;
            for prev in ALL {
                if c.finish(prev).text != c.text() {
                    bad.push(format!("{word}: no-vowel text changed"));
                }
            }
            continue;
        }
        let real = vi.contains(c.text());
        let unknown = c.finish(Lang::Unknown);
        let want = if real {
            (c.text(), Lang::Vi)
        } else {
            (word, Lang::En)
        };
        if (unknown.text, unknown.lang) != want {
            bad.push(format!("{word}: Unknown -> {:?}", unknown.lang));
        }
        let en = c.finish(Lang::En);
        if (en.text, en.lang) != (word, Lang::En) {
            bad.push(format!("{word}: En -> {:?}", en.lang));
        }
        let upper = word.to_ascii_uppercase();
        let cu = composed(&upper);
        let fu = cu.finish(Lang::En);
        if fu.text != upper {
            bad.push(format!("{upper}: En not restored in typed case"));
        }
    }
    eprintln!(
        "en.txt: {words} words, {passthrough} end as passthrough (undo by repeat), {no_vowel} without vowel"
    );
    assert!(words > 0, "en.txt is empty");
    assert!(
        bad.is_empty(),
        "{} mismatches:\n{}",
        bad.len(),
        bad.join("\n")
    );
}

/// D10: a common English word typed as is (`the`) commits unchanged and makes
/// the field English, so the overlap word after it is restored.
#[test]
fn plain_english_words_set_english() {
    for prev in ALL {
        check(
            prev,
            &[
                ("the", "the", Lang::En),
                ("The", "The", Lang::En),
                ("THE", "THE", Lang::En),
                ("with", "with", Lang::En),
                ("would", "would", Lang::En),
            ],
        );
    }
    let mut prev = Lang::Unknown;
    for (keys, want) in [("the", "the"), ("best", "best")] {
        let c = composed(keys);
        let f = c.finish(prev);
        assert_eq!(f.text, want, "{keys}");
        prev = f.lang;
    }
    assert_eq!(prev, Lang::En);
    let the = composed("the").finish(Lang::Unknown).lang;
    assert_eq!(composed("Box").finish(the).text, "Box");
}

/// Words common in Vietnamese stay out of the plain list: they keep `prev`.
#[test]
fn vietnamese_looking_plain_words_keep_the_previous_language() {
    for prev in ALL {
        check(
            prev,
            &[
                ("to", "to", prev),
                ("in", "in", prev),
                ("an", "an", prev),
                ("tin", "tin", prev),
                ("ban", "ban", prev),
                ("cho", "cho", prev),
                ("nam", "nam", prev),
                ("con", "con", prev),
                ("say", "say", prev),
                ("that", "that", prev),
                ("them", "them", prev),
                ("then", "then", prev),
                ("on", "on", prev),
                ("ten", "ten", prev),
                ("met", "met", prev),
                ("be", "be", prev),
                ("he", "he", prev),
                ("my", "my", prev),
                ("go", "go", prev),
            ],
        );
    }
}

/// A Vietnamese sentence typed with Telex is not affected by the plain list.
#[test]
fn vietnamese_sentence_stays_vietnamese() {
    let mut prev = Lang::Unknown;
    let mut out = Vec::new();
    for keys in [
        "toi", "raats", "thichs", "hocj", "tieengs", "vieetj", "cho", "ban", "best",
    ] {
        let c = composed(keys);
        let f = c.finish(prev);
        out.push(f.text.to_owned());
        if f.lang != Lang::Unknown {
            prev = f.lang;
        }
    }
    assert_eq!(
        out,
        [
            "toi", "rất", "thích", "học", "tiếng", "việt", "cho", "ban", "bét"
        ]
    );
    assert_eq!(prev, Lang::Vi);
}

/// Every plain-list entry is left unchanged by Telex and sets English in any case.
#[test]
fn every_plain_english_word_is_unchanged_and_english() {
    let list = data("en_plain.txt");
    let en = data("en.txt");
    let en: std::collections::HashSet<&str> = en.lines().collect();
    let mut bad = Vec::new();
    for word in list.lines() {
        if word.is_empty() || !word.bytes().all(|b| b.is_ascii_lowercase()) || en.contains(word) {
            bad.push(format!("{word:?}: bad entry"));
            continue;
        }
        for typed in [word.to_owned(), word.to_ascii_uppercase()] {
            let c = composed(&typed);
            for prev in ALL {
                let f = c.finish(prev);
                if (f.text, f.lang) != (typed.as_str(), Lang::En) {
                    bad.push(format!("{typed}: got ({:?}, {:?})", f.text, f.lang));
                }
            }
        }
    }
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}

/// Plain-list rule: no entry is a Vietnamese syllable, except `the` (D10).
#[test]
fn plain_english_words_are_not_vietnamese_syllables() {
    let plain = data("en_plain.txt");
    let vi = data("vi.txt");
    let vi: std::collections::HashSet<&str> = vi.lines().collect();
    let hits: Vec<&str> = plain
        .lines()
        .filter(|w| *w != "the" && vi.contains(w))
        .collect();
    assert!(hits.is_empty(), "in vi.txt: {hits:?}");
}
