"""Team-authored table of Vietnamese rhymes (nucleus + final) for tools/wordlists/gen.py.

Source: the authors' own knowledge of Vietnamese spelling syllable list exists). The table is INCLUSIVE: a rhyme lists every initial for which at
least one toned syllable is attested in common use (names, loanwords, colloquial speech
included) or plausible; the rule-valid set of tools/golden-gen/gen.py is the upper bound.
Each entry is `rhyme: initials that are NOT used with it`; a rhyme missing from EXCEPT is
used with every rule-valid initial. ONLY maps a rhyme to the exact initials that are used.
"""

# Initials never used with the rhyme (the rule-valid set minus these is kept).
EXCEPT = {
    "ach": {"gi", "d", "đ"},
    "au": {"d", "gi"},
    "ec": {"gh", "k", "ngh"},
    "eng": {"gh", "ngh"},
    "em": {"ngh"},
    "ep": {"ngh"},
    "ich": {"gh"},
    "inh": {"gh"},
    "ip": {"gh"},
    "it": {"gh"},
    "im": {"gh"},
    "iêc": {"gh", "k", "ngh"},
    "iêm": {"gh", "ngh"},
    "iêng": {"gh"},
    "iêp": {"gh", "ngh"},
    "iêt": {"gh", "ngh"},
    "ua": {"ng", "ph"},
    "êch": {"gh"},
    "êm": {"gh", "ngh"},
    "êp": {"gh", "ngh"},
    "êt": {"gh"},
    "êu": {"gi"},
    "âc": {"ph", "d", "m", "ch", "th", "v", "tr", "s", "r", "đ"},
    "ơm": {"ph", "kh"},
    "ưc": {"g", "kh"},
    "ươc": {"g", "gi"},
    "ươi": {"ph", "n", "d", "đ"},
}

# Rhymes used only with the listed initials ("" = no initial).
ONLY = {
    "oa": {"", "ch", "d", "đ", "h", "kh", "l", "ng", "nh", "t", "th", "x"},
    "oac": {"", "h", "kh", "l", "ng", "x", "t"},
    "oach": {"", "h", "kh", "l", "ng", "x", "t", "ch"},
    "oai": {"", "ch", "h", "kh", "l", "ng", "nh", "s", "t", "th", "x", "đ"},
    "oan": {"", "d", "đ", "h", "kh", "l", "ng", "s", "t", "th", "x"},
    "oang": {"", "ch", "h", "kh", "l", "ng", "t", "th", "x"},
    "oanh": {"", "d", "h", "kh", "l", "ng", "t", "x", "ch"},
    "oat": {"", "ch", "d", "đ", "h", "kh", "l", "s", "t", "th", "x"},
    "oay": {"", "ch", "h", "kh", "l", "ng", "x", "t"},
    "oe": {"", "ch", "h", "kh", "l", "ng", "nh", "t", "x"},
    "oen": {"", "h", "kh", "l", "t", "x", "nh", "ng"},
    "oeo": {"", "kh", "l", "ng", "nh", "x", "t", "h", "ch"},
    "oet": {"", "h", "kh", "l", "t", "x", "ng", "ch", "nh"},
    "oăc": {"", "h", "kh", "l", "ng", "t", "x", "ch"},
    "oăn": {"", "kh", "l", "ng", "x", "t", "ch", "h"},
    "oăng": {"", "h", "kh", "l", "ng", "x", "t", "ch"},
    "oăt": {"", "ch", "h", "kh", "l", "ng", "th", "t", "x", "s", "đ"},
    "uy": {"", "b", "ch", "d", "đ", "h", "kh", "l", "m", "n", "ng", "nh", "ph", "r", "s", "t",
           "th", "tr", "x", "v"},
    "uya": {"kh"},
    "uych": {"", "h", "kh", "x", "t", "ng", "m", "l", "ch"},
    "uynh": {"", "h", "kh", "l", "ng", "x", "t"},
    "uyt": {"", "b", "h", "kh", "l", "t", "x", "s", "ng", "nh", "ch"},
    "uyu": {"", "kh", "nh", "ng", "l", "t"},
    "uyên": {"", "ch", "d", "đ", "h", "kh", "l", "n", "ng", "nh", "s", "t", "th", "tr", "x"},
    "uyêt": {"", "d", "h", "kh", "l", "ng", "t", "th", "x", "tr", "ch", "s", "đ"},
    "uân": {"", "ch", "d", "h", "kh", "l", "ng", "nh", "s", "t", "th", "tr", "x", "đ"},
    "uâng": {"", "kh", "ng"},
    "uât": {"", "ch", "kh", "l", "nh", "s", "t", "th", "tr", "x"},
    "uây": {"kh"},
    "uê": {"", "d", "đ", "h", "kh", "n", "nh", "t", "th", "x", "s"},
    "uêch": {"kh", "ng", "x", "h", ""},
    "uênh": {"h", "kh", "ng", "x", "ch", "", "t", "l"},
    "uôc": {"", "b", "c", "ch", "g", "l", "m", "nh", "r", "s", "t", "th", "x", "đ"},
    "uôi": {"b", "c", "ch", "đ", "d", "l", "m", "n", "ng", "r", "s", "t", "x"},
    "uôm": {"b", "ch", "l", "m", "n", "nh", "r", "t", "th", "ng"},
    "uôn": {"b", "c", "ch", "kh", "l", "m", "n", "ng", "nh", "s", "t", "th", "v", "x", "r"},
    "uôt": {"b", "ch", "l", "m", "n", "nh", "s", "t", "th", "v", "tr", "r", "x"},
    "ươm": {"", "b", "c", "g", "h", "l", "n", "r", "s", "t", "th", "tr"},
    "ươn": {"", "b", "c", "ch", "d", "l", "n", "s", "th", "tr", "v", "ng", "g", "x"},
    "ươp": {"c", "l", "m", "n", "ng"},
    "ươt": {"", "b", "d", "l", "m", "n", "nh", "r", "s", "t", "th", "tr", "v", "x", "kh"},
    "ươu": {"b", "h", "kh", "r"},
    "ưu": {"", "b", "c", "h", "kh", "l", "m", "n", "ng", "s"},
    "ưi": {"ch", "g", "ng"},
    "ưt": {"b", "ch", "d", "h", "kh", "l", "m", "n", "nh", "ph", "r", "s", "t", "v", "đ"},
    "y": {"", "h", "k", "l", "m", "n", "qu", "s", "t", "th", "v"},
    "yêm": {""}, "yên": {"", "qu"}, "yêu": {""}, "yêt": {"", "qu"},
    "ynh": {"qu"}, "yt": {"qu"},
    "yêc": set(), "yêng": set(), "yêp": set(),
}

# Real rhymes the rule set of golden-gen does not generate: (initial, nucleus, final).
EXTRA = [("g", "ư", "i"), ("ng", "ư", "i"), ("qu", "i", ""), ("qu", "i", "n"), ("qu", "i", "t"),
         ("h", "uơ", ""), ("qu", "ơ", ""), ("th", "uơ", ""), ("kh", "uơ", "")]

# Rhymes that the golden-gen shape tables leave out for gi-, ngh- and qu- and for a few
# glide shapes (authored): giúp, giống, giọng, giỏi, giọt, giỗ, giun, nghĩa, nghêu, quạu, quệt,
# ngoạm, khoằm, cửi, and their families. The engine check in gen.py drops what it cannot type.
EXTRA += (
    [("gi", n, f) for n, f in [
        ("e", ""), ("e", "m"), ("e", "n"), ("e", "p"), ("e", "t"), ("ê", "c"), ("ê", "n"),
        ("ê", "p"), ("ê", "m"), ("o", "i"), ("o", "ng"), ("o", "t"), ("o", "c"), ("o", "p"),
        ("o", "m"), ("ô", ""), ("ô", "c"), ("ô", "i"), ("ô", "ng"), ("ô", "n"), ("ô", "t"),
        ("ô", "p"), ("u", "n"), ("u", "ng"), ("u", "p"), ("u", "t"), ("u", "m"), ("u", "i"),
        ("ua", ""), ("uô", "c"), ("uô", "i"), ("uô", "n"), ("uô", "ng"), ("uô", "t"),
        ("â", "p"), ("â", "ng"), ("ă", "m"), ("ă", "p"), ("ă", "ng"), ("ư", "ng"), ("ư", "c"),
        ("ư", "t"), ("ơ", "m"), ("ơ", "t"), ("ơ", "p"), ("ơ", "ng"), ("i", ""), ("i", "n"),
    ]]
    + [("ngh", n, f) for n, f in [
        ("ia", ""), ("iu", ""), ("êu", ""), ("iêu", ""), ("i", "m"), ("ê", "ch"),
    ]]
    + [("qu", n, f) for n, f in [
        ("au", ""), ("ă", "m"), ("ê", "t"), ("ê", "u"), ("ê", "m"), ("a", "m"), ("a", "p"),
        ("i", "n"), ("i", "m"), ("uyu", ""), ("ê", ""), ("ê", "n"), ("ê", "ch"),
    ]]
    + [(i, "oa", "m") for i in ("ng", "kh", "h")]
    + [(i, "oă", "m") for i in ("ng", "kh", "h")]
    + [("c", "ư", "i")]
)
