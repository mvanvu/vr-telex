//! AC-10: key handling p99 < 5 ms.

mod common;

use std::time::{Duration, Instant};

use common::{PREEDIT, SURROUNDING, ctx, ime, key, press, tap_ctrl_shift};
use ime_core::keysym;

const KEYS: usize = 10_000;

#[test]
fn process_key_p99_is_under_5_ms() {
    let prose = "tieesng vieejt class nguowif dduowngf windows hoaf thuys \
                 khuyeenx as<s password nghieeng https giuwowngf, 123. ";
    // The costliest input: a word at the length cap, edited at its end.
    let worst = format!("{}{} ", "qwrtpsdf".repeat(4), "<x".repeat(40));
    for (caps, text) in [
        (PREEDIT, prose),
        (SURROUNDING, prose),
        (PREEDIT, worst.as_str()),
        (SURROUNDING, worst.as_str()),
    ] {
        let mut ime = ime();
        let id = ctx(&mut ime, caps);
        let mut samples = Vec::with_capacity(KEYS);
        let mut actions = 0usize;
        for (n, c) in text.chars().cycle().take(KEYS).enumerate() {
            let ev = if c == '<' {
                press(keysym::BACKSPACE)
            } else {
                key(c)
            };
            let start = Instant::now();
            let result = ime.process_key(id, ev);
            samples.push(start.elapsed());
            actions += result.actions.len();
            if n % 1000 == 999 {
                // Mode switches are part of a real session (two taps: back to VI).
                tap_ctrl_shift(&mut ime, id);
                tap_ctrl_shift(&mut ime, id);
            }
        }
        assert_eq!(samples.len(), KEYS);
        assert!(actions > KEYS / 2, "the keys were really composed");

        samples.sort_unstable();
        let p50 = samples[KEYS / 2];
        let p99 = samples[KEYS * 99 / 100];
        let max = samples[KEYS - 1];
        println!(
            "process_key over {KEYS} keys, caps {caps:?}: p50 {p50:?}, p99 {p99:?}, max {max:?}"
        );
        assert!(p99 < Duration::from_millis(5), "p99 {p99:?}");
    }
}
