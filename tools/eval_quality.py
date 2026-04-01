#!/usr/bin/env python3
"""
Evaluate pipeline quality against hand-curated ground truth.

Usage:
  cd /Users/josephruocco/Downloads/Summa-main/GutenbergTest
  swift run gutenberg-test 2>&1 | python3 ../tools/eval_quality.py

  Or with a saved TSV:
  python3 tools/eval_quality.py --tsv path/to/output.tsv
"""

import json
import sys
import csv
import re
import os
import argparse
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
GT_DIR     = SCRIPT_DIR / "ground_truth"
LEGACY_GT_PATH = SCRIPT_DIR / "ground_truth.json"


def load_ground_truth():
    files = []
    if GT_DIR.is_dir():
        files = sorted(GT_DIR.glob("*.json"))
    elif LEGACY_GT_PATH.exists():
        files = [LEGACY_GT_PATH]
    else:
        raise FileNotFoundError(f"No ground truth found in {GT_DIR} or {LEGACY_GT_PATH}")

    gt = {}
    loaded_files = []
    for path in files:
        data = json.loads(path.read_text())
        loaded_files.append(path.name)
        for entry in data:
            if "_comment" in entry:
                continue
            key = (entry["bookId"], entry["phrase"].lower())
            if key in gt:
                raise ValueError(f"Duplicate ground truth entry for {key} in {path}")
            gt[key] = entry
    return gt, loaded_files


def title_matches(actual: str, expected: str) -> bool:
    """True if titles are close enough (case-insensitive substring match)."""
    a = actual.lower().strip()
    e = expected.lower().strip()
    return a == e or e in a or a in e


def parse_pipeline_log(lines):
    """
    Parse the human-readable pipeline log (stderr/stdout mix) into rows.
    Returns list of dicts: bookId, phrase, status, wikiTitle, score
    """
    rows = []
    current_book_id = None
    for line in lines:
        # Book header: ── Hunger (ID 8387)
        m = re.match(r"── .+\(ID (\d+)\)", line.strip())
        if m:
            current_book_id = int(m.group(1))
            continue
        # Result line: ✓/✗/~ phrase → status [title] score
        m = re.match(r"\s+([✓✗~])\s+(.+?)\s+→\s+(\w+)\s*(?:\[(.+?)\])?\s*(\d+\.\d+)?", line)
        if m and current_book_id is not None:
            icon, phrase, status_raw, title, score = m.groups()
            rows.append({
                "bookId":    current_book_id,
                "phrase":    phrase.strip(),
                "status":    status_raw,
                "wikiTitle": (title or "").strip(),
                "score":     float(score) if score else None,
            })
    return rows


def parse_tsv(lines):
    """Parse TSV output (non-demo mode): bookID bookTitle phrase kind status wikiTitle score ..."""
    rows = []
    reader = csv.DictReader(lines, delimiter="\t")
    for row in reader:
        status = row.get("status") or ""
        phrase = row.get("phrase") or ""
        title  = row.get("wikiTitle") or ""
        score  = row.get("score") or ""
        book_id = row.get("bookID") or "0"
        try:
            rows.append({
                "bookId":    int(book_id),
                "phrase":    phrase.strip(),
                "status":    status.strip(),
                "wikiTitle": title.strip(),
                "score":     float(score) if score.strip() else None,
            })
        except (ValueError, AttributeError):
            continue  # skip malformed rows
    return rows


def evaluate(rows, gt):
    tp = []          # correct annotation, right title
    fp = []          # annotated but should be suppressed
    fn = []          # should be annotated but wasn't
    tn = []          # correctly not annotated
    wrong_title = [] # annotated but wrong title

    seen_keys = set()
    for row in rows:
        key = (row["bookId"], row["phrase"].lower())
        if key not in gt:
            continue
        seen_keys.add(key)
        entry   = gt[key]
        verdict = entry["verdict"]
        expected = entry.get("expected") or ""
        status   = row["status"]
        title    = row["wikiTitle"]
        score    = row["score"]

        if verdict == "ok":
            if status == "ok":
                if title_matches(title, expected):
                    tp.append((row, entry))
                else:
                    wrong_title.append((row, entry))
            else:
                fn.append((row, entry))

        elif verdict == "gloss":
            if status == "gloss":
                tp.append((row, entry))
            elif status in ("notFound", "suppressed", "error", ""):
                fn.append((row, entry))
            else:
                fp.append((row, entry))

        elif verdict == "suppress":
            if status in ("notFound", "suppressed", "error", ""):
                tn.append((row, entry))
            else:
                fp.append((row, entry))

    # Ground truth entries never seen in the pipeline output → false negatives
    for key, entry in gt.items():
        if key not in seen_keys and entry["verdict"] == "ok":
            fn.append(({"bookId": key[0], "phrase": key[1], "status": "not_run",
                        "wikiTitle": "", "score": None}, entry))

    return tp, fp, fn, tn, wrong_title


def print_report(tp, fp, fn, tn, wrong_title):
    n_tp = len(tp)
    n_fp = len(fp)
    n_fn = len(fn)
    n_tn = len(tn)
    n_wt = len(wrong_title)

    total_positive = n_tp + n_fp + n_wt  # everything we annotated that's in GT
    total_gt_ok    = n_tp + n_fn + n_wt  # everything that SHOULD be annotated

    precision = n_tp / total_positive if total_positive > 0 else 0.0
    recall    = n_tp / total_gt_ok    if total_gt_ok    > 0 else 0.0
    f1        = (2 * precision * recall / (precision + recall)) if (precision + recall) > 0 else 0.0

    print(f"\n{'='*60}")
    print(f"  GROUND TRUTH EVAL  ({n_tp+n_fp+n_fn+n_tn+n_wt} test cases matched)")
    print(f"{'='*60}")
    print(f"  TP  (correct annotation, right title) : {n_tp:3d}")
    print(f"  FP  (annotated, should be suppressed) : {n_fp:3d}")
    print(f"  FN  (missed — should be annotated)    : {n_fn:3d}")
    print(f"  TN  (correctly suppressed/notFound)   : {n_tn:3d}")
    print(f"  WT  (annotated, but wrong title)       : {n_wt:3d}")
    print(f"{'─'*60}")
    print(f"  Precision : {precision:.1%}  (of what we annotate, how much is right)")
    print(f"  Recall    : {recall:.1%}  (of what should be found, how much we find)")
    print(f"  F1        : {f1:.1%}")
    print(f"{'='*60}\n")

    if fp:
        print("FALSE POSITIVES (annotated, should be suppressed):")
        for row, entry in sorted(fp, key=lambda x: x[0]["bookId"]):
            reason = entry.get("_reason", "")
            score_str = f"{row['score']:.2f}" if row["score"] is not None else "n/a"
            print(f"  [{row['bookId']}] {entry['phrase']!r:35} → {row['wikiTitle']!r} ({score_str})")
            if reason: print(f"    reason: {reason}")
        print()

    if wrong_title:
        print("WRONG TITLE (annotated but incorrect article):")
        for row, entry in sorted(wrong_title, key=lambda x: x[0]["bookId"]):
            print(f"  [{row['bookId']}] {entry['phrase']!r:35} → got {row['wikiTitle']!r}, expected {entry['expected']!r}")
        print()

    if fn:
        print("FALSE NEGATIVES (should be annotated but wasn't):")
        for row, entry in sorted(fn, key=lambda x: x[0]["bookId"]):
            print(f"  [{row['bookId']}] {entry['phrase']!r:35} → {row['status']}  (expected {entry['expected']!r})")
        print()

    if tp:
        print("TRUE POSITIVES:")
        for row, entry in sorted(tp, key=lambda x: x[0]["bookId"]):
            score_str = f"{row['score']:.2f}" if row["score"] is not None else "n/a"
            print(f"  [{row['bookId']}] {entry['phrase']!r:35} → {row['wikiTitle']!r} ({score_str}) ✓")
        print()


def main():
    parser = argparse.ArgumentParser(description="Eval pipeline quality vs ground truth")
    parser.add_argument("--tsv", help="Read from TSV file instead of stdin log")
    parser.add_argument("--book-id", type=int, help="Restrict eval to a single book ID")
    args = parser.parse_args()

    gt, loaded_files = load_ground_truth()
    source_label = GT_DIR if GT_DIR.is_dir() else LEGACY_GT_PATH
    print(f"Loaded {len(gt)} ground truth entries from {source_label} ({len(loaded_files)} files)")

    if args.tsv:
        with open(args.tsv) as f:
            rows = parse_tsv(f)
        print(f"Read {len(rows)} TSV rows from {args.tsv}")
    else:
        raw = sys.stdin.read()
        # Try to detect format: TSV has tab-separated header line
        lines = raw.splitlines()
        if lines and "\t" in lines[0] and lines[0].startswith("bookID"):
            rows = parse_tsv(lines)
            print(f"Parsed {len(rows)} TSV rows from stdin")
        else:
            rows = parse_pipeline_log(lines)
            print(f"Parsed {len(rows)} log rows from stdin")

    if args.book_id is not None:
        rows = [row for row in rows if row["bookId"] == args.book_id]
        gt = {k: v for k, v in gt.items() if k[0] == args.book_id}

    tp, fp, fn, tn, wrong_title = evaluate(rows, gt)
    print_report(tp, fp, fn, tn, wrong_title)


if __name__ == "__main__":
    main()
