//! AC-7: what `Composer::finish` does to the golden list, the 25 English words
//! of the spec and an English sample. The golden check is a real assertion;
//! the English sample reads the system word list and only reports numbers
//! (`cargo test -p telex-core --test finish_measure -- --ignored --nocapture`).

use std::collections::HashSet;
use std::path::PathBuf;

use telex_core::{Composer, Lang};

fn read(path: &PathBuf) -> String {
    match std::fs::read_to_string(path) {
        Ok(d) => d,
        Err(err) => panic!("cannot read {}: {err}", path.display()),
    }
}

fn manifest(rel: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(rel)
}

fn composed(keys: &str) -> Composer {
    let mut c = Composer::new();
    for ch in keys.chars() {
        c.push(ch);
    }
    c
}

/// The words of a golden line's keys, split the way ime-core ends words.
fn words(keys: &str) -> impl Iterator<Item = &str> {
    keys.split(|c: char| !c.is_ascii_alphabetic())
        .filter(|w| !w.is_empty())
}

#[test]
fn golden_syllables_in_the_vietnamese_list_are_unchanged() {
    let vi_data = read(&manifest("data/vi.txt"));
    let vi: HashSet<&str> = vi_data.lines().collect();
    let golden = read(&manifest("tests/golden/telex_golden.tsv"));
    let en_data = read(&manifest("data/en.txt"));
    let en: HashSet<&str> = en_data.lines().collect();
    let plain_data = read(&manifest("data/en_plain.txt"));
    let plain: HashSet<&str> = plain_data.lines().collect();
    let mut plain_hits = 0usize;
    let (mut in_vi, mut not_in_vi, mut not_in_vi_changed) = (0usize, 0usize, 0usize);
    let mut not_in_vi_changed_en = 0usize;
    let mut examples = Vec::new();
    let mut bad = Vec::new();
    for line in golden.lines() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((keys, _)) = line.split_once('\t') else {
            continue;
        };
        for word in words(keys) {
            let c = composed(word);
            let known = vi.contains(c.text().to_lowercase().as_str());
            let is_plain = plain.contains(word.to_ascii_lowercase().as_str());
            let mut changed = false;
            for prev in [Lang::Unknown, Lang::Vi] {
                let f = c.finish(prev);
                changed |= f.text != c.text();
                // A word whose text equals its keys keeps the previous language,
                // unless it is in the plain English list (D10).
                let lang = match (c.text() == c.raw(), is_plain) {
                    (true, true) => Lang::En,
                    (true, false) => prev,
                    (false, _) => Lang::Vi,
                };
                if known && (f.text != c.text() || f.lang != lang) {
                    bad.push(format!("{word:?} prev {prev:?} -> {:?}", f.lang));
                }
            }
            if known {
                in_vi += 1;
                plain_hits += usize::from(is_plain);
            } else {
                not_in_vi += 1;
                not_in_vi_changed += usize::from(changed);
                if changed {
                    let in_en = en.contains(word.to_ascii_lowercase().as_str());
                    not_in_vi_changed_en += usize::from(in_en);
                    if examples.len() < 40 {
                        examples.push(format!(
                            "{word}->{}{}",
                            c.text(),
                            if in_en { "(en)" } else { "" }
                        ));
                    }
                }
            }
        }
    }
    eprintln!(
        "golden words: {in_vi} in vi.txt (unchanged by finish: {}; {plain_hits} of them plain English, language En), {not_in_vi} not in vi.txt \
         ({not_in_vi_changed} of them changed by finish with prev Unknown or Vi, \
         {not_in_vi_changed_en} of those with keys in en.txt); changed examples: {examples:?}",
        in_vi - bad.len().min(in_vi)
    );
    assert!(in_vi > 10_000, "only {in_vi} golden words found in vi.txt");
    assert!(bad.is_empty(), "{} changed:\n{}", bad.len(), bad.join("\n"));
}

const SPEC_WORDS: [&str; 25] = [
    "this", "see", "now", "how", "use", "user", "two", "was", "is", "as", "us", "has", "his",
    "her", "most", "host", "box", "mix", "max", "tax", "car", "test", "best", "last", "list",
];

#[test]
fn spec_words_after_an_english_word_are_english() {
    let mut first = Vec::new();
    let after_the = composed("the").finish(Lang::Unknown).lang;
    let mut after = Vec::new();
    for w in SPEC_WORDS {
        let c = composed(w);
        assert_eq!(c.finish(Lang::En).text, w, "{w} after an English word");
        if c.finish(Lang::Unknown).text == w {
            first.push(w);
        }
        if c.finish(after_the).text == w {
            after.push(w);
        }
    }
    eprintln!(
        "spec words: sentence-first English {}/25 {first:?}; after `the` {}/25; \
         after an English word 25/25",
        first.len(),
        after.len()
    );
    for w in ["use", "user", "two"] {
        assert!(first.contains(&w), "{w} sentence-first");
    }
    assert_eq!(after.len(), SPEC_WORDS.len(), "after `the`: {after:?}");
}

/// English sample: every lowercase ASCII word of 2 to 6 letters in the system
/// list (wamerican), in file order. The list carries no frequency, so short
/// words stand in for common ones.
#[test]
#[ignore = "reads /usr/share/dict/american-english; run for the AC-7 numbers"]
fn english_sample_unchanged_rate() {
    let path = PathBuf::from("/usr/share/dict/american-english");
    let Ok(dict) = std::fs::read_to_string(&path) else {
        eprintln!("skip: {} not found", path.display());
        return;
    };
    let sample: Vec<&str> = dict
        .lines()
        .filter(|w| (2..=6).contains(&w.len()) && w.bytes().all(|b| b.is_ascii_lowercase()))
        .collect();
    let after_the = composed("the").finish(Lang::Unknown).lang;
    let mut the = 0usize;
    let (mut before, mut unknown, mut en) = (0usize, 0usize, 0usize);
    for w in &sample {
        let c = composed(w);
        before += usize::from(c.text() == *w);
        unknown += usize::from(c.finish(Lang::Unknown).text == *w);
        en += usize::from(c.finish(Lang::En).text == *w);
        the += usize::from(c.finish(after_the).text == *w);
    }
    let pct = |n: usize| 100.0 * n as f64 / sample.len() as f64;
    eprintln!(
        "english sample: {} words; unchanged before (text) {before} ({:.2} %), \
         finish(Unknown) {unknown} ({:.2} %), finish(En) {en} ({:.2} %), after `the` {the} ({:.2} %)",
        sample.len(),
        pct(before),
        pct(unknown),
        pct(en),
        pct(the)
    );
    assert!(sample.len() >= 2000);
}
