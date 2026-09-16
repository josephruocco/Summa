#!/usr/bin/env python3
"""
The experiment compare.py cannot run: on the anchors BOTH tools select, is the
note WordDumb produces actually different from Summa's, or only differently
worded?

compare.py measures span selection. This measures content. For every Summa
anchor that WordDumb also selects, print the two notes side by side:

  X-Ray anchor     -> the lead of the Wikipedia article WordDumb resolves to
  Word Wise anchor -> the short Wiktionary sense WordDumb would gloss with

Network: Wikipedia's REST summary endpoint and kaikki.org (the Wiktionary
extraction WordDumb ships against). Both are blocked from the Claude Code
container this was written in, so --offline falls back to this repo's own
tools/ground_truth/moby_dick.json, which records the Wikipedia article each
phrase resolves to. Offline mode shows the TARGET rather than the prose, which
is enough to see the difference in kind but not in register -- run it online for
the real thing.
"""

import argparse
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
WIKI = "https://en.wikipedia.org/api/rest_v1/page/summary/"
KAIKKI = "https://kaikki.org/dictionary/English/meaning/{a}/{ab}/{word}.jsonl"


def norm(s):
    s = s.lower().replace("æ", "ae").replace("’", "'")
    s = re.sub(r"[^a-z0-9' ]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def fetch(url, timeout=10):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "summa-compare/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except Exception as e:
        return None


def wiki_lead(title):
    body = fetch(WIKI + urllib.parse.quote(title.replace(" ", "_")))
    if not body:
        return None
    try:
        return json.loads(body).get("extract")
    except Exception:
        return None


def wiktionary_sense(word):
    w = word.lower()
    if len(w) < 2:
        return None
    body = fetch(KAIKKI.format(a=w[0], ab=w[:2], word=urllib.parse.quote(w)))
    if not body:
        return None
    for line in body.splitlines():
        try:
            e = json.loads(line)
        except Exception:
            continue
        for sense in e.get("senses", []):
            gl = sense.get("glosses")
            if gl:
                return gl[0]
    return None


def load_gt_titles():
    """Repo ground truth: phrase -> the Wikipedia article it resolves to."""
    out = {}
    gt = REPO / "tools" / "ground_truth" / "moby_dick.json"
    if gt.exists():
        for e in json.loads(gt.read_text()):
            if e.get("phrase") and e.get("expected"):
                out[norm(e["phrase"])] = e["expected"]
    return out


def wrap(text, width, indent):
    words, lines, cur = text.split(), [], ""
    for w in words:
        if len(cur) + len(w) + 1 > width:
            lines.append(cur)
            cur = w
        else:
            cur = f"{cur} {w}".strip()
    if cur:
        lines.append(cur)
    return f"\n{' ' * indent}".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--worddumb", type=Path, required=True)
    ap.add_argument("--summa", type=Path, required=True)
    ap.add_argument("--offline", action="store_true",
                    help="skip network, use repo ground-truth article titles")
    args = ap.parse_args()

    wd = json.loads(args.worddumb.read_text())
    su = json.loads(args.summa.read_text())

    ents = {norm(e["text"]): e["text"] for e in wd["xray"]}
    ww = {norm(e["lemma"]) for e in wd["word_wise"]}
    gt = load_gt_titles()

    shared = []
    for a in su["annotations"]:
        n = norm(a["anchor"])
        if n in ents:
            shared.append((a, "xray", ents[n]))
        elif n in ww:
            shared.append((a, "wordwise", n))

    print("=" * 78)
    print(f"{su['source']}")
    print(f"Anchors both tools select: {len(shared)}")
    if args.offline:
        print("OFFLINE -- WordDumb column shows the article it resolves to,")
        print("not the prose it would print. Run without --offline for that.")
    print("=" * 78)

    for a, src, key in shared:
        print()
        print(f"ANCHOR  {a['anchor']}   [{a['type']}]")
        if src == "xray":
            if args.offline:
                wdnote = f"(X-Ray) -> Wikipedia article: {gt.get(norm(a['anchor']), key)}"
            else:
                lead = wiki_lead(gt.get(norm(a["anchor"]), key))
                wdnote = f"(X-Ray) {lead}" if lead else "(X-Ray) no article found"
        else:
            if args.offline:
                wdnote = f"(Word Wise) -> Wiktionary sense of '{key}'"
            else:
                sense = wiktionary_sense(key)
                wdnote = f"(Word Wise) {sense}" if sense else "(Word Wise) no sense found"
        print(f"  WORDDUMB  {wrap(wdnote, 62, 12)}")
        print(f"  SUMMA     {wrap(a['note'], 62, 12)}")


if __name__ == "__main__":
    main()
