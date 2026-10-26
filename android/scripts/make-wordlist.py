#!/usr/bin/env python3
"""Builds app/src/main/assets/common-words-en.txt: ordinary English words, all their forms, lowercase.

Auto-learn uses it to tell ordinary words ("apple") from names and jargon ("Nadiah", "kubectl").
Source: the SCOWL Hunspell en_US dictionary (https://github.com/en-wl/wordlist, permissive licence,
notice copied to assets/common-words-en-LICENSE.txt). Words that start with a capital in the
dictionary are proper names and are left out.

Usage: scripts/make-wordlist.py path/to/en_US.aff path/to/en_US.dic
"""
import re
import sys
from pathlib import Path


def affixes(aff_path):
    rules = {}  # flag -> (kind, cross, [(strip, add, condition regex)])
    lines = Path(aff_path).read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        parts = lines[i].split()
        if len(parts) == 4 and parts[0] in ("PFX", "SFX") and parts[3].isdigit():
            kind, flag, cross, count = parts[0], parts[1], parts[2] == "Y", int(parts[3])
            entries = []
            for line in lines[i + 1:i + 1 + count]:
                p = line.split()
                strip = "" if p[2] == "0" else p[2]
                add = "" if p[3] == "0" else p[3].split("/")[0]
                cond = p[4] if len(p) > 4 else "."
                pattern = ("^" + cond) if kind == "PFX" else (cond + "$")
                entries.append((strip, add, re.compile(pattern)))
            rules[flag] = (kind, cross, entries)
            i += count
        i += 1
    return rules


def apply(word, rule):
    kind, _, entries = rule
    out = []
    for strip, add, cond in entries:
        if not cond.search(word):
            continue
        if kind == "SFX":
            if strip and not word.endswith(strip):
                continue
            out.append(word[:len(word) - len(strip)] + add)
        else:
            if strip and not word.startswith(strip):
                continue
            out.append(add + word[len(strip):])
    return out


def main(aff_path, dic_path, out_path):
    rules = affixes(aff_path)
    words = set()
    for line in Path(dic_path).read_text(encoding="utf-8").splitlines()[1:]:
        stem, _, flags = line.strip().partition("/")
        if not re.fullmatch(r"[a-z][a-z'-]*", stem):
            continue
        flags = [f for f in flags if f in rules]
        forms = {stem}
        sfx = [rules[f] for f in flags if rules[f][0] == "SFX"]
        pfx = [rules[f] for f in flags if rules[f][0] == "PFX"]
        for r in sfx:
            forms.update(apply(stem, r))
        for p in pfx:
            forms.update(apply(stem, p))
            if p[1]:  # prefixes combine with cross-product suffixes
                for r in sfx:
                    if r[1]:
                        for f in apply(stem, r):
                            forms.update(apply(f, p))
        words.update(w.lower() for w in forms if len(w) > 1)
    Path(out_path).write_text("\n".join(sorted(words)) + "\n", encoding="utf-8")
    print(f"{len(words)} words -> {out_path}")


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    main(sys.argv[1], sys.argv[2], root / "app/src/main/assets/common-words-en.txt")
