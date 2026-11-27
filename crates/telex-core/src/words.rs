//! Word lists embedded at compile time, used only at the end of a word.
//!
//! All files are sorted by byte order with one word per line (LF), so a
//! binary search over the text finds a line without building any index and
//! without allocating. Lookups compare case-folded characters on the fly, so
//! no folded copy of the typed word is ever made (SEC-4).

/// English words whose Telex reading the engine changes (lowercase ASCII).
const EN: &str = include_str!("../data/en.txt");
/// Common English words that Telex leaves unchanged and that are rare as
/// Vietnamese (lowercase ASCII, hand-curated).
const EN_PLAIN: &str = include_str!("../data/en_plain.txt");
/// Real Vietnamese syllables (lowercase, NFC, with tone and marks).
const VI: &str = include_str!("../data/vi.txt");
/// Vietnamese syllables that Telex leaves unchanged and that are also English
/// words (lowercase ASCII, generated, D15).
const EN_BOTH: &str = include_str!("../data/en_both.txt");

/// `raw` (the keys typed) is in the English list, ignoring ASCII case.
pub(crate) fn is_english(raw: &str) -> bool {
    contains(EN, raw.chars().map(|c| c.to_ascii_lowercase()))
}

/// `raw` (the keys typed) is in the list of common, unchanged English words,
/// ignoring ASCII case.
pub(crate) fn is_plain_english(raw: &str) -> bool {
    contains(EN_PLAIN, raw.chars().map(|c| c.to_ascii_lowercase()))
}

/// `raw` (the keys typed) is an unchanged Vietnamese syllable that is also an
/// English word, ignoring ASCII case.
pub(crate) fn is_also_english(raw: &str) -> bool {
    contains(EN_BOTH, raw.chars().map(|c| c.to_ascii_lowercase()))
}

/// `text` (the composed word) is in the Vietnamese list, ignoring case.
pub(crate) fn is_vietnamese(text: &str) -> bool {
    contains(VI, text.chars().flat_map(char::to_lowercase))
}

/// Binary search for a line equal to `key` in a byte-sorted, LF-separated
/// list. UTF-8 byte order equals code point order, so comparing `char`s
/// agrees with the order of the file.
fn contains<I>(list: &str, key: I) -> bool
where
    I: Iterator<Item = char> + Clone,
{
    let bytes = list.as_bytes();
    // Invariant: `lo` is a line start; candidates are the lines starting in `lo..hi`.
    let (mut lo, mut hi) = (0, bytes.len());
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        let start = bytes[lo..mid]
            .iter()
            .rposition(|&b| b == b'\n')
            .map_or(lo, |p| lo + p + 1);
        let end = bytes[start..]
            .iter()
            .position(|&b| b == b'\n')
            .map_or(bytes.len(), |p| start + p);
        match list[start..end].chars().cmp(key.clone()) {
            std::cmp::Ordering::Equal => return true,
            std::cmp::Ordering::Less => lo = end + 1,
            std::cmp::Ordering::Greater => hi = start,
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn has(list: &str, key: &str) -> bool {
        contains(list, key.chars())
    }

    #[test]
    fn finds_every_line_and_nothing_else() {
        let list = "a\nab\nb\nba\nbé\nc\nđ\n";
        for w in list.lines() {
            assert!(has(list, w), "{w}");
        }
        for w in ["", "0", "aa", "abc", "bb", "be", "bê", "d", "z", "đa"] {
            assert!(!has(list, w), "{w}");
        }
    }

    #[test]
    fn works_without_a_final_newline_and_on_one_line() {
        assert!(has("x\ny", "y"));
        assert!(has("x", "x"));
        assert!(!has("x", "y"));
        assert!(!has("", "x"));
    }

    #[test]
    fn embedded_lists_fold_case() {
        assert!(is_english("USER"));
        assert!(is_english("best"));
        assert!(!is_english("vieetj"));
        assert!(is_plain_english("The"));
        assert!(!is_plain_english("to"));
        assert!(is_also_english("To"));
        assert!(!is_also_english("cho"));
        assert!(is_vietnamese("Việt"));
        assert!(is_vietnamese("VIỆT"));
        assert!(!is_vietnamese("úe"));
    }

    #[test]
    fn every_vietnamese_entry_is_found_in_upper_case() {
        let missed: Vec<&str> = VI
            .lines()
            .filter(|l| !is_vietnamese(&l.to_uppercase()))
            .collect();
        assert!(
            missed.is_empty(),
            "{} missed: {:?}",
            missed.len(),
            &missed[..missed.len().min(20)]
        );
    }

    #[test]
    fn embedded_lists_are_sorted_and_unique() {
        for list in [EN, EN_PLAIN, EN_BOTH, VI] {
            let lines: Vec<&str> = list.lines().collect();
            assert!(lines.windows(2).all(|w| w[0] < w[1]));
            assert!(
                lines
                    .iter()
                    .all(|l| !l.is_empty() && *l == l.to_lowercase())
            );
        }
    }
}
