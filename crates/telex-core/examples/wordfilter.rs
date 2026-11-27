//! Word-list helper for `tools/wordlists/gen.py`: runs words through the Telex engine.
//!
//! stdin: one entry per line. Modes (first argument):
//! - `changed` (default): prints the words whose Telex reading differs from the word.
//! - `pairs`: prints `word<TAB>text` for those words.
//! - `check`: stdin lines are `expected<TAB>keys`; prints the lines whose engine text differs.
//!
//! Prints only word lists; nothing else is logged.
use std::io::{self, BufRead, Write};

use telex_core::Composer;

fn compose(keys: &str) -> String {
    let mut c = Composer::new();
    for ch in keys.chars() {
        c.push(ch);
    }
    c.text().to_string()
}

fn main() {
    let mode = std::env::args().nth(1).unwrap_or_else(|| "changed".into());
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let line = line.trim_end_matches('\r');
        if line.is_empty() {
            continue;
        }
        let res = match mode.as_str() {
            "check" => {
                let mut it = line.splitn(2, '\t');
                let (want, keys) = (it.next().unwrap_or(""), it.next().unwrap_or(""));
                let got = compose(keys);
                (got != want).then(|| format!("{want}\t{keys}\t{got}"))
            }
            "pairs" => {
                let got = compose(line);
                (got != line).then(|| format!("{line}\t{got}"))
            }
            _ => (compose(line) != line).then(|| line.to_string()),
        };
        if let Some(r) = res {
            let _ = writeln!(out, "{r}");
        }
    }
    let _ = out.flush();
}
