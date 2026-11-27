# Spec — English word detection at word end (EN-DETECT)

has_ui: false
security_sensitive: true (ime-core keeps per-context state about typed words; SEC-2/SEC-4 apply)
route: new feature, unattended (user away from 14:22, 27 Nov)

## Problem
With Telex on, English words that form a valid Vietnamese syllable (or a prefix of one) are turned
into Vietnamese: of ~90 common English words, 25 change on master 43fa547 —
`this→thí see→sê now→nơ how→hơ use→úe user→ủe two→tưo was→ứa is→í as→á us→ú has→há his→hí her→hẻ
most→mót host→hót box→bõ mix→mĩ max→mã tax→tã car→cả test→tét best→bét last→lát list→lít`.

## User decisions (27 Nov 14:18–14:21)
- Do (1) complete-syllable check at word end and (2) automatic English restore at word end.
- A word that is both a real English word and a real Vietnamese word: the language of the previous word
  in the same field decides (previous English → English; previous Vietnamese, or no previous word → Vietnamese).
- No exception file, no new setting, no undo of a restore (the user retypes). As little configuration as possible.
- Word lists from open sources with a license compatible with the repo's MIT license, sources recorded;
  nothing is downloaded at run time.
- Commit locally per task, no push; reinstall the daemon from the final reviewed commit when done.

## Definitions
- Word end: every point where ime-core ends a word (`Context::flush`): a boundary key (space, punctuation,
  Enter, Tab…), focus out, reset (click / cursor move), capability change, mode toggle, disable, destroy.
- Composed word: the composer is in Vietnamese mode and its text differs from its raw keys.
- English list: lowercase English words (from the system SCOWL-based `wamerican` list or another MIT-compatible source)
  whose Telex reading the engine changes. Vietnamese list: real (attested) Vietnamese syllables in lowercase NFC with tone.

## Acceptance criteria
- AC-1 Complete syllable: at word end, a composed word whose letters are only a prefix of a syllable
  (no valid complete nucleus/final; e.g. `úe`, `ủe`, `tưo`, `ă`, `â` without a final) is committed as its raw keys
  (`use`→`use`, `user`→`user`, `two`→`two`, `aw`→`aw`). Words with no vowel keep their text (`dd`→`đ`, `d`→`d`).
  Every complete syllable of the golden list is unchanged.
- AC-2 English restore: at word end, a composed word whose raw keys (case-folded) are in the English list and whose
  Vietnamese text (case-folded) is NOT in the Vietnamese list is committed as its raw keys, in the case typed
  (`her `→`her `, `Box`→`Box`).
- AC-3 Overlap: when the raw keys are in the English list AND the text is in the Vietnamese list, the previous word's
  language in the same context decides: English → raw keys; Vietnamese or unknown → Vietnamese text
  (`the best `→`the best `, `rất bét `→ stays `bét`, sentence-first `bét` stays).
- AC-4 Previous-word language, per context: set at each word end — English when the word was committed as raw keys
  (restore, complete-syllable fallback, passthrough/invalid word, undo-by-repeat word) or is an unchanged word in the
  English list and not in the Vietnamese list; Vietnamese when the committed text carries Vietnamese letters or marks,
  or is in the Vietnamese list and not in the English list; otherwise unchanged. Reset to unknown on focus in/out,
  reset, context creation, mode toggle and disable. Only the language value is kept, never text (SEC-2/SEC-4).
- AC-5 Every edit mode commits the decided text: preedit (commit replaces the preedit), surrounding text
  (delete what is shown, commit the result; nothing sent when identical), hold. The FR-8 address-bar order
  (hide, gap, commit) and FR-10/B3 never-drop rules still hold.
- AC-6 No configuration, no runtime file I/O, lists embedded at compile time; per-key work unchanged (lookups only at
  word end, sub-linear); binary grows by at most ~1.5 MB.
- AC-7 Measured result in the notes: of the 25 words above, how many come out English sentence-first and after an
  English word; of the Vietnamese golden list, 100 % unchanged with previous = unknown/Vietnamese for every syllable
  in the Vietnamese list; plus an English sample (≥ 2,000 common words) unchanged rate before/after.
- AC-8 Existing suites green (`cargo test --workspace --locked`, guard), e2e smoke on the daemon still lossless
  (expected outputs of English corpus lines updated only where AC-2/3 says so, listed).
- AC-9 Licenses: sources, versions and licenses in README (short) and a third-party notice file; GPL / CC-BY-SA lists are
  not used. If no permissive attested Vietnamese syllable list exists, the team authors one (only real syllables in
  common use; at least every Vietnamese form that an English-list word produces is decided) and says so (D-entry).

## Out of scope
Per-app defaults, field-purpose switching, learning from corrections, undo of a restore, any setting.
