//! AC-10 (D24): a key's round trip through the frontend — the call over the
//! socket, the IME, the signals and the reply — has a p99 under 5 ms.

mod common;

use std::time::{Duration, Instant};

use common::*;

const KEYS: usize = 4_000;

#[test]
fn process_key_round_trip_p99_is_under_5_ms() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        let path = shell.shell_context().await;

        let prose = "tieesng vieejt class nguowif dduowngf windows hoaf thuys khuyeenx ";
        let mut samples = Vec::with_capacity(KEYS);
        let mut written = 0usize;
        for letter in prose.chars().cycle().take(KEYS) {
            let start = Instant::now();
            let press = shell.key(&path, letter as u32, 0).await;
            samples.push(start.elapsed());
            written += press.before.len();
            shell.key(&path, letter as u32, RELEASE).await;
        }
        assert!(written > KEYS / 2, "the keys were really composed");

        samples.sort_unstable();
        let p50 = samples[KEYS / 2];
        let p99 = samples[KEYS * 99 / 100];
        let max = samples[KEYS - 1];
        println!(
            "ProcessKeyEvent round trip over {KEYS} keys: p50 {p50:?}, p99 {p99:?}, max {max:?}"
        );
        assert!(p99 < Duration::from_millis(5), "p99 {p99:?}");
    });
}
