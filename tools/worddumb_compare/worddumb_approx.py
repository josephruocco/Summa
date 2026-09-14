#!/usr/bin/env python3
"""
Approximate WordDumb's annotation output for a passage, so it can be compared
against Summa's LLM annotations on the same text.

This is an APPROXIMATION, not WordDumb itself. WordDumb needs calibre, Wiktionary
(kaikki) dumps and Wikidata access, none of which run here. What is reproduced
faithfully is the *selection* logic, which is what the comparison is about:

  X-Ray     spaCy NER, filtered to WordDumb's NER_LABELS frozenset and its
            documented cleanup rules (x_ray_share.py, parse_job.py).
  Word Wise WordDumb glosses lemmas that carry a Wiktionary difficulty level.
            Stand-in here: any lemma outside the top-N most frequent English
            words (Resources/common_words_en_20k.txt, already in this repo).

The *descriptions* WordDumb attaches (Wikipedia summary, Wikidata fields,
Wiktionary sense) are not fetched. Selection, not prose, is the thing under test.
"""

import argparse
import json
import re
import sys
from pathlib import Path

import spacy

REPO = Path(__file__).resolve().parents[2]

# x_ray_share.py NER_LABELS — the English-relevant members.
NER_LABELS = frozenset(
    {"EVENT", "FAC", "GPE", "LAW", "LOC", "ORG", "PERSON", "PRODUCT", "MISC"}
)

# parse_job.py find_named_entity() cleanup rules.
LEADING_ARTICLE = re.compile(r"^(the|a|an)\s+", re.IGNORECASE)
DIRECTIONS = {"north", "south", "east", "west", "northeast", "northwest",
              "southeast", "southwest"}
CHAPTER_REF = re.compile(r"^(chapter|part|page|vol|volume)\b", re.IGNORECASE)
URLISH = re.compile(r"(https?://|www\.|\.\w{2,4}$)", re.IGNORECASE)
EDGE_JUNK = re.compile(r"^\W+|\W+$")


def load_common(limit):
    words = (REPO / "Resources" / "common_words_en_20k.txt").read_text().split()
    return set(w.lower() for w in words[:limit])


def xray(doc):
    seen = {}
    for ent in doc.ents:
        if ent.label_ not in NER_LABELS:
            continue
        text = EDGE_JUNK.sub("", ent.text.replace("\n", " ")).strip()
        text = LEADING_ARTICLE.sub("", text).strip()
        if len(text) < 3:
            continue
        if text.lower() in DIRECTIONS:
            continue
        if CHAPTER_REF.match(text) or URLISH.search(text):
            continue
        key = text.lower()
        if key not in seen:
            seen[key] = {"text": text, "label": ent.label_, "count": 0}
        seen[key]["count"] += 1
    return sorted(seen.values(), key=lambda e: (-e["count"], e["text"]))


def word_wise(doc, common):
    seen = {}
    for tok in doc:
        if not tok.is_alpha or tok.is_stop or tok.ent_type_:
            continue
        if tok.pos_ not in {"NOUN", "VERB", "ADJ", "ADV"}:
            continue
        lemma = tok.lemma_.lower()
        if len(lemma) < 4 or lemma in common:
            continue
        if lemma not in seen:
            seen[lemma] = {"lemma": lemma, "pos": tok.pos_, "count": 0,
                           "first_form": tok.text}
        seen[lemma]["count"] += 1
    return sorted(seen.values(), key=lambda e: (-e["count"], e["lemma"]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("text", type=Path)
    ap.add_argument("--common-limit", type=int, default=10000,
                    help="lemmas inside the top-N frequency list are treated as "
                         "easy and not glossed (default 10000)")
    ap.add_argument("--json", type=Path)
    args = ap.parse_args()

    raw = args.text.read_text()
    nlp = spacy.load("en_core_web_sm")
    nlp.max_length = max(len(raw) + 1000, nlp.max_length)
    doc = nlp(raw)

    common = load_common(args.common_limit)
    entities = xray(doc)
    hard = word_wise(doc, common)

    out = {
        "source": str(args.text),
        "words": sum(1 for t in doc if t.is_alpha),
        "common_limit": args.common_limit,
        "xray": entities,
        "word_wise": hard,
    }
    if args.json:
        args.json.write_text(json.dumps(out, indent=2))

    print(f"{args.text.name}: {out['words']} words")
    print(f"X-Ray entities      : {len(entities)} unique "
          f"({sum(e['count'] for e in entities)} mentions)")
    print(f"Word Wise lemmas    : {len(hard)} unique "
          f"({sum(e['count'] for e in hard)} mentions)")
    print(f"TOTAL annotations   : {len(entities) + len(hard)} unique")
    print()
    print("X-Ray:")
    for e in entities:
        print(f"  [{e['label']:<7}] {e['text']}  x{e['count']}")
    print()
    print(f"Word Wise (first 60 of {len(hard)}):")
    for e in hard[:60]:
        print(f"  [{e['pos']:<4}] {e['lemma']}  x{e['count']}")


if __name__ == "__main__":
    main()
