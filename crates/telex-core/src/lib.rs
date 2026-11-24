//! Telex composition engine: turns the keys of one word into Vietnamese text.
//!
//! Pure and I/O free. Rules: spec §4, decisions D5 (standard Telex, modern tone
//! placement), D13 (tone placement details) and D18 (free-order `a`/`e`/`o`
//! circumflex and `d` → `đ`).
//!
//! The engine keeps the word as letters (lower case, with vowel marks, without
//! tone) plus one tone for the word. After every key the letters must still be
//! a valid Vietnamese syllable or a prefix of one; when they are not, the word
//! falls back to the raw keys and the rest of it passes through unchanged.
#![forbid(unsafe_code)]

use std::fmt;

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
            raw: String::new(),
            letters: Vec::new(),
            tone: Tone::None,
            mode: Mode::Viet,
            text: String::new(),
            tone_key_last: false,
        }
    }

    /// Feeds one key (`a`-`z`, `A`-`Z`). Any other character turns the word
    /// into passthrough and is appended as is. Returns the state of the word;
    /// the rendered word is [`Composer::text`].
    pub fn push(&mut self, ch: char) -> Outcome {
        self.raw.push(ch);
        self.tone_key_last = false;
        match self.mode {
            Mode::Raw => {
                self.text.push(ch);
                return Outcome::Invalid;
            }
            // More letters after an undo mean a foreign word (`session`, `array`).
            Mode::Undone if ch.is_ascii_alphabetic() => {
                self.restore_raw();
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
                let mut keys: Vec<char> = self.raw.chars().collect();
                keys.pop();
                self.replay(&keys);
                keys.fill('\0');
            }
            Mode::Viet => self.pop_letter(),
            Mode::Undone => {
                self.text.pop();
                self.raw.pop();
                let mut before = String::new();
                self.render_to(&mut before);
                if before == self.text {
                    if parse(&self.letters, self.tone).is_some() {
                        self.mode = Mode::Viet;
                        self.resync_raw();
                    } else {
                        // An undone mid-word `w` leaves letters no syllable
                        // fits (`twnw` → `twn`): the shown text is raw keys.
                        wipe_string(&mut self.raw);
                        self.raw.push_str(&self.text);
                        self.restore_raw();
                    }
                }
                wipe_string(&mut before);
            }
            Mode::Raw => {
                self.text.pop();
                self.raw.pop();
                // The shortened raw keys may form a syllable again (`acf` → `ac`);
                // take that state only when it shows the same text.
                let mut keys: Vec<char> = self.raw.chars().collect();
                let mut again = Composer::new();
                for &k in &keys {
                    again.push(k);
                }
                keys.fill('\0');
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
            let mut shown = String::new();
            self.render_to(&mut shown);
            self.raw.clear();
            self.raw.push_str(&shown);
            wipe_string(&mut shown);
            self.restore_raw();
            return;
        }
        self.resync_raw();
        self.render();
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

    /// Forgets the word, overwriting the buffers first (best effort, SEC-4).
    pub fn clear(&mut self) {
        wipe_string(&mut self.raw);
        wipe_string(&mut self.text);
        self.letters.fill(Letter::BLANK);
        self.letters.clear();
        self.tone = Tone::None;
        self.mode = Mode::Viet;
        self.tone_key_last = false;
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
            self.letters.fill(Letter::BLANK);
            self.letters.clear();
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
            // D18: a later `d` turns the initial `d` into `đ` (`dinhd` → đinh).
            ('d', _) if self.letters.len() > 1 => match self.letters[0].ch {
                'd' => {
                    let mut trial = self.letters.clone();
                    trial[0].ch = 'đ';
                    if self.try_letters(trial) {
                        return Step::Ok;
                    }
                }
                // Undo by repeat, only right after the key that made the `đ`.
                'đ' if self.prev_key_is(k) => {
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

    /// `aa` → â, `ee` → ê, `oo` → ô, also when other keys come between (D18:
    /// `vieset` → viết) as long as the result is a valid syllable; otherwise
    /// the key is a plain letter. Only an adjacent repeat undoes the hat.
    fn circumflex(&mut self, k: char, ch: char, s: Syllable) -> Step {
        let hat = match k {
            'a' => 'â',
            'e' => 'ê',
            _ => 'ô',
        };
        if let Some(i) = (s.ns..s.ne).rev().find(|&i| self.letters[i].ch == k) {
            let mut trial = self.letters.clone();
            trial[i].ch = hat;
            if self.try_letters(trial) {
                return Step::Ok;
            }
        }
        if !self.prev_key_is(k) {
            self.letters.push(Letter::new(k, ch.is_ascii_uppercase()));
            return self.validated();
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
        let nuc: Vec<char> = self.letters[s.ns..s.ne].iter().map(|l| l.ch).collect();
        let at = |i: usize| s.ns + i;

        // u + o → ươ (spec: `uow` and `uwow` both give ươ).
        if let Some(p) = nuc
            .windows(2)
            .position(|w| base(w[0]) == 'u' && base(w[1]) == 'o')
        {
            let mut trial = self.letters.clone();
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
            let mut trial = self.letters.clone();
            trial[at(i)].ch = to;
            if self.try_letters(trial) {
                return Step::Ok;
            }
        }

        // Undo: drop every w mark of the nucleus, then the key itself is literal.
        if nuc.iter().any(|&c| matches!(c, 'ă' | 'ơ' | 'ư')) {
            for i in (s.ns..s.ne).rev() {
                let l = &mut self.letters[i];
                match l.ch {
                    'ư' if l.w_alone => {
                        if i + 1 == end {
                            self.letters.remove(i);
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
            return Step::Literal(ch);
        }

        // A lone `w` is ư where a vowel can start (`tw`, `giw`).
        let mut trial = self.letters.clone();
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

    /// The key typed just before the current one (already in `raw`) was `k`.
    fn prev_key_is(&self, k: char) -> bool {
        self.raw
            .chars()
            .rev()
            .nth(1)
            .is_some_and(|p| p.to_ascii_lowercase() == k)
    }

    fn try_letters(&mut self, trial: Vec<Letter>) -> bool {
        if parse(&trial, self.tone).is_some() {
            self.letters = trial;
            true
        } else {
            false
        }
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
                let nuc: Vec<char> = self.letters[s.ns..s.ne].iter().map(|l| l.ch).collect();
                Some(s.ns + tone_index(&nuc, s.ne < self.letters.len()))
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

/// Overwrites a string's bytes before emptying it, keeping the allocation.
fn wipe_string(s: &mut String) {
    let mut bytes = std::mem::take(s).into_bytes();
    bytes.fill(0);
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

/// Validates letters as a Vietnamese syllable or a prefix of one.
fn parse(letters: &[Letter], tone: Tone) -> Option<Syllable> {
    let w: Vec<char> = letters.iter().map(|l| l.ch).collect();
    let n = w.len();
    let Some(fv) = w.iter().position(|&c| is_vowel(c)) else {
        let ok = w.iter().all(|c| c.is_ascii_lowercase() || *c == 'đ')
            && (w == ['q']
                || INITIALS
                    .iter()
                    .any(|i| i.starts_with(&String::from_iter(&w)[..])));
        return (ok && tone == Tone::None).then_some(Syllable { ns: n, ne: n });
    };
    let cons: String = w[..fv].iter().collect();
    let ns = match cons.as_str() {
        "q" if w[fv] == 'u' => fv + 1,
        "q" => return None,
        "g" if w[fv] == 'i' && w.get(fv + 1).is_some_and(|&c| is_vowel(c)) => fv + 1,
        c if INITIALS.contains(&c) => fv,
        _ => return None,
    };
    let ne = (ns..n).find(|&i| !is_vowel(w[i])).unwrap_or(n);
    let fin: String = w[ne..].iter().collect();
    if !FINALS.contains(&fin.as_str()) {
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
    let spelling_ok = match cons.as_str() {
        "k" | "gh" | "ngh" => front,
        "c" | "ng" => !front,
        "g" if ns == fv => !matches!(nuc[0], 'e' | 'ê'),
        _ => true,
    };
    let stop_final = matches!(fin.as_str(), "c" | "ch" | "p" | "t");
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
