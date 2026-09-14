#!/usr/bin/env python3
"""
Head-to-head: what WordDumb annotates on a passage vs. what Summa annotates.

Answers one question -- is Summa's output actually different, or is it a
noisier restatement of what WordDumb already gives away for free?

For each Summa annotation, check whether WordDumb's selection covers the same
span, either as an X-Ray entity or as a Word Wise lemma. Anything covered is
overlap. Anything uncovered is the part of Summa that WordDumb structurally
cannot reach.
"""

import argparse
import json
import re
from collections import Counter
from pathlib import Path


def norm(s):
    s = s.lower()
    s = s.replace("æ", "ae").replace("’", "'")
    s = re.sub(r"[^a-z0-9' ]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def words(s):
    return [w for w in norm(s).split() if w]


def covered_by(anchor, xray_terms, ww_lemmas):
    """LOOSE coverage: any content word in the anchor is an X-Ray entity or a
    Word Wise lemma. Deliberately hostile to Summa -- a multiword anchor counts
    as covered when WordDumb happens to gloss one incidental word inside it."""
    aw = words(anchor)
    hits = []
    for w in aw:
        if w in xray_terms:
            hits.append(("xray", w))
        elif w in ww_lemmas:
            hits.append(("wordwise", w))
    # whole-anchor entity match (multiword entities like "White Steed")
    if norm(anchor) in xray_terms:
        hits.append(("xray", norm(anchor)))
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--worddumb", type=Path, required=True)
    ap.add_argument("--summa", type=Path, required=True)
    args = ap.parse_args()

    wd = json.loads(args.worddumb.read_text())
    su = json.loads(args.summa.read_text())

    xray_terms = set()
    for e in wd["xray"]:
        xray_terms.add(norm(e["text"]))
        for w in words(e["text"]):
            xray_terms.add(w)
    ww_lemmas = {norm(e["lemma"]) for e in wd["word_wise"]}

    anns = su["annotations"]
    wd_total = len(wd["xray"]) + len(wd["word_wise"])

    print("=" * 72)
    print(f"{su['source']}  --  {su['words']} words")
    print("=" * 72)
    print()
    print(f"WordDumb  : {len(wd['xray']):>4} X-Ray entities")
    print(f"            {len(wd['word_wise']):>4} Word Wise lemmas")
    print(f"            {wd_total:>4} annotations total"
          f"   ({su['words']/wd_total:.0f} words per annotation)")
    print(f"Summa     : {len(anns):>4} annotations total"
          f"   ({su['words']/len(anns):.0f} words per annotation)")
    print(f"            {Counter(a['type'] for a in anns)}")
    print()
    print(f"Summa annotates {wd_total/len(anns):.0f}x less than WordDumb "
          f"on the same text.")
    print()

    uncovered, overlapped = [], []
    for a in anns:
        hits = covered_by(a["anchor"], xray_terms, ww_lemmas)
        (overlapped if hits else uncovered).append((a, hits))

    print("-" * 72)
    print(f"OVERLAP -- WordDumb also selects this span ({len(overlapped)}/{len(anns)})")
    print("-" * 72)
    for a, hits in overlapped:
        src = ",".join(sorted({h[0] for h in hits}))
        print(f"  [{a['type']:<14}] {a['anchor']:<38} <- {src}")

    print()
    print("-" * 72)
    print(f"SUMMA ONLY -- WordDumb cannot reach this ({len(uncovered)}/{len(anns)})")
    print("-" * 72)
    for a, _ in uncovered:
        print(f"  [{a['type']:<14}] {a['anchor']}")
        print(f"                   {a['note']}")

    print()
    # STRICT coverage: the whole anchor is itself an entity or a glossed lemma.
    ents = {norm(e["text"]) for e in wd["xray"]}
    strict_cov = [a for a in anns if norm(a["anchor"]) in ents or norm(a["anchor"]) in ww_lemmas]
    strict_un = [a for a in anns if a not in strict_cov]

    print()
    print("-" * 72)
    print("STRICT -- whole anchor is itself an X-Ray entity or a Word Wise lemma")
    print("-" * 72)
    print(f"  covered {len(strict_cov)}/{len(anns)}, unique to Summa {len(strict_un)}")
    print(f"  by type: {dict(Counter(a['type'] for a in strict_un))}")
    print()
    print("  NOTE: coverage means WordDumb selects the same SPAN, not that it")
    print("  produces the same note. On 'Xerxes' WordDumb emits a Wikipedia")
    print("  summary of the Achaemenid king; Summa explains why Melville")
    print("  reached for him. This script cannot measure that difference.")

    print()
    print("-" * 72)
    print("BY TYPE (loose) -- how much of each Summa type WordDumb already covers")
    print("-" * 72)
    by_type = {}
    for a, hits in overlapped:
        by_type.setdefault(a["type"], [0, 0])[0] += 1
    for a, _ in uncovered:
        by_type.setdefault(a["type"], [0, 0])[1] += 1
    for t, (ov, un) in sorted(by_type.items()):
        tot = ov + un
        print(f"  {t:<16} {ov}/{tot} covered by WordDumb, {un} unique to Summa")


if __name__ == "__main__":
    main()
