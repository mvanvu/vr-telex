//! AC-1: every case of the independent golden list (T3) must match exactly.

use std::path::PathBuf;

use telex_core::Composer;

/// Types `keys` the way ime-core will: letters go to the composer, any other
/// character commits the current word and is passed through.
fn type_text(keys: &str) -> String {
    let mut out = String::new();
    let mut c = Composer::new();
    for ch in keys.chars() {
        if ch.is_ascii_alphabetic() {
            c.push(ch);
        } else {
            out.push_str(c.text());
            c.clear();
            out.push(ch);
        }
    }
    out.push_str(c.text());
    out
}

#[test]
fn golden_list() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/golden/telex_golden.tsv");
    // A missing list must fail: AC-1 cannot pass with zero cases checked.
    let data = match std::fs::read_to_string(&path) {
        Ok(data) => data,
        Err(err) => panic!("cannot read golden list {}: {err}", path.display()),
    };
    let mut cases = 0usize;
    let mut mismatches = Vec::new();
    for (no, line) in data.lines().enumerate() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((keys, want)) = line.split_once('\t') else {
            mismatches.push(format!("line {}: no TAB", no + 1));
            continue;
        };
        cases += 1;
        let got = type_text(keys);
        if got != want {
            mismatches.push(format!(
                "line {}: {keys:?} want {want:?} got {got:?}",
                no + 1
            ));
        }
    }
    assert!(
        cases >= 2000,
        "golden list has only {cases} cases (AC-1 needs >= 2000)"
    );
    assert!(
        mismatches.is_empty(),
        "{} of {cases} golden cases failed:\n{}",
        mismatches.len(),
        mismatches.join("\n")
    );
    eprintln!("golden_list: {cases} cases passed");
}
