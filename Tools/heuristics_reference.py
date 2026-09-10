#!/usr/bin/env python3
"""Transliteration of FilenameParser + VersionMatcher, used to exercise the
heuristics where no Swift toolchain is available.

The Swift implementation in Packages/DubplateCore/Services is authoritative and is
covered by Tests/CoreTests. This file mirrors it rule for rule so the *behaviour*
of the heuristics can be checked against a table of real-world bounce names on any
machine. Run: python3 Tools/heuristics_reference.py
"""
import re, sys, unicodedata

VERSION_KEYWORDS = {
    "v","ver","version","mix","mixes","master","mastered","mstr","bounce","take",
    "pass","print","rough","demo","sketch","idea","final","alt","alternate","edit",
    "ref","reference","wip","draft","comp","rev","revision","test","tweak","tweaks",
    "fix","fixed","drums","drum","vox","vocal","vocals","bass","keys","gtr","guitar",
    "synth","stems","inst","instrumental","acapella","backup","copy","revised",
    "clean","dirty","wet","dry","loud","quiet","louder","quieter","radio","extended",
}
MODIFIER_WORDS = {"new","old","more","less","no","without","with","extra","another"}
WEAK_TOKENS = VERSION_KEYWORDS | MODIFIER_WORDS | {"up","down","long","short","only"}
AUDIO_EXT = {"wav","wave","aif","aiff","aifc","caf","flac","m4a","mp4","alac","aac","mp3","m4b"}


def stem(name):
    return name.rsplit(".", 1)[0] if "." in name[1:] else name


def normalize(text):
    return "".join(c for c in text.lower() if c.isalnum())


def tokenize(text):
    for ch in "_-.–":
        text = text.replace(ch, " ")
    return [t for t in text.split(" ") if t]


def split_letter_digit(token):
    m = re.fullmatch(r"([A-Za-z]+)(\d+)", token)
    return (m.group(1), int(m.group(2))) if m else None


def is_weak(token):
    low = token.lower()
    if low in WEAK_TOKENS:
        return True
    sp = split_letter_digit(low)
    return bool(sp and sp[0] in WEAK_TOKENS)


def classify_group(group, state):
    trimmed = group.strip()
    if not trimmed:
        return
    low = trimmed.lower()
    for marker in ["feat.", "feat ", "ft.", "ft ", "featuring "]:
        if low.startswith(marker):
            state["featured"] = trimmed[len(marker):].strip()
            return
    words = tokenize(trimmed)
    if words and all(is_weak(w) or w.isdigit() for w in words):
        state["version_tokens"].extend(words)
    else:
        state["passthrough"] += " " + trimmed


def extract_parentheticals(text):
    state = {"featured": None, "version_tokens": [], "passthrough": ""}
    depth, group = 0, ""
    for ch in text:
        if ch in "([":
            depth += 1
            if depth == 1:
                group = ""
                continue
        if ch in ")]":
            depth -= 1
            if depth == 0:
                classify_group(group, state)
                continue
        if depth > 0:
            group += ch
        else:
            state["passthrough"] += ch
    if depth > 0:
        state["passthrough"] += group
    return state["passthrough"].strip(), state["featured"], state["version_tokens"]


def leading_track_number(words):
    if not words:
        return None
    first = words[0]
    low = first.lower()
    if low in ("track", "trk", "tk") and len(words) > 1 and words[1].isdigit():
        v = int(words[1])
        if 1 <= v <= 99:
            return v, words[2:]
    if first.isdigit() and len(first) <= 3 and len(words) > 1:
        v = int(first)
        if 1 <= v <= 199:
            return v, words[1:]
    if len(first) == 2 and first[0].isalpha() and first[1].isdigit() \
            and first[0].lower() in "abcd" and len(words) > 1:
        return int(first[1]), words[1:]
    return None


def strip_version_tail(words, track_number):
    remaining = list(words)
    tail = []
    while remaining:
        last = remaining[-1]
        low = last.lower()
        sp = split_letter_digit(low)
        if sp and sp[0] in VERSION_KEYWORDS:
            tail.insert(0, last); remaining.pop(); continue
        if low in VERSION_KEYWORDS:
            tail.insert(0, last); remaining.pop(); continue
        # "new" in "new drums" only counts once something after it was peeled.
        if low in MODIFIER_WORDS and tail:
            tail.insert(0, last); remaining.pop(); continue
        if low.isdigit() and len(remaining) >= 2:
            prev = remaining[-2].lower()
            prev_split = split_letter_digit(prev)
            if prev in VERSION_KEYWORDS or (prev_split and prev_split[0] in VERSION_KEYWORDS):
                tail.insert(0, last); remaining.pop(); continue
        break
    if not remaining and len(tail) == 1 and tail[0].isdigit():
        return list(words), []
    # Never strip a name down to nothing unless a track number can stand in for it.
    if not remaining and track_number is None:
        return list(words), []
    return remaining, tail


def ordinal(tokens):
    for token in reversed(tokens):
        if token.isdigit():
            return int(token)
        sp = split_letter_digit(token.lower())
        if sp:
            return sp[1]
    return None


def presentable_label(tokens):
    out = []
    for token in tokens:
        sp = split_letter_digit(token.lower())
        if sp:
            out.append(f"v{sp[1]}" if sp[0] == "v" else f"{sp[0].capitalize()} {sp[1]}")
        elif token.isdigit():
            out.append(str(int(token)))
        elif token.lower() == "v":
            out.append("v")
        elif any(c.isalpha() for c in token) and token.upper() == token:
            out.append(token)
        else:
            out.append(token.capitalize())
    return " ".join(out)


def presentable_title(words, track_number, fallback):
    joined = " ".join(words).strip()
    if not joined:
        return f"Track {track_number}" if track_number else fallback
    if any(c.isupper() for c in joined):
        return joined
    if any(c.islower() for c in joined):
        return " ".join(w if len(w) <= 2 else w.capitalize() for w in joined.split(" "))
    return joined


def parse(filename):
    working = stem(filename)
    working, featured, group_tokens = extract_parentheticals(working)
    track_number = None
    segments = [s.strip() for s in working.split(" - ") if s.strip()]
    if len(segments) > 1:
        numeric = next((s for s in segments if s.isdigit()), None)
        if numeric:
            track_number = int(numeric)
        non_numeric = [s for s in segments if not s.isdigit()]
        working = non_numeric[-1] if non_numeric else working
    words = tokenize(working)
    lead = leading_track_number(words)
    if lead:
        track_number = track_number if track_number is not None else lead[0]
        words = lead[1]
    words, consumed = strip_version_tail(words, track_number)
    consumed = consumed + group_tokens
    title = presentable_title(words, track_number, stem(filename))
    key = normalize("".join(words)) or normalize(title)
    return {
        "trackNumber": track_number,
        "title": title,
        "versionLabel": presentable_label(consumed) if consumed else None,
        "versionOrdinal": ordinal(consumed) if consumed else None,
        "featured": featured,
        "matchKey": key,
    }


def similarity(a, b):
    """Jaro-Winkler: rewards a shared prefix, which is how bounce names differ."""
    if a == b: return 1.0
    if not a or not b: return 0.0
    window = max(max(len(a), len(b)) // 2 - 1, 0)
    a_flags = [False] * len(a)
    b_flags = [False] * len(b)
    matches = 0
    for i, ch in enumerate(a):
        lo = max(0, i - window)
        hi = min(i + window + 1, len(b))
        for j in range(lo, hi):
            if not b_flags[j] and b[j] == ch:
                a_flags[i] = b_flags[j] = True
                matches += 1
                break
    if matches == 0:
        return 0.0
    k = 0
    transpositions = 0
    for i, ch in enumerate(a):
        if not a_flags[i]:
            continue
        while not b_flags[k]:
            k += 1
        if ch != b[k]:
            transpositions += 1
        k += 1
    transpositions //= 2
    jaro = (matches / len(a) + matches / len(b) + (matches - transpositions) / matches) / 3
    prefix = 0
    for x, y in zip(a[:4], b[:4]):
        if x != y: break
        prefix += 1
    return jaro + 0.1 * prefix * (1 - jaro)


def same_song_likelihood(incoming, existing):
    """0 when these are different songs, otherwise how sure we are."""
    if not incoming or not existing:
        return 0.0, ""
    if incoming == existing:
        return 1.0, "Same name"
    if weak_remainder(incoming, existing) is not None:
        return 0.94, "Same name with a new marker"
    # One name contains the other but the extra words are real words, not revision
    # markers: "Dust" and "Dust Storm" are two songs, not two bounces.
    if incoming.startswith(existing) or existing.startswith(incoming):
        return 0.0, ""
    ratio = similarity(incoming, existing)
    if ratio >= 0.90:
        return ratio, "Nearly the same name"
    return 0.0, ""


def is_weak_remainder(rest):
    if not rest or len(rest) > 24:
        return False
    peeled = 0
    while rest and peeled < 4:
        digits = re.match(r"\d+", rest)
        if digits:
            rest = rest[digits.end():]; peeled += 1; continue
        matched = False
        for token in sorted(WEAK_TOKENS, key=len, reverse=True):
            if rest.startswith(token):
                rest = rest[len(token):]; peeled += 1; matched = True; break
        if not matched:
            return False
    return not rest


def weak_remainder(incoming, existing):
    if incoming.startswith(existing) and len(incoming) > len(existing):
        return True if is_weak_remainder(incoming[len(existing):]) else None
    if existing.startswith(incoming) and len(existing) > len(incoming):
        return False if is_weak_remainder(existing[len(incoming):]) else None
    return None


def match(filename, candidates):
    """candidates: list of dicts {id,title,trackNumber,matchKeys}"""
    parsed = parse(filename)
    key = parsed["matchKey"]
    best = None
    for cand in candidates:
        conf, reason = 0.0, ""
        for ck in cand["matchKeys"]:
            if not ck:
                continue
            scored, why = same_song_likelihood(key, ck)
            if scored > conf:
                conf, reason = scored, why
            if conf == 1.0:
                break
            if conf == 0.0 and parsed["trackNumber"] is not None \
                    and parsed["trackNumber"] == cand["trackNumber"] \
                    and similarity(key, ck) >= 0.78:
                conf, reason = 0.75, "Same track number"
        if conf > 0 and (best is None or conf > best[1]):
            best = (cand["title"], conf, reason)
    if best and best[1] >= 0.70:
        return best
    return None


CASES = [
    # filename, expected trackNumber, expected title, expected version label
    ("04 Midnight v5.wav",            4,   "Midnight",   "v5"),
    ("Midnight Mix 01.wav",           None,"Midnight",   "Mix 1"),
    ("Midnight Mix 02.wav",           None,"Midnight",   "Mix 2"),
    ("04 Midnight master.wav",        4,   "Midnight",   "Master"),
    ("04 Midnight master2.wav",       4,   "Midnight",   "Master 2"),
    ("Track 1 mix 5.wav",             1,   "Track 1",    "Mix 5"),
    ("Track 2 FINAL 7.wav",           2,   "Track 2",    "FINAL 7"),
    ("Track 3 new master.wav",        3,   "Track 3",    "New Master"),
    ("NO SIGNAL - 02 - Dust.wav",     2,   "Dust",       None),
    ("NO SIGNAL - 03 - Something New (final master).wav", 3, "Something New", "Final Master"),
    ("01_intro.wav",                  1,   "Intro",      None),
    ("05 After Dark.aiff",            5,   "After Dark", None),
    ("midnight rough.wav",            None,"Midnight",   "Rough"),
    ("Midnight new drums.wav",        None,"Midnight",   "New Drums"),
    ("A1 Untitled.wav",               1,   "Untitled",   None),
    ("Dust (feat. Someone) v3.wav",   None,"Dust",       "v3"),
    ("10.wav",                        None,"10",         None),
    ("Blue Room bounce 12.wav",       None,"Blue Room",  "Bounce 12"),
]

MATCH_CASES = [
    # incoming filename, existing track keys, expect match?, expect confident?
    ("04 Midnight Mix 6.wav",      [("Midnight", 4, ["midnight"])],            True,  True),
    ("Midnight rough.wav",         [("Midnight", 4, ["midnight"])],            True,  True),
    ("Midnight new drums.wav",     [("Midnight", 4, ["midnight"])],            True,  True),
    ("Dust Storm.wav",             [("Dust", 2, ["dust"])],                    False, False),
    ("Midnite v2.wav",             [("Midnight", 4, ["midnight"])],            True,  True),
    ("Dusk.wav",                   [("Dust", 2, ["dust"])],                    False, False),
    ("Drums idea.wav",             [("Midnight", 4, ["midnight"])],            False, False),
    ("After Dark.wav",             [("Midnight", 4, ["midnight"])],            False, False),
    ("04 Untitled.wav",            [("Untitled Two", 4, ["untitledtwo"])],     True,  False),
    ("Something New master.wav",   [("Something New", 3, ["somethingnew"])],   True,  True),
]


def main():
    failures = 0
    print("== FilenameParser ==")
    for filename, number, title, label in CASES:
        got = parse(filename)
        ok = got["trackNumber"] == number and got["title"] == title and got["versionLabel"] == label
        failures += 0 if ok else 1
        flag = "ok  " if ok else "FAIL"
        print(f"{flag} {filename:46} -> #{got['trackNumber']} | {got['title']!r} | {got['versionLabel']!r} | key={got['matchKey']}")
        if not ok:
            print(f"      expected #{number} | {title!r} | {label!r}")

    print("\n== VersionMatcher ==")
    for filename, existing, expect_match, expect_confident in MATCH_CASES:
        cands = [{"id": i, "title": t, "trackNumber": n, "matchKeys": k}
                 for i, (t, n, k) in enumerate(existing)]
        got = match(filename, cands)
        has = got is not None
        confident = bool(got and got[1] >= 0.85)
        ok = has == expect_match and confident == expect_confident
        failures += 0 if ok else 1
        flag = "ok  " if ok else "FAIL"
        desc = f"{got[0]} ({got[1]:.2f}, {got[2]})" if got else "no match"
        print(f"{flag} {filename:30} -> {desc}")
        if not ok:
            print(f"      expected match={expect_match} confident={expect_confident}")

    print(f"\n{failures} failing case(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
