//! Telex composition engine: turns the keys of one word into Vietnamese text.
//!
//! Pure and I/O free. Rules: spec §4, decisions D5 (standard Telex, modern tone
//! placement) and D13 (tone placement details).
//!
//! The engine keeps the word as letters (lower case, with vowel marks, without
//! tone) plus one tone for the word. After every key the letters must still be
//! a valid Vietnamese syllable or a prefix of one; when they are not, the word
//! falls back to the raw keys and the rest of it passes through unchanged.
#![forbid(unsafe_code)]

use std::fmt;

mod words;

/// State of the word after a key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// The word is being composed as Vietnamese.
    Composing,
    /// The word is passthrough now: either the raw keys (no Vietnamese
    /// syllable fits) or the text left by an undo-by-repeat. Further keys of
    /// this word are appended as typed.
    Invalid,
}

/// Language of a committed word, kept per input field to decide the next
/// word that is both English and Vietnamese (AC-3). Holds no text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Lang {
    #[default]
    Unknown,
    En,
    Vi,
}

/// What to commit at the end of a word, and the language it counts as.
/// Borrows the composer's own buffers. `Debug` hides the text (SEC-2).
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Finished<'a> {
    pub text: &'a str,
    pub lang: Lang,
}

impl fmt::Debug for Finished<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "Finished {{ <redacted len={}>, lang: {:?} }}",
            self.text.chars().count(),
            self.lang
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum Tone {
    #[default]
    None,
    Sac,
    Huyen,
    Hoi,
    Nga,
    Nang,
}

impl Tone {
    fn from_key(k: char) -> Option<Self> {
        match k {
            's' => Some(Self::Sac),
            'f' => Some(Self::Huyen),
            'r' => Some(Self::Hoi),
            'x' => Some(Self::Nga),
            'j' => Some(Self::Nang),
            _ => None,
        }
    }

    fn column(self) -> usize {
        self as usize
    }
}

#[derive(Clone, Copy)]
struct Letter {
    /// Lower case, with vowel marks, without tone.
    ch: char,
    upper: bool,
    /// An `ư` typed as a lone `w` (undo turns it back into `w`, not `u`).
    w_alone: bool,
}

impl Letter {
    const BLANK: Self = Self {
        ch: '\0',
        upper: false,
        w_alone: false,
    };

    fn new(ch: char, upper: bool) -> Self {
        Self {
            ch,
            upper,
            w_alone: false,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Viet,
    /// Right after an undo-by-repeat: the text ends with the literal key.
    Undone,
    /// The raw keys, as typed.
    Raw,
}

/// Result of applying one key in Vietnamese mode.
enum Step {
    Ok,
    /// Undo by repeat: render the word as it is now, then append this key literally.
    Literal(char),
    /// No syllable fits: restore the raw keys.
    Invalid,
}

/// Composes one word. Holds typed text, so its `Debug` output is redacted (SEC-2).
pub struct Composer {
    raw: String,
    letters: Vec<Letter>,
    tone: Tone,
    mode: Mode,
    text: String,
    /// The last key only changed the tone: BackSpace then takes the tone back
    /// instead of the last letter (`vieets` + BackSpace → viêt).
    tone_key_last: bool,
}

impl fmt::Debug for Composer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "Composer {{ <redacted len={}> }}",
            self.raw.chars().count()
        )
    }
}

impl Default for Composer {
    fn default() -> Self {
        Self::new()
    }
}

impl Composer {
    pub fn new() -> Self {
        Self {
            raw: String::with_capacity(WORD_BYTES),
            letters: Vec::with_capacity(WORD_KEYS),
            tone: Tone::None,
            mode: Mode::Viet,
            text: String::with_capacity(WORD_BYTES),
            tone_key_last: false,
        }
    }

    /// Feeds one key (`a`-`z`, `A`-`Z`). Any other character turns the word
    /// into passthrough and is appended as is. Returns the state of the word;
    /// the rendered word is [`Composer::text`]. The buffers are sized for a
    /// word of up to 32 keys (ime-core `MAX_WORD_KEYS`); past that they grow
    /// by reallocation and the old blocks are not wiped (SEC-4).
    pub fn push(&mut self, ch: char) -> Outcome {
        self.raw.push(ch);
        self.tone_key_last = false;
        match self.mode {
            Mode::Raw => {
                self.text.push(ch);
                return Outcome::Invalid;
            }
            // After an undo the next letter decides: a foreign word keeps the raw
            // keys (`session`, `array`, `offline`, `asss`); otherwise the word goes
            // on from the text shown (`lis` + `t` → `list`).
            Mode::Undone if ch.is_ascii_alphabetic() => {
                if self.keeps_raw_after_undo(ch) {
                    self.restore_raw();
                } else {
                    self.continue_shown(ch);
                }
                return Outcome::Invalid;
            }
            _ if !ch.is_ascii_alphabetic() => {
                self.text.push(ch);
                self.enter_passthrough(Mode::Undone);
                return Outcome::Invalid;
            }
            _ => {}
        }
        match self.apply(ch) {
            Step::Ok => {
                self.render();
                Outcome::Composing
            }
            Step::Literal(key) => {
                self.render();
                self.text.push(key);
                self.enter_passthrough(Mode::Undone);
                Outcome::Invalid
            }
            Step::Invalid => {
                self.restore_raw();
                Outcome::Invalid
            }
        }
    }

    /// BackSpace inside a word: removes the last character shown, so the word
    /// on screen loses exactly one character (`ass` → `as` → `a`, `tuw` → `tư`
    /// → `t`). One exception: when the last key only set or cleared the tone,
    /// BackSpace takes that tone back (`vieets` → `viết` → `viêt`).
    /// The composer then goes on from what is shown.
    pub fn pop(&mut self) -> Outcome {
        if self.raw.is_empty() {
            return Outcome::Composing;
        }
        match self.mode {
            Mode::Viet if self.tone_key_last => {
                let mut keys = self.typed_keys();
                keys.pop();
                self.replay(&keys);
                wipe_chars(&mut keys);
            }
            Mode::Viet => self.pop_letter(),
            Mode::Undone => {
                self.text.pop();
                self.raw.pop();
                let mut before = String::with_capacity(WORD_BYTES);
                self.render_to(&mut before);
                if before == self.text {
                    self.mode = Mode::Viet;
                    self.resync_raw();
                }
                wipe_string(&mut before);
            }
            Mode::Raw => {
                self.text.pop();
                self.raw.pop();
                // The shortened raw keys may form a syllable again (`acf` → `ac`);
                // take that state only when it shows the same text.
                let mut keys = self.typed_keys();
                let mut again = Composer::new();
                for &k in &keys {
                    again.push(k);
                }
                wipe_chars(&mut keys);
                if again.text == self.text {
                    std::mem::swap(self, &mut again);
                }
                again.clear();
            }
        }
        if self.text.is_empty() {
            self.clear();
        }
        self.outcome()
    }

    fn pop_letter(&mut self) {
        if let Some(l) = self.letters.last_mut() {
            *l = Letter::BLANK;
        }
        self.letters.pop();
        if parse(&self.letters, self.tone).is_none_or(|s| s.ns == s.ne) {
            self.tone = Tone::None;
        }
        if parse(&self.letters, self.tone).is_none() {
            // Not reachable for a valid prefix; keep the shown text exactly.
            let mut shown = String::with_capacity(WORD_BYTES);
            self.render_to(&mut shown);
            wipe_string(&mut self.raw);
            self.raw.push_str(&shown);
            wipe_string(&mut shown);
            self.restore_raw();
            return;
        }
        self.render();
        if !self.retype_without_last_key() {
            self.resync_raw();
        }
    }

    /// After a letter is taken back, keeps the keys the user typed for the
    /// letters still shown when the last key alone made that letter: the keys
    /// minus the last one must compose to exactly the text shown. The word end
    /// then restores and looks up those keys (`usern` + BackSpace → `user`),
    /// not the canonical ones of [`Composer::resync_raw`] (`uer`).
    fn retype_without_last_key(&mut self) -> bool {
        let mut keys = self.typed_keys();
        keys.pop();
        let mut again = Composer::new();
        for &k in &keys {
            again.push(k);
        }
        wipe_chars(&mut keys);
        let same = again.mode == Mode::Viet && again.text == self.text;
        if same {
            // BackSpace after this takes a letter, as it would have here.
            again.tone_key_last = false;
            std::mem::swap(self, &mut again);
        }
        again.clear();
        same
    }

    /// The keys as chars, in a buffer sized up front so it never reallocates
    /// (a reallocation would free a copy of the keys without wiping it).
    fn typed_keys(&self) -> Vec<char> {
        let mut keys = Vec::with_capacity(self.raw.len());
        keys.extend(self.raw.chars());
        keys
    }

    fn replay(&mut self, keys: &[char]) {
        self.clear();
        for &k in keys {
            self.push(k);
        }
    }

    /// Rewrites `raw` as Telex keys for the current letters and tone, so a
    /// later raw restore or tone BackSpace starts from what is shown.
    fn resync_raw(&mut self) {
        wipe_string(&mut self.raw);
        for l in &self.letters {
            let keys: &[char] = match l.ch {
                'â' => &['a', 'a'],
                'ă' => &['a', 'w'],
                'ê' => &['e', 'e'],
                'ô' => &['o', 'o'],
                'ơ' => &['o', 'w'],
                'ư' if l.w_alone => &['w'],
                'ư' => &['u', 'w'],
                'đ' => &['d', 'd'],
                _ => std::slice::from_ref(&l.ch),
            };
            for &k in keys {
                self.raw
                    .push(if l.upper { k.to_ascii_uppercase() } else { k });
            }
        }
        let tone_key = match self.tone {
            Tone::None => None,
            Tone::Sac => Some('s'),
            Tone::Huyen => Some('f'),
            Tone::Hoi => Some('r'),
            Tone::Nga => Some('x'),
            Tone::Nang => Some('j'),
        };
        if let Some(k) = tone_key {
            let upper = self.letters.last().is_some_and(|l| l.upper);
            self.raw
                .push(if upper { k.to_ascii_uppercase() } else { k });
        }
        self.tone_key_last = false;
    }

    fn outcome(&self) -> Outcome {
        if self.mode == Mode::Viet {
            Outcome::Composing
        } else {
            Outcome::Invalid
        }
    }

    /// The rendered word (Vietnamese, or the passthrough text), NFC.
    pub fn text(&self) -> &str {
        &self.text
    }

    /// The keys as typed.
    pub fn raw(&self) -> &str {
        &self.raw
    }

    pub fn is_empty(&self) -> bool {
        self.raw.is_empty()
    }

    /// What to commit at the end of the word, given the language of the
    /// previous word in the same field. Does not change the composer;
    /// [`Composer::text`] still returns what is shown. No allocation: the
    /// result borrows the shown text or the raw keys, and the word lists are
    /// searched only here.
    ///
    /// Vietnamese words (text differs from the keys):
    /// - no vowel (`dd` → đ): the text, [`Lang::Vi`];
    /// - not a complete syllable (`úe`, `tưo`, `ă`, `ươ`): the raw keys, [`Lang::En`];
    /// - keys in the English list and text not in the Vietnamese list: the raw keys, [`Lang::En`];
    /// - keys in the English list and text in the Vietnamese list: the raw keys
    ///   with [`Lang::En`] when `prev` is [`Lang::En`], else the text with [`Lang::Vi`];
    /// - otherwise the text, [`Lang::Vi`].
    ///
    /// Words whose text equals the keys commit unchanged. A common English word
    /// that is rare in Vietnamese (`the`, `with`: the plain English list) gives
    /// [`Lang::En`]; else a Vietnamese syllable that is not an English word
    /// (`cho`, `anh`) gives [`Lang::Vi`]; any other (`to`, `can`, `ngh`) keeps
    /// `prev`, since it says nothing about the language (D15). An all-caps word
    /// of two or more letters (`AI`, `VIP`) keeps `prev` too (D19). An empty
    /// word also keeps `prev`.
    ///
    /// Passthrough words (no syllable fits, or after an undo by repeat) commit
    /// the text shown: [`Lang::Vi`] when it has a Vietnamese letter (`viêts`),
    /// [`Lang::En`] when it has letters (`class`, `as` from `ass`), else `prev`.
    /// One exception (D14): a word that ends in a tone-key undo, shows only
    /// ASCII and whose keys are in the English list commits its keys with
    /// [`Lang::En`] when `prev` is [`Lang::En`] (`the pass`, not `the pas`).
    pub fn finish(&self, prev: Lang) -> Finished<'_> {
        let text = self.text.as_str();
        let raw = self.raw.as_str();
        let keep = |lang| Finished { text, lang };
        let restore = Finished {
            text: raw,
            lang: Lang::En,
        };
        if self.mode != Mode::Viet {
            if prev == Lang::En && self.ends_in_tone_undo() && words::is_english(raw) {
                return restore;
            }
            return keep(shown_lang(text, prev));
        }
        if text == raw {
            let lang = if raw.is_empty() {
                prev
            } else if words::is_plain_english(raw) {
                Lang::En
            } else if raw.len() >= 2 && raw.bytes().all(|b| b.is_ascii_uppercase()) {
                // An acronym (`AI`, `UI`, `VIP`) says nothing about the language (D19).
                prev
            } else if words::is_vietnamese(text) && !words::is_also_english(raw) {
                Lang::Vi
            } else {
                prev
            };
            return keep(lang);
        }
        let Some(s) = parse(&self.letters, self.tone) else {
            return restore;
        };
        if s.ns == self.letters.len() {
            return keep(Lang::Vi);
        }
        if !is_complete(&self.letters, s) {
            return restore;
        }
        if !words::is_english(raw) || (prev != Lang::En && words::is_vietnamese(text)) {
            return keep(Lang::Vi);
        }
        restore
    }

    /// The word stopped right after an undo by repeat of a tone key (`pass`,
    /// `less`) and shows only ASCII letters. In `Undone` the last key is the
    /// literal one; of the keys that can undo (tone keys, `a e o w d`), only
    /// tone keys are `s f r x j`.
    fn ends_in_tone_undo(&self) -> bool {
        self.mode == Mode::Undone
            && self.text.is_ascii()
            && self.raw.chars().last().is_some_and(|k| {
                matches!(k.to_ascii_lowercase(), 's' | 'f' | 'r' | 'x' | 'j')
                    && self.text.ends_with(k)
            })
    }

    /// Forgets the word, overwriting the buffers first (best effort, SEC-4).
    pub fn clear(&mut self) {
        wipe_string(&mut self.raw);
        wipe_string(&mut self.text);
        wipe_letters(&mut self.letters);
        self.tone = Tone::None;
        self.mode = Mode::Viet;
        self.tone_key_last = false;
    }

    /// `ch` is already in `raw`; the undone key is the one before it.
    fn keeps_raw_after_undo(&self, ch: char) -> bool {
        let mut keys = self.raw.chars().rev().skip(1);
        let undone = keys.next().map(|k| k.to_ascii_lowercase());
        let k = ch.to_ascii_lowercase();
        // A mark undo (`ww`, `aaa`, `ddd`) always goes on from the shown text.
        // Repeating the same key restores the raw keys (`www`, `aaaa`).
        if matches!(undone, Some('a' | 'e' | 'o' | 'd' | 'w')) {
            return Some(k) == undone;
        }
        // `l` / `r` form the clusters of `offline`, `offroad`.
        is_raw_vowel_key(ch) || matches!(k, 'l' | 'r') || Some(k) == undone
    }

    /// Passthrough from the text shown, so BackSpace works on what is on screen.
    fn continue_shown(&mut self, ch: char) {
        self.text.push(ch);
        wipe_string(&mut self.raw);
        self.raw.push_str(&self.text);
        self.enter_passthrough(Mode::Raw);
    }

    fn restore_raw(&mut self) {
        wipe_string(&mut self.text);
        self.text.push_str(&self.raw);
        self.enter_passthrough(Mode::Raw);
    }

    /// `Undone` keeps the letters: they render the text before the literal
    /// key, which BackSpace returns to.
    fn enter_passthrough(&mut self, mode: Mode) {
        self.mode = mode;
        if mode == Mode::Raw {
            wipe_letters(&mut self.letters);
            self.tone = Tone::None;
        }
    }

    fn apply(&mut self, ch: char) -> Step {
        let k = ch.to_ascii_lowercase();
        let upper = ch.is_ascii_uppercase();
        let syl = parse(&self.letters, self.tone);
        let has_nucleus = syl.is_some_and(|s| s.ns < s.ne);

        if has_nucleus {
            if let Some(t) = Tone::from_key(k) {
                if self.tone == t {
                    self.tone = Tone::None;
                    return Step::Literal(ch);
                }
                self.tone = t;
                self.tone_key_last = true;
                return self.validated();
            }
            if k == 'z' && self.tone != Tone::None {
                self.tone = Tone::None;
                self.tone_key_last = true;
                return self.validated();
            }
        }

        match (k, syl) {
            ('a' | 'e' | 'o', Some(s)) if has_nucleus => return self.circumflex(k, ch, s),
            ('w', Some(s)) => return self.horn(ch, s),
            ('d', _) if self.letters.len() == 1 => match self.letters[0].ch {
                'd' => {
                    self.letters[0].ch = 'đ';
                    return self.validated();
                }
                'đ' => {
                    self.letters[0].ch = 'd';
                    return Step::Literal(ch);
                }
                _ => {}
            },
            _ => {}
        }

        self.letters.push(Letter::new(k, upper));
        self.validated()
    }

    /// `aa` → â, `ee` → ê, `oo` → ô; a repeat undoes it. The two keys must be
    /// adjacent, otherwise foreign words such as `reset` or `photo` would turn
    /// into valid syllables.
    fn circumflex(&mut self, k: char, ch: char, s: Syllable) -> Step {
        let hat = match k {
            'a' => 'â',
            'e' => 'ê',
            _ => 'ô',
        };
        let doubled = self
            .raw
            .chars()
            .rev()
            .nth(1)
            .is_some_and(|p| p.to_ascii_lowercase() == k);
        if !doubled {
            self.letters.push(Letter::new(k, ch.is_ascii_uppercase()));
            return self.validated();
        }
        if let Some(i) = (s.ns..s.ne).rev().find(|&i| self.letters[i].ch == k) {
            let mut trial = self.trial_letters();
            trial[i].ch = hat;
            if self.try_letters(trial) {
                return Step::Ok;
            }
        }
        if let Some(i) = (s.ns..s.ne).rev().find(|&i| self.letters[i].ch == hat) {
            self.letters[i].ch = k;
            return Step::Literal(ch);
        }
        self.letters.push(Letter::new(k, ch.is_ascii_uppercase()));
        self.validated()
    }

    /// `w`: ươ / ă / ơ / ư on the nucleus, else a lone ư; a repeat undoes it.
    fn horn(&mut self, ch: char, s: Syllable) -> Step {
        let upper = ch.is_ascii_uppercase();
        let end = self.letters.len();
        let mut buf = CharBuf::new(&self.letters[s.ns..s.ne]);
        let step = self.horn_on(ch, upper, end, s, buf.chars());
        buf.wipe();
        step
    }

    fn horn_on(&mut self, ch: char, upper: bool, end: usize, s: Syllable, nuc: &[char]) -> Step {
        let at = |i: usize| s.ns + i;

        // u + o → ươ (spec: `uow` and `uwow` both give ươ).
        if let Some(p) = nuc
            .windows(2)
            .position(|w| base(w[0]) == 'u' && base(w[1]) == 'o')
        {
            let mut trial = self.trial_letters();
            trial[at(p)].ch = 'ư';
            trial[at(p + 1)].ch = 'ơ';
            let changed = trial[at(p)].ch != self.letters[at(p)].ch
                || trial[at(p + 1)].ch != self.letters[at(p + 1)].ch;
            if changed && self.try_letters(trial) {
                return Step::Ok;
            }
        }
        let candidates = [
            nuc.iter().rposition(|&c| c == 'a').map(|i| (i, 'ă')),
            nuc.iter().rposition(|&c| c == 'o').map(|i| (i, 'ơ')),
            nuc.iter()
                .position(|&c| c == 'u')
                .filter(|&i| !nuc.get(i + 1).is_some_and(|&n| base(n) == 'o'))
                .map(|i| (i, 'ư')),
        ];
        for (i, to) in candidates.into_iter().flatten() {
            let mut trial = self.trial_letters();
            trial[at(i)].ch = to;
            if self.try_letters(trial) {
                return Step::Ok;
            }
        }

        // Undo: drop every w mark of the nucleus, then the key itself is literal.
        if nuc.iter().any(|&c| matches!(c, 'ă' | 'ơ' | 'ư')) {
            let mut literal = ch;
            for i in (s.ns..s.ne).rev() {
                let l = &mut self.letters[i];
                match l.ch {
                    'ư' if l.w_alone => {
                        if i + 1 == end {
                            // The shown `w` keeps the case of the key it came from.
                            if l.upper {
                                literal = ch.to_ascii_uppercase();
                            }
                            // Rotate the dropped letter to the end and blank it, so no copy
                            // stays past the end of the vector.
                            self.letters[i..].rotate_left(1);
                            if let Some(l) = self.letters.last_mut() {
                                *l = Letter::BLANK;
                            }
                            self.letters.pop();
                        } else {
                            l.ch = 'w';
                        }
                    }
                    'ă' => l.ch = 'a',
                    'ơ' => l.ch = 'o',
                    'ư' => l.ch = 'u',
                    _ => {}
                }
            }
            return Step::Literal(literal);
        }

        // A lone `w` is ư where a vowel can start (`tw`, `giw`).
        let mut trial = self.trial_letters();
        trial.push(Letter {
            ch: 'ư',
            upper,
            w_alone: true,
        });
        if self.try_letters(trial) {
            return Step::Ok;
        }
        self.letters.push(Letter::new('w', upper));
        self.validated()
    }

    /// A copy of the letters to try a change on, with room for one more
    /// letter, so pushing to it never reallocates and frees an unwiped copy.
    fn trial_letters(&self) -> Vec<Letter> {
        let mut trial = Vec::with_capacity(WORD_KEYS.max(self.letters.len() + 1));
        trial.extend_from_slice(&self.letters);
        trial
    }

    /// Takes `trial` when it is valid, copied into the composer's own buffer
    /// so that buffer keeps its capacity; `trial` is wiped either way.
    fn try_letters(&mut self, mut trial: Vec<Letter>) -> bool {
        let ok = parse(&trial, self.tone).is_some();
        if ok {
            wipe_letters(&mut self.letters);
            self.letters.extend_from_slice(&trial);
        }
        wipe_letters(&mut trial);
        ok
    }

    fn validated(&mut self) -> Step {
        if parse(&self.letters, self.tone).is_some() {
            Step::Ok
        } else {
            Step::Invalid
        }
    }

    fn render(&mut self) {
        let mut text = std::mem::take(&mut self.text);
        wipe_string(&mut text);
        self.render_to(&mut text);
        self.text = text;
    }

    fn render_to(&self, out: &mut String) {
        let mark = match parse(&self.letters, self.tone) {
            Some(s) if self.tone != Tone::None && s.ns < s.ne => {
                let mut nuc = CharBuf::new(&self.letters[s.ns..s.ne]);
                let i = tone_index(nuc.chars(), s.ne < self.letters.len());
                nuc.wipe();
                Some(s.ns + i)
            }
            _ => None,
        };
        for (i, l) in self.letters.iter().enumerate() {
            let ch = if mark == Some(i) {
                with_tone(l.ch, self.tone)
            } else {
                l.ch
            };
            if l.upper {
                out.extend(ch.to_uppercase());
            } else {
                out.push(ch);
            }
        }
    }
}

/// Room for one word without reallocating: ime-core ends a word at
/// `MAX_WORD_KEYS` (32) keys; a shown character takes at most 4 bytes.
const WORD_KEYS: usize = 32;
const WORD_BYTES: usize = WORD_KEYS * 4;

/// Overwrites the letters before emptying the vector, keeping the allocation.
/// `black_box` keeps the stores although the memory is not read again.
fn wipe_letters(v: &mut Vec<Letter>) {
    v.fill(Letter::BLANK);
    std::hint::black_box(&mut *v);
    v.clear();
}

/// Overwrites a copy of the keys before it is dropped.
fn wipe_chars(v: &mut Vec<char>) {
    v.fill('\0');
    std::hint::black_box(&mut *v);
}

/// Overwrites a string's bytes before emptying it, keeping the allocation.
fn wipe_string(s: &mut String) {
    let mut bytes = std::mem::take(s).into_bytes();
    bytes.fill(0);
    std::hint::black_box(&mut bytes);
    bytes.clear();
    *s = String::from_utf8(bytes).unwrap_or_default();
}

/// Nucleus span of a valid syllable (or syllable prefix): letters `ns..ne`.
#[derive(Clone, Copy)]
struct Syllable {
    ns: usize,
    ne: usize,
}

const INITIALS: [&str; 26] = [
    "", "b", "c", "ch", "d", "đ", "g", "gh", "h", "k", "kh", "l", "m", "n", "ng", "ngh", "nh", "p",
    "ph", "r", "s", "t", "th", "tr", "v", "x",
];

const FINALS: [&str; 9] = ["", "c", "ch", "m", "n", "ng", "nh", "p", "t"];

/// Nuclei that end a syllable without a final consonant.
const OPEN: [&str; 42] = [
    "a", "e", "ê", "i", "o", "ô", "ơ", "u", "ư", "y", "ai", "ao", "au", "âu", "ay", "ây", "eo",
    "êu", "ia", "iu", "oa", "oe", "oi", "ôi", "ơi", "ua", "uê", "ui", "uơ", "uy", "ưa", "ưi", "ưu",
    "iêu", "yêu", "oai", "oao", "oay", "oeo", "uây", "uôi", "ươi",
];

const OPEN_LONG: [&str; 3] = ["ươu", "uya", "uyu"];

/// Nuclei that take a final consonant.
const CLOSED: [&str; 24] = [
    "a", "ă", "â", "e", "ê", "i", "o", "ô", "ơ", "u", "ư", "y", "oa", "oă", "oe", "oo", "uâ", "uê",
    "uô", "uy", "ươ", "iê", "yê", "uyê",
];

fn is_vowel(c: char) -> bool {
    matches!(
        c,
        'a' | 'ă' | 'â' | 'e' | 'ê' | 'i' | 'o' | 'ô' | 'ơ' | 'u' | 'ư' | 'y'
    )
}

fn is_marked(c: char) -> bool {
    matches!(c, 'ă' | 'â' | 'ê' | 'ô' | 'ơ' | 'ư')
}

fn base(c: char) -> char {
    match c {
        'ă' | 'â' => 'a',
        'ê' => 'e',
        'ô' | 'ơ' => 'o',
        'ư' => 'u',
        other => other,
    }
}

/// A typed nucleus letter fits a pattern letter if equal, or if it is still
/// unmarked and a later key can add the pattern's mark (`uo` before `w`).
fn fits(typed: &[char], pattern: &str) -> bool {
    let mut p = pattern.chars();
    typed.iter().all(|&t| {
        p.next()
            .is_some_and(|pc| t == pc || (!is_marked(t) && base(pc) == t))
    })
}

fn nucleus_ok(nuc: &[char], has_final: bool) -> bool {
    if has_final {
        CLOSED
            .iter()
            .any(|p| p.chars().count() == nuc.len() && fits(nuc, p))
    } else {
        OPEN.iter()
            .chain(OPEN_LONG.iter())
            .chain(CLOSED.iter())
            .any(|p| fits(nuc, p))
    }
}

/// The letters (already a valid prefix, nucleus `s`) form a whole syllable:
/// the nucleus is one that can end the word as it stands, without a final
/// (OPEN) or before the final typed (CLOSED). Exact match, so a nucleus still
/// waiting for a mark (`ue` → uê, `uo` → ươ) or for a final (`ă`, `â`, `ươ`)
/// is not complete.
fn is_complete(letters: &[Letter], s: Syllable) -> bool {
    if s.ns >= s.ne {
        return false;
    }
    let nuc = || letters[s.ns..s.ne].iter().map(|l| l.ch);
    let exact = |p: &&str| p.chars().eq(nuc());
    if s.ne < letters.len() {
        CLOSED.iter().any(exact)
    } else {
        OPEN.iter().chain(OPEN_LONG.iter()).any(exact)
    }
}

/// Language of a passthrough word from the text it shows.
fn shown_lang(text: &str, prev: Lang) -> Lang {
    if text.chars().any(|c| !c.is_ascii() && c.is_alphabetic()) {
        Lang::Vi
    } else if text.chars().any(|c| c.is_ascii_alphabetic()) {
        Lang::En
    } else {
        prev
    }
}

/// Longest run of letters [`parse`] looks at. A valid syllable has at most 8
/// letters (`nghiêng` + one being tried); anything longer is not one.
const MAX_LETTERS: usize = 16;

/// The plain characters of some letters on the stack, so checking a word
/// makes no heap copy of what was typed (SEC-4). Wiped by [`CharBuf::wipe`].
struct CharBuf {
    buf: [char; MAX_LETTERS],
    len: usize,
}

impl CharBuf {
    /// Takes at most [`MAX_LETTERS`] letters.
    fn new(letters: &[Letter]) -> Self {
        let mut buf = ['\0'; MAX_LETTERS];
        let len = letters.len().min(MAX_LETTERS);
        for (b, l) in buf.iter_mut().zip(letters) {
            *b = l.ch;
        }
        Self { buf, len }
    }

    fn chars(&self) -> &[char] {
        &self.buf[..self.len]
    }

    fn wipe(&mut self) {
        self.buf.fill('\0');
        std::hint::black_box(&mut self.buf);
    }
}

/// `chars` spells `s`.
fn spells(chars: &[char], s: &str) -> bool {
    s.chars().eq(chars.iter().copied())
}

/// Validates letters as a Vietnamese syllable or a prefix of one.
fn parse(letters: &[Letter], tone: Tone) -> Option<Syllable> {
    if letters.len() > MAX_LETTERS {
        return None;
    }
    let mut w = CharBuf::new(letters);
    let res = parse_chars(w.chars(), tone);
    w.wipe();
    res
}

fn parse_chars(w: &[char], tone: Tone) -> Option<Syllable> {
    let n = w.len();
    let Some(fv) = w.iter().position(|&c| is_vowel(c)) else {
        let ok = w.iter().all(|c| c.is_ascii_lowercase() || *c == 'đ')
            && (w == ['q']
                || INITIALS.iter().any(|i| {
                    let mut ic = i.chars();
                    w.iter().all(|&c| ic.next() == Some(c))
                }));
        return (ok && tone == Tone::None).then_some(Syllable { ns: n, ne: n });
    };
    let cons = &w[..fv];
    let ns = if spells(cons, "q") {
        if w[fv] != 'u' {
            return None;
        }
        fv + 1
    } else if spells(cons, "g") && w[fv] == 'i' && w.get(fv + 1).is_some_and(|&c| is_vowel(c)) {
        fv + 1
    } else if INITIALS.iter().any(|i| spells(cons, i)) {
        fv
    } else {
        return None;
    };
    let ne = (ns..n).find(|&i| !is_vowel(w[i])).unwrap_or(n);
    let fin = &w[ne..];
    if !FINALS.iter().any(|f| spells(fin, f)) {
        return None;
    }
    let nuc = &w[ns..ne];
    if nuc.is_empty() {
        // Only `qu` (or `gi`) waiting for its vowel.
        return (fin.is_empty() && tone == Tone::None).then_some(Syllable { ns, ne });
    }
    if !nucleus_ok(nuc, !fin.is_empty()) {
        return None;
    }
    let front = matches!(nuc[0], 'i' | 'y' | 'e' | 'ê');
    let spelling_ok = if ["k", "gh", "ngh"].iter().any(|c| spells(cons, c)) {
        front
    } else if spells(cons, "c") || spells(cons, "ng") {
        !front
    } else if spells(cons, "g") && ns == fv {
        !matches!(nuc[0], 'e' | 'ê')
    } else {
        true
    };
    let stop_final = ["c", "ch", "p", "t"].iter().any(|f| spells(fin, f));
    let tone_ok = !stop_final || matches!(tone, Tone::None | Tone::Sac | Tone::Nang);
    (spelling_ok && tone_ok).then_some(Syllable { ns, ne })
}

/// Modern tone placement (D13), index inside the nucleus.
fn tone_index(nuc: &[char], has_final: bool) -> usize {
    match nuc.len() {
        0 | 1 => 0,
        _ if nuc.iter().any(|&c| is_marked(c)) => {
            nuc.iter().rposition(|&c| is_marked(c)).unwrap_or(0)
        }
        n if n >= 3 => 1,
        _ if has_final => 1,
        _ if matches!(nuc, ['o', 'a'] | ['o', 'e'] | ['u', 'y']) => 1,
        _ => 0,
    }
}

const TONED: [(char, [char; 6]); 12] = [
    ('a', ['a', 'á', 'à', 'ả', 'ã', 'ạ']),
    ('ă', ['ă', 'ắ', 'ằ', 'ẳ', 'ẵ', 'ặ']),
    ('â', ['â', 'ấ', 'ầ', 'ẩ', 'ẫ', 'ậ']),
    ('e', ['e', 'é', 'è', 'ẻ', 'ẽ', 'ẹ']),
    ('ê', ['ê', 'ế', 'ề', 'ể', 'ễ', 'ệ']),
    ('i', ['i', 'í', 'ì', 'ỉ', 'ĩ', 'ị']),
    ('o', ['o', 'ó', 'ò', 'ỏ', 'õ', 'ọ']),
    ('ô', ['ô', 'ố', 'ồ', 'ổ', 'ỗ', 'ộ']),
    ('ơ', ['ơ', 'ớ', 'ờ', 'ở', 'ỡ', 'ợ']),
    ('u', ['u', 'ú', 'ù', 'ủ', 'ũ', 'ụ']),
    ('ư', ['ư', 'ứ', 'ừ', 'ử', 'ữ', 'ự']),
    ('y', ['y', 'ý', 'ỳ', 'ỷ', 'ỹ', 'ỵ']),
];

fn with_tone(c: char, tone: Tone) -> char {
    TONED
        .iter()
        .find(|(v, _)| *v == c)
        .map_or(c, |(_, forms)| forms[tone.column()])
}

/// Keys that start or extend a vowel (`w` is the horn key).
fn is_raw_vowel_key(ch: char) -> bool {
    matches!(
        ch.to_ascii_lowercase(),
        'a' | 'e' | 'i' | 'o' | 'u' | 'y' | 'w'
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Buffers sized for a whole word: typing up to 32 keys, BackSpace and the
    /// BackSpace replay never move them, so no freed copy of the word is left
    /// behind (SEC-4).
    /// Trial copies leave room for the letter a trial may add, at every size a
    /// word reaches, and every trial site takes its copy from `trial_letters`.
    #[test]
    fn trial_letters_never_reallocate() {
        let mut c = Composer::new();
        for ch in "nghieeng".chars() {
            c.push(ch);
            let trial = c.trial_letters();
            assert!(trial.capacity() > trial.len(), "no room after {ch}");
        }
        let mut c = Composer::new();
        c.letters.extend((0..40).map(|_| Letter::new('b', false)));
        let trial = c.trial_letters();
        assert!(trial.capacity() > trial.len());
        let exact_clone = concat!("letters", ".clone()");
        assert!(
            !include_str!("lib.rs").contains(exact_clone),
            "a trial site clones the letters with exact capacity"
        );
    }

    #[test]
    fn word_buffers_never_reallocate() {
        for keys in [
            "nguwowif",
            "nghieeengs",
            "usern",
            "vieetj",
            "tuow",
            "passport",
            "abcdefghijklmnopqrstuvwxyzabcdef",
            "đđđđđđđđđđđđđđđđđđđđđđđđđđđđđđđđ",
        ] {
            let mut c = Composer::new();
            for (n, ch) in keys.chars().enumerate() {
                c.push(ch);
                if n % 3 == 2 {
                    c.pop();
                    c.push(ch);
                }
                // A replay swaps in a fresh composer of the same size; it must
                // not have grown either.
                assert!(c.raw.capacity() == WORD_BYTES, "{keys}: raw grew");
                assert!(c.text.capacity() == WORD_BYTES, "{keys}: text grew");
                assert!(c.letters.capacity() == WORD_KEYS, "{keys}: letters grew");
            }
        }
    }
}
