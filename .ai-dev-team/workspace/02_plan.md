# Plan — EN-DETECT (spec 01_spec.md)

## Contracts
### Data files (E1 → E2)
- `crates/telex-core/data/en.txt`: lowercase ASCII English words, one per line, unique, sorted by byte order, LF,
  no comments, no blank lines. Only words of length ≥ 2 whose Telex reading the current engine changes
  (`Composer` text after all keys != keys) — the others never need a restore.
- `crates/telex-core/data/vi.txt`: real Vietnamese syllables, lowercase, NFC, with tone and marks, one per line,
  unique, sorted by byte order, LF. Inclusive when in doubt (a missing real syllable makes Vietnamese typing restore
  to English, which is worse than a missed English word). Must contain every attested syllable among the Vietnamese
  forms the `en.txt` words produce.
- Generator and provenance: `tools/wordlists/` (README with sources, versions, licenses and the exact regenerate
  commands; Python stdlib only, run with `-I`; the engine filter step may use a cargo example in
  `crates/telex-core/examples/`). Third-party notice: `THIRD-PARTY-NOTICES.md` at the repo root.

### telex-core API (E2 → E3)
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Lang { #[default] Unknown, En, Vi }

pub struct Finished<'a> { pub text: &'a str, pub lang: Lang }

impl Composer {
    /// What to commit at the end of the word, given the previous word's language in the same field.
    /// Borrowed from the composer's own buffers (text or raw); no allocation.
    pub fn finish(&self, prev: Lang) -> Finished<'_>;
}
```
Rules: AC-1 (incomplete syllable → raw), AC-2 (English not Vietnamese → raw), AC-3 (overlap → prev decides),
AC-4 language of the result. Lists embedded with `include_str!`, looked up by binary search on lines (or a
`OnceLock` sorted slice) — case-folded lookups, no allocation per key; work only in `finish`.
`text()` keeps meaning "what is shown now" (golden tests unchanged).

### ime-core (E3)
`Context` keeps `last: Lang` (no text). `flush` uses `composer.finish(ctx.last)`; per edit mode:
Preedit → HidePreedit + Commit(finished.text) (fe-ibus reorders as today); Hold → Commit(finished.text);
Surrounding → when finished.text != shown text: DeleteSurrounding(shown chars) + Commit(finished.text).
`last` updated at every flush (also for passthrough words, which end as En when they contain letters);
reset to Unknown on focus_in, focus_out, reset, create, mode toggle, set_enabled(false).
Overflowed (MAX_WORD_KEYS) words: unchanged behaviour, `last` = En.

## Tasks
- E1 data + generator (sonnet, content). No code in src/.
- E2 engine `finish` + completeness + tests + measurement (opus). Needs E1's files.
- E3 ime-core wiring + tests in ime-core (opus, security: per-context state, SEC-2/SEC-4). Needs E2 API.
Order E1 → E2 → E3 (shared compile unit, each consumes the previous). Then sign-off qc (workspace tests, guard,
e2e smoke on the daemon), Phase 5 (correctness + security, Agent tool, unattended), install from the final commit.

## Reuse
`Composer` raw/text buffers and `parse` / `nucleus_ok` (OPEN/CLOSED tables) for AC-1; `wipe_string`/zeroize
patterns for any temporary; ime-core `compose` diff logic for the surrounding-mode delete+commit.
