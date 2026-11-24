#!/usr/bin/env python3
"""Generate crates/telex-core/tests/golden/telex_golden.tsv.

Independent of the engine and of any dictionary: the Vietnamese syllable set
is built from rules (initials x nuclei x finals x tones with the standard
spelling and tone restrictions); tone placement follows D13 (modern); the
word -> Telex keys reverse function is written here from the spec only.

Usage: python3 -I tools/golden-gen/gen.py [--out PATH]
Standard library only, no network.
"""
import os
import sys
import unicodedata
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_OUT = os.path.join(ROOT, "crates/telex-core/tests/golden/telex_golden.tsv")

TONE_KEYS = {"s": "́", "f": "̀", "r": "̉", "x": "̃", "j": "̣"}
DIACRITIC = set("ăâêôơư")
LETTER_KEYS = {"â": "aa", "ă": "aw", "ê": "ee", "ô": "oo", "ơ": "ow", "ư": "uw", "đ": "dd"}

# Letters used by the English-word oracle (loose on purpose: it must reject
# every word a Telex reading could turn into a valid syllable).
INITIALS = {"", "b", "c", "ch", "d", "đ", "g", "gh", "h", "k", "kh", "l", "m", "n",
            "ng", "ngh", "nh", "ph", "q", "r", "s", "t", "th", "tr", "v", "x"}
FINALS = {"", "c", "ch", "m", "n", "ng", "nh", "p", "t"}

A_FIN = ["", "c", "ch", "m", "n", "ng", "nh", "p", "t"]
PLAIN_FIN = ["", "c", "m", "n", "ng", "p", "t"]
# Finals allowed after each nucleus. Open-only nuclei have [""].
NUCLEUS_FINALS = {
    "a": A_FIN, "ă": ["c", "m", "n", "ng", "p", "t"], "â": ["c", "m", "n", "ng", "p", "t"],
    "e": PLAIN_FIN, "ê": ["", "ch", "m", "n", "nh", "p", "t"], "i": ["", "ch", "m", "n", "nh", "p", "t"],
    "o": PLAIN_FIN, "ô": PLAIN_FIN, "ơ": ["", "m", "n", "p", "t"], "u": PLAIN_FIN,
    "ư": ["", "c", "ng", "t"], "y": [""],
    "iê": ["c", "m", "n", "ng", "p", "t"], "uô": ["c", "m", "n", "ng", "t"],
    "ươ": ["c", "m", "n", "ng", "p", "t"],
    "oa": ["", "c", "ch", "n", "ng", "nh", "t"], "oă": ["c", "n", "ng", "t"],
    "oe": ["", "n", "t"], "uâ": ["n", "ng", "t"], "uê": ["", "ch", "nh"],
    "uy": ["", "ch", "nh", "t"], "uyê": ["n", "t"],
}
for _n in ("ai ao au ay âu ây eo êu ia iu oi ôi ơi ua ui ưa ưi ưu oai oay oeo iêu uây uôi "
           "ươi ươu uyu uya").split():
    NUCLEUS_FINALS[_n] = [""]
NUCLEI = set(NUCLEUS_FINALS) | {"yê", "yêu"}

PLAIN_INITIALS = ["", "b", "ch", "d", "đ", "h", "kh", "l", "m", "n", "nh", "ph", "r", "s", "t",
                  "th", "tr", "v", "x"]
BACK = {"a", "ă", "â", "o", "ô", "ơ", "u", "ư", "ai", "ao", "au", "ay", "âu", "ây", "oi", "ôi",
        "ơi", "ui", "ua", "ưa", "ưu", "uô", "ươ", "ươi", "ươu", "uôi"}
BACK_WIDE = {"oa", "oă", "oe", "oai", "oay", "oeo", "uy", "uâ", "uê", "uây", "uyê", "uyu", "uya"}
G_OK = {"a", "ă", "â", "o", "ô", "ơ", "u", "ư", "ai", "ao", "au", "ay", "âu", "ây", "oi", "ôi",
        "ơi", "ui", "ưa", "uô", "ươ"}
K_OK = {"e", "ê", "i", "y", "ia", "iê", "iêu", "eo", "êu"}
GH_OK = {"e", "ê", "i", "iê", "eo"}
# Initial-specific nucleus -> finals (the u of qu and the i of gi belong to the initial, D13).
QU = {"a": A_FIN, "ă": ["c", "n", "ng", "p", "t"], "â": ["n", "ng", "t"], "e": ["", "n", "t"],
      "ê": ["", "ch", "n"], "y": ["", "nh", "t"], "ơ": [""], "ô": ["c"], "ai": [""], "ay": [""],
      "ao": [""], "ây": [""], "eo": [""], "yê": ["n", "t"]}
GI = {"a": A_FIN, "ă": ["c", "n", "ng", "t"], "â": ["c", "m", "n", "t"], "ê": ["ng", "t"],
      "ư": [""], "u": ["", "c"], "o": ["", "n"], "ơ": ["", "n"], "ơi": [""], "ai": [""],
      "ao": [""], "au": [""], "ay": [""], "âu": [""], "ây": [""], "eo": [""], "êu": [""],
      "ưa": [""], "ươ": ["ng"]}
G_BARE_I = ["", "n"]  # gì, gìn: i is the only vowel, so it is the nucleus


def nfc(s):
    return unicodedata.normalize("NFC", s)


def tone_index(nuc):
    """D13 (modern) tone placement: index into nuc."""
    if len(nuc) == 1:
        return 0
    dia = [i for i, c in enumerate(nuc) if c in DIACRITIC]
    if dia:
        return dia[-1]
    if len(nuc) == 3:
        return 1
    if nuc in ("oa", "oe", "uy"):
        return 1
    return 0


def put_tone(nuc, idx, tone):
    if not tone:
        return nuc
    return nuc[:idx] + nfc(nuc[idx] + TONE_KEYS[tone]) + nuc[idx + 1:]


def keys_of(s):
    return "".join(LETTER_KEYS.get(c, c) for c in s)


def nucleus_keys(nuc, alt=False):
    if nuc.startswith("ươ"):
        return ("uwow" if alt else "uow") + keys_of(nuc[2:])
    return keys_of(nuc)


class Syl:
    def __init__(self, init, nuc, fin, tone):
        self.init, self.nuc, self.fin, self.tone = init, nuc, fin, tone
        self.text = nfc(init + put_tone(nuc, tone_index(nuc), tone) + fin)
        self.plain = nfc(init + nuc + fin)

    def keys(self, mid=False, alt=False):
        k = keys_of(self.init) + nucleus_keys(self.nuc, alt)
        if mid:
            return k + self.tone + keys_of(self.fin)
        return k + keys_of(self.fin) + self.tone


def spelled(init, nuc):
    """Written form: iê/iêu are spelled yê/yêu without a consonant initial or after qu."""
    if init in ("", "qu") and nuc in ("iê", "iêu"):
        return "y" + nuc[1:]
    return nuc


def base_syllables():
    """Yield (initial, nucleus, final) triples from the spelling rules."""
    out = []
    for init in PLAIN_INITIALS:
        for nuc, fins in NUCLEUS_FINALS.items():
            for fin in fins:
                out.append((init, spelled(init, nuc), fin))
    for init, allowed in (("c", BACK), ("g", G_OK), ("ng", BACK | BACK_WIDE),
                          ("k", K_OK), ("gh", GH_OK), ("ngh", GH_OK)):
        for nuc in sorted(allowed):
            for fin in NUCLEUS_FINALS[nuc]:
                out.append((init, nuc, fin))
    for fin in G_BARE_I:
        out.append(("g", "i", fin))
    for init, table in (("qu", QU), ("gi", GI)):
        for nuc, fins in table.items():
            for fin in fins:
                out.append((init, nuc, fin))
    return sorted(set(out))


def build_syllables():
    syls = []
    for init, nuc, fin in base_syllables():
        tones = ["", "s", "j"] if fin in ("c", "ch", "p", "t") else ["", "s", "f", "r", "x", "j"]
        for t in tones:
            syls.append(Syl(init, nuc, fin, t))
    return sorted(syls, key=lambda s: (s.plain, s.tone))


def h(s):
    return zlib.crc32(s.encode("utf-8"))


def cap(s):
    return s[:1].upper() + s[1:]


HAT_BASE = {"â": "a", "ê": "e", "ô": "o"}


def late_hat_cases(syls):
    """D18: circumflex key typed late, on the matching earlier vowel.

    Three placements: after the final (`vietej`), tone key then hat key (`tiengse`),
    hat key between the tone and the final (`vieset`).
    """
    out = {"final": [], "tone_first": [], "after_tone": []}
    for s in syls:
        hats = [c for c in s.nuc if c in HAT_BASE]
        if len(hats) != 1:
            continue
        head = keys_of(s.init) + "".join(HAT_BASE.get(c) or LETTER_KEYS.get(c, c) for c in s.nuc)
        fin, hat = keys_of(s.fin), HAT_BASE[hats[0]]
        # No final and the hat vowel last in the nucleus: the key would sit next to its vowel,
        # which is the ordinary doubled key, not a free-order case.
        if fin or s.nuc[-1] not in HAT_BASE:
            out["final"].append((head + fin + hat + s.tone, s))
        if s.tone:
            out["tone_first"].append((head + fin + s.tone + hat, s))
            if fin:
                out["after_tone"].append((head + s.tone + hat + fin, s))
    return out


def late_d_cases(syls):
    """D18: a later d turns the initial d into đ (initial đ only)."""
    out = {"final": [], "tone_first": []}
    for s in syls:
        if s.init != "đ":
            continue
        rest = nucleus_keys(s.nuc) + keys_of(s.fin)
        out["final"].append(("d" + rest + "d" + s.tone, s))
        if s.tone:
            out["tone_first"].append(("d" + rest + s.tone + "d", s))
    return out


ENGLISH = """class https http git windows release linux ubuntu gnome github gitlab docker kubernetes
python rust cargo npm node react vue angular typescript javascript json yaml toml html css sql
bash shell terminal commit branch merge rebase push pull clone fetch stash checkout diff patch
server client request response header cookie token session cache proxy socket thread async await
function struct enum trait impl public private static const let var return import export default
string number boolean array object map set list queue stack tree graph vector buffer stream
test debug build deploy install update upgrade config settings profile account password login logout
email google chrome firefox safari android iphone macbook office excel word powerpoint outlook
facebook twitter youtube instagram netflix spotify discord slack zoom telegram whatsapp
computer keyboard monitor mouse laptop desktop printer router wifi bluetooth browser website domain
database table column index query select insert delete drop create alter schema
hello world please thanks sorry yes good morning night people time year week month today
black white green yellow orange purple brown pink grey silver golden
three four five eight nine twelve twenty thirty forty fifty hundred thousand million
school teacher student friend family mother father brother sister
water light music movie photo video audio image picture
bluetooth wireless network internet online offline download upload
project package module library framework plugin extension widget component template
error warning notice info trace panic crash freeze timeout
button click scroll drag drop hover focus blur submit reset
north south east west right left front back
apple banana grape lemon mango peach cherry melon
chrome edge opera brave
street market restaurant hotel airport station
tiger lion horse monkey rabbit
blog forum thread comment reply
sprint backlog kanban agile scrum
google drive gmail maps
shift ctrl alt tab enter escape space
screen window display pixel frame
black block clock flock stock track brick
spring summer winter autumn
hotkey shortcut keymap layout
python3 gcc clang make cmake ninja
tcp udp dns ssh ssl tls vpn
cpu gpu ram ssd usb hdmi
sudo chmod chown grep sed awk curl wget
vim emacs nano
wasm webpack vite
std str vec box rc arc mutex
""".split()

BASE_NUCLEI = {unicodedata.normalize("NFD", n).encode("ascii", "ignore").decode() for n in NUCLEI} | {"u"}


def skeleton_valid(sk):
    for cut in range(0, 3):
        init = sk[:cut]
        rest = sk[cut:]
        if not (init in INITIALS or init in ("qu", "gi")) or not rest:
            continue
        j = 0
        while j < len(rest) and rest[j] in "aeiouy":
            j += 1
        nuc, fin = rest[:j], rest[j:]
        if nuc and fin in FINALS and nuc in BASE_NUCLEI:
            return True
    return False


def english_safe(word):
    """True when no Telex reading of the word can be a valid Vietnamese syllable."""
    keyish = [i for i, c in enumerate(word) if c in "sfrxjzw"]
    # D18: any later a/e/o/d that repeats an earlier letter may act as a free-order key.
    doubles = [i for i in range(1, len(word)) if word[i] in "aeod" and word[i] in word[:i]]
    if not keyish and not doubles:
        return True
    ops = [("key", i) for i in keyish] + [("wdel", i) for i in keyish if word[i] == "w"] \
        + [("dbl", i) for i in doubles]
    if len(ops) > 16:
        return True
    for mask in range(1 << len(ops)):
        chars = list(word)
        drop = set()
        for b, (kind, i) in enumerate(ops):
            if mask >> b & 1:
                if kind == "wdel":
                    drop.add(i)
                elif kind == "key":
                    if word[i] == "w":
                        chars[i] = "u"
                    else:
                        drop.add(i)
                else:
                    drop.add(i)
        if skeleton_valid("".join(c for i, c in enumerate(chars) if i not in drop)):
            return False
    return True


def main():
    args = sys.argv[1:]
    out = DEFAULT_OUT
    while args:
        a = args.pop(0)
        if a == "--out":
            out = args.pop(0)
        else:
            sys.exit("unknown argument " + a)
    syls = build_syllables()

    sections = []
    seen = {}

    def add(title, pairs):
        rows = []
        for k, v in pairs:
            v = nfc(v)
            if k in seen:
                if seen[k] != v:
                    sys.exit("conflict for keys %r: %r vs %r" % (k, seen[k], v))
                continue
            seen[k] = v
            rows.append((k, v))
        sections.append((title, rows))

    add("Syllables, tone key at the end of the word (rule-generated, D13 tone placement)",
        [(s.keys(), s.text) for s in syls])
    add("Syllables, tone key right after the vowel nucleus",
        [(s.keys(mid=True), s.text) for s in syls if s.tone and s.fin])
    add("Capitalised (first letter upper), tone at end or after the vowel",
        [((cap(s.keys(mid=bool(h(s.text) & 1)))), cap(s.text)) for s in syls if h(s.text) % 4 == 0])
    add("ALL CAPS sample",
        [(s.keys(mid=bool(h(s.text) & 2)).upper(), s.text.upper()) for s in syls if h(s.text) % 11 == 0])
    add("uwow spelling of the horn nucleus (alternative to uow)",
        [(s.keys(alt=True), s.text) for s in syls if s.nuc.startswith("ươ")])
    add("w alone as u-horn at a vowel position",
        [(keys_of(s.init) + "w" + keys_of(s.fin) + s.tone, s.text) for s in syls if s.nuc == "ư"])
    add("z clears the tone (diacritics stay)",
        [(s.keys() + "z", s.plain) for s in syls if s.tone and h(s.text) % 13 == 0])
    add("Hand-written: dd, w, uow, undo by repetition, z", [
        ("dd", "đ"), ("DD", "Đ"), ("Dd", "Đ"), ("ddd", "dd"), ("DDD", "DD"),
        ("w", "ư"), ("W", "Ư"), ("tw", "tư"), ("Tw", "Tư"), ("TW", "TƯ"), ("ww", "w"),
        ("uow", "ươ"), ("uwow", "ươ"), ("Uow", "Ươ"), ("UOW", "ƯƠ"),
        ("ass", "as"), ("Ass", "As"), ("ASS", "AS"), ("aaa", "aa"), ("AAA", "AA"),
        ("asz", "a"), ("aww", "aw"), ("ooo", "oo"), ("eee", "ee"),
        ("aff", "af"), ("arr", "ar"), ("axx", "ax"), ("ajj", "aj"), ("oww", "ow"), ("uww", "uw"),
        ("daaa", "daa"), ("thww", "thw"), ("ddatj", "đạt"),
        ("Vieetj", "Việt"), ("VIEETJ", "VIỆT"), ("vieetj", "việt"), ("vieejt", "việt"),
    ])

    seen_before_d18 = set(seen)
    # D18: free-order circumflex and đ.
    hat = late_hat_cases(syls)
    dd = late_d_cases(syls)

    def sample(items, mod, salt):
        return [(k, s) for k, s in items if h(salt + k) % mod == 0]

    hat_titles = {
        "final": "Circumflex key typed after the final consonant, tone last (D18: vietej, vietes)",
        "tone_first": "Tone key, then the circumflex key at the very end (D18: tiengse)",
        "after_tone": "Tone key, circumflex key, then the final consonant (D18: vieset)",
    }
    hat_mod = {"final": 6, "tone_first": 6, "after_tone": 5}
    for kind in ("final", "tone_first", "after_tone"):
        add(hat_titles[kind], [(k, s.text) for k, s in sample(hat[kind], hat_mod[kind], "h" + kind)])
        add(hat_titles[kind] + ", capitalised sample",
            [(cap(k), cap(s.text)) for k, s in sample(hat[kind], 40, "c" + kind)])
        add(hat_titles[kind] + ", ALL CAPS sample",
            [(k.upper(), s.text.upper()) for k, s in sample(hat[kind], 90, "u" + kind)])
    d_titles = {
        "final": "Later d after the final consonant, tone last (D18: duowngd, dinhd)",
        "tone_first": "Tone key, then the later d at the very end (D18)",
    }
    d_mod = {"final": 3, "tone_first": 4}
    for kind in ("final", "tone_first"):
        add(d_titles[kind], [(k, s.text) for k, s in sample(dd[kind], d_mod[kind], "d" + kind)])
        add(d_titles[kind] + ", capitalised sample",
            [(cap(k), cap(s.text)) for k, s in sample(dd[kind], 12, "cd" + kind)])
        add(d_titles[kind] + ", ALL CAPS sample",
            [(k.upper(), s.text.upper()) for k, s in sample(dd[kind], 30, "ud" + kind)])
    add("Hand-written D18 cases", [
        ("vieset", "viết"), ("tiengse", "tiếng"), ("vietej", "việt"), ("tieeng", "tiêng"),
        ("duowngd", "đương"), ("duowngfd", "đường"), ("dinhd", "đinh"), ("Dinhd", "Đinh"), ("DINHD", "ĐINH"),
        ("Vieset", "Viết"), ("VIESET", "VIẾT"), ("Tiengse", "Tiếng"), ("Duowngd", "Đương"), ("Duowngfd", "Đường"),
        ("ana", "ân"), ("dad", "đa"), ("toio", "tôi"), ("bese", "bế"), ("viete", "viêt"),
    ])

    # Words that stay raw, and words whose keys now form a Vietnamese syllable (D18).
    new_keys = {}
    for kind in hat:
        for k, s in hat[kind]:
            new_keys[k] = s.text
    for kind in dd:
        for k, s in dd[kind]:
            new_keys[k] = s.text
    rejected = []
    eng = []
    now_vi = []
    for w in dict.fromkeys(ENGLISH):
        if english_safe(w) and seen.get(w, w) == w:
            eng.append(w)
        else:
            rejected.append(w)
            if w in new_keys and w not in seen_before_d18:
                now_vi.append((w, new_keys[w]))
    pairs = [(w, w) for w in eng]
    pairs += [(cap(w), cap(w)) for w in eng if h(w) % 3 == 0]
    pairs += [(w.upper(), w.upper()) for w in eng if h(w) % 5 == 0]
    add("English / code words passed through unchanged (stay raw under D18)", pairs)
    add("english_now_vietnamese: English words that form a valid syllable under D18",
        now_vi + [(cap(k), cap(v)) for k, v in now_vi])

    total = sum(len(r) for _, r in sections)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("# telex golden list: keys<TAB>expected (NFC). Generated by tools/golden-gen/gen.py; do not edit.\n")
        for title, rows in sections:
            f.write("# %s [%d]\n" % (title, len(rows)))
            for k, v in rows:
                f.write("%s\t%s\n" % (k, v))
    print("base syllables %d, toned syllables %d" % (len(base_syllables()), len(syls)))
    for title, rows in sections:
        print("%6d  %s" % (len(rows), title))
    print("%6d  total cases" % total)
    print("english kept %d, rejected %d: %s" % (len(eng), len(rejected), " ".join(rejected)))


if __name__ == "__main__":
    main()
