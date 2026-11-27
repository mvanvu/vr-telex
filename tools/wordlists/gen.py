#!/usr/bin/env python3
"""Generate crates/telex-core/data/en.txt and vi.txt (see tools/wordlists/README.md).

en.txt: English words (SCOWL via the system wamerican list) whose Telex reading the
engine changes (the cargo example `wordfilter` runs the real engine).
vi.txt: Vietnamese syllables = team-authored rhyme table (vi_rhymes.py) over the
rule-valid shapes of tools/golden-gen/gen.py, merged with the syllable inventory read
from an optional Vietnamese word list (any, one word per line) given on the command line (never shipped), minus the forms
that the English words produce and that are not real syllables (vi_overrides.py),
validated against the engine.

Usage (repo root):
  python3 -I tools/wordlists/gen.py [--viet-source WORDLIST] [--english PATH]
Standard library only (cargo is used for the engine filter); no network.
"""
import importlib.util
import os
import re
import subprocess
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DATA = os.path.join(ROOT, "crates/telex-core/data")


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


GG = load(os.path.join(ROOT, "tools/golden-gen/gen.py"), "golden_gen")
RH = load(os.path.join(HERE, "vi_rhymes.py"), "vi_rhymes")
OV = load(os.path.join(HERE, "vi_overrides.py"), "vi_overrides")

TONE_MARKS = {"́": "s", "̀": "f", "̉": "r", "̃": "x", "̣": "j"}


def nfc(s):
    return unicodedata.normalize("NFC", s)


def engine(mode, lines):
    """Runs the cargo example `wordfilter` and returns its output lines."""
    cmd = ["cargo", "run", "-q", "-p", "telex-core", "--example", "wordfilter", "--locked", "--", mode]
    res = subprocess.run(cmd, input="\n".join(lines) + "\n", capture_output=True, text=True,
                         cwd=ROOT, check=True)
    return res.stdout.splitlines()


def english_candidates(path):
    out = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            w = line.rstrip("\n")
            if len(w) >= 2 and re.fullmatch(r"[a-z]+", w):
                out.add(w)
    return sorted(out)


def authored_syllables():
    """Syllables from the rhyme table: list of Syl objects."""
    out = []
    for init, nuc, fin in GG.base_syllables():
        r = nuc + fin
        if r in RH.ONLY:
            if init not in RH.ONLY[r]:
                continue
        elif init in RH.EXCEPT.get(r, ()):
            continue
        out.append((init, nuc, fin))
    out.extend(RH.EXTRA)
    return out


def tones_for(fin):
    return ["", "s", "j"] if fin in ("c", "ch", "p", "t") else ["", "s", "f", "r", "x", "j"]


INITIALS = ["ngh", "ng", "nh", "ph", "th", "tr", "ch", "kh", "gh", "gi", "qu", "b", "c", "d", "đ",
            "g", "h", "k", "l", "m", "n", "r", "s", "t", "v", "x", ""]
FINALS = ["ch", "ng", "nh", "c", "m", "n", "p", "t", ""]
VOWELS = set("aăâeêioôơuưy")


def parse_token(tok):
    """(initial, nucleus, final, tone) of a lowercase token, or None. The shape is only a sanity
    check: the engine check in main() decides whether the syllable can be typed."""
    d = unicodedata.normalize("NFD", tok)
    tone = [TONE_MARKS[c] for c in d if c in TONE_MARKS]
    if len(tone) > 1:
        return None
    plain = nfc("".join(c for c in d if c not in TONE_MARKS))
    for init in INITIALS:
        if not plain.startswith(init):
            continue
        rest = plain[len(init):]
        if not rest or rest[0] not in VOWELS:
            continue
        for fin in FINALS:
            if fin and not rest.endswith(fin):
                continue
            nuc = rest[:len(rest) - len(fin)]
            if nuc and len(nuc) <= 3 and all(c in VOWELS for c in nuc):
                t = tone[0] if tone else ""
                if t not in tones_for(fin):
                    return None
                return init, nuc, fin, t
    return None


def source_syllables(path):
    """(token count, {syllable text in modern tone placement: Telex keys}) from a word list."""
    tokens = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            for tok in re.split(r"[\s\-.,;:()/]+", line.strip()):
                if tok:
                    tokens.add(tok.lower())
    found = {}
    for tok in tokens:
        parsed = parse_token(tok)
        if parsed:
            syl = GG.Syl(*parsed)
            found[syl.text] = syl.keys()
    return len(tokens), found


def write_list(name, items):
    path = os.path.join(DATA, name)
    os.makedirs(DATA, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for it in items:
            f.write(it + "\n")
    return path


def check_format(items, ascii_only):
    assert items == sorted(set(items), key=lambda s: s.encode()), "not unique/sorted"
    for it in items:
        assert it and it == it.lower() and "\n" not in it and it == nfc(it)
        if ascii_only:
            assert re.fullmatch(r"[a-z]{2,}", it), it


def main():
    args = sys.argv[1:]
    src = None
    english = "/usr/share/dict/american-english"
    while args:
        a = args.pop(0)
        if a == "--viet-source":
            src = args.pop(0)
        elif a == "--english":
            english = args.pop(0)
        else:
            sys.exit("unknown argument " + a)

    cands = english_candidates(english)
    en_pairs = [l.split("\t") for l in engine("pairs", cands)]
    en = sorted({w for w, _ in en_pairs}, key=lambda s: s.encode())
    forms = sorted({v for _, v in en_pairs}, key=lambda s: s.encode())

    authored = {}
    for init, nuc, fin in authored_syllables():
        for t in tones_for(fin):
            s = GG.Syl(init, nuc, fin, t)
            authored[s.text] = s
    n_tokens, from_src = source_syllables(src) if src else (0, {})
    merged = set(authored) | set(from_src)
    added_by_us = len(set(authored) - set(from_src))

    # Forms the English words produce: only the ones judged real stay.
    for f in forms:
        if f in OV.REAL_EN_FORMS:
            merged.add(f)
        else:
            merged.discard(f)
    for f in OV.REAL_EN_FORMS:
        assert f in forms or f in merged, f

    # Engine validation: typing each syllable's keys must give the syllable back.
    key_of = dict(from_src)
    for s in authored.values():
        key_of.setdefault(s.text, s.keys())
    lines = []
    for text in sorted(merged):
        k = key_of.get(text) or reverse_keys(text)
        if k:
            lines.append(text + "\t" + k)
    bad = {l.split("\t")[0] for l in engine("check", lines)}
    unkeyed = merged - {l.split("\t")[0] for l in lines}
    dropped = sorted(bad | unkeyed)
    vi = sorted(merged - set(dropped), key=lambda s: s.encode())

    check_format(en, True)
    check_format(vi, False)
    en_path = write_list("en.txt", en)
    vi_path = write_list("vi.txt", vi)
    real_forms = [f for f in forms if f in set(vi)]
    print("english candidates %d" % len(cands))
    print("en.txt lines %d" % len(en))
    print("distinct vietnamese forms from en.txt %d, judged real %d" % (len(forms), len(real_forms)))
    print("source tokens %d, valid syllables from source %d" % (n_tokens, len(from_src)))
    print("authored syllables %d, added by authored table only %d" % (len(authored), added_by_us))
    print("dropped by engine check %d: %s" % (len(dropped), " ".join(dropped)))
    print("vi.txt lines %d" % len(vi))
    print("sizes en.txt %d bytes, vi.txt %d bytes" % (os.path.getsize(en_path), os.path.getsize(vi_path)))


def reverse_keys(text):
    """Telex keys of a syllable text whose shape is rule-valid (via golden-gen)."""
    d = unicodedata.normalize("NFD", text)
    tone = [TONE_MARKS[c] for c in d if c in TONE_MARKS]
    stripped = nfc("".join(c for c in d if c not in TONE_MARKS))
    for init, nuc, fin in GG.base_syllables():
        if nfc(init + nuc + fin) == stripped:
            return GG.Syl(init, nuc, fin, tone[0] if tone else "").keys()
    return None


if __name__ == "__main__":
    main()
