#!/usr/bin/env python3
"""
Evaluate annotation-type output against a small labeled gold set.

Usage:
  cd /Users/josephruocco/Downloads/Summa-main/GutenbergTest
  swift run gutenberg-test 2701 2>&1 | python3 ../tools/eval_annotation_types.py

  Or with TSV:
  python3 tools/eval_annotation_types.py --tsv path/to/output.tsv
"""

import argparse
import csv
import json
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
GOLD_PATH = SCRIPT_DIR / "gold_sets" / "moby_dick_annotation_types.json"


def load_gold():
    data = json.loads(GOLD_PATH.read_text())
    gold = {}
    for entry in data:
        key = (entry["bookId"], entry["phrase"].lower())
        gold[key] = entry
    return gold


def parse_pipeline_log(lines):
    rows = []
    current_book_id = None
    for line in lines:
        m = re.match(r"── .+\(ID (\d+)\)", line.strip())
        if m:
            current_book_id = int(m.group(1))
            continue
        m = re.match(r"\s+([✓✗~])\s+(.+?)\s+→\s+(\w+)\s*(?:\[(.+?)\])?\s*(\d+\.\d+)?", line)
        if m and current_book_id is not None:
            _, phrase, status_raw, title, score = m.groups()
            annotation_type = "suppress"
            if status_raw == "ok":
                annotation_type = "wikipedia"
            elif status_raw == "gloss":
                annotation_type = "gloss"
            rows.append({
                "bookId": current_book_id,
                "phrase": phrase.strip(),
                "status": status_raw,
                "annotationType": annotation_type,
                "wikiTitle": (title or "").strip(),
                "score": float(score) if score else None,
                "gloss": "",
            })
    return rows


def parse_tsv(lines):
    rows = []
    reader = csv.DictReader(lines, delimiter="\t")
    for row in reader:
        rows.append({
            "bookId": int(row.get("bookID", 0)),
            "phrase": row.get("phrase", "").strip(),
            "status": row.get("status", "").strip(),
            "annotationType": row.get("annotationType", "").strip(),
            "wikiTitle": row.get("wikiTitle", "").strip(),
            "score": float(row["score"]) if row.get("score") else None,
            "gloss": row.get("gloss", "").strip(),
        })
    return rows


def title_matches(actual, expected):
    a = actual.lower().strip()
    e = expected.lower().strip()
    return a == e or e in a or a in e


def evaluate(rows, gold):
    exact = []
    wrong_type = []
    wrong_title = []
    missing = []

    seen = set()
    for row in rows:
        key = (row["bookId"], row["phrase"].lower())
        if key not in gold:
            continue
        seen.add(key)
        entry = gold[key]
        expected_type = entry["annotation_type"]
        actual_type = row["annotationType"] or ("wikipedia" if row["status"] == "ok" else row["status"])

        if actual_type != expected_type:
            wrong_type.append((row, entry))
            continue

        if expected_type == "wikipedia":
            expected_title = entry.get("expected", "")
            if title_matches(row["wikiTitle"], expected_title):
                exact.append((row, entry))
            else:
                wrong_title.append((row, entry))
        elif expected_type == "gloss":
            if row.get("gloss"):
                exact.append((row, entry))
            else:
                exact.append((row, entry))
        else:
            exact.append((row, entry))

    for key, entry in gold.items():
        if key not in seen:
            missing.append(({"bookId": key[0], "phrase": entry["phrase"], "annotationType": "missing", "wikiTitle": ""}, entry))

    return exact, wrong_type, wrong_title, missing


def print_report(exact, wrong_type, wrong_title, missing):
    total = len(exact) + len(wrong_type) + len(wrong_title) + len(missing)
    print(f"\n{'='*60}")
    print(f"  ANNOTATION TYPE EVAL  ({total} gold cases)")
    print(f"{'='*60}")
    print(f"  Exact / acceptable : {len(exact):3d}")
    print(f"  Wrong type         : {len(wrong_type):3d}")
    print(f"  Wrong title        : {len(wrong_title):3d}")
    print(f"  Missing            : {len(missing):3d}")
    print(f"{'='*60}\n")

    if wrong_type:
        print("WRONG TYPE:")
        for row, entry in wrong_type:
            print(f"  [{row['bookId']}] {entry['phrase']!r:35} → got {row['annotationType']!r}, expected {entry['annotation_type']!r}")
        print()

    if wrong_title:
        print("WRONG WIKIPEDIA TITLE:")
        for row, entry in wrong_title:
            print(f"  [{row['bookId']}] {entry['phrase']!r:35} → got {row['wikiTitle']!r}, expected {entry['expected']!r}")
        print()

    if missing:
        print("MISSING:")
        for row, entry in missing:
            print(f"  [{row['bookId']}] {entry['phrase']!r:35} → no pipeline output")
        print()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tsv")
    args = parser.parse_args()

    gold = load_gold()
    if args.tsv:
        with open(args.tsv) as f:
            rows = parse_tsv(f)
    else:
        raw = sys.stdin.read()
        lines = raw.splitlines()
        if lines and "\t" in lines[0] and lines[0].startswith("bookID"):
            rows = parse_tsv(lines)
        else:
            rows = parse_pipeline_log(lines)

    exact, wrong_type, wrong_title, missing = evaluate(rows, gold)
    print_report(exact, wrong_type, wrong_title, missing)


if __name__ == "__main__":
    main()
