#!/usr/bin/env python3
"""
Score a passage-level annotation run against a hand-spec'd golden paragraph.

Usage:
  python3 tools/eval_golden_paragraph.py --run tools/runs/md_ch42_premium_<timestamp>.json

The run file is expected to contain a "paragraphs" list where each entry has
"passage" and "annotations" (list of {anchor, type, note}) -- see
PremiumAnnotator's dump format in GutenbergTest. This script finds the
paragraph matching the gold set's passage and scores it.
"""

import argparse
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
DEFAULT_GOLD = SCRIPT_DIR / "gold_sets" / "moby_dick_ch42_golden_paragraph.json"


def load_gold(path: Path) -> dict:
    return json.loads(path.read_text())


def find_scored_paragraph(run: dict, gold_passage: str) -> dict | None:
    gold_norm = " ".join(gold_passage.split())
    for para in run.get("paragraphs", []):
        if " ".join(para.get("passage", "").split()) == gold_norm:
            return para
    return None


def anchor_overlaps(a: str, b: str) -> bool:
    a, b = a.lower().strip(), b.lower().strip()
    return a == b or a in b or b in a


def score(gold: dict, actual_annotations: list[dict], passage: str) -> dict:
    expected = gold["expected_annotations"]
    caught, missed = [], []
    matched_actual_idx = set()

    for exp in expected:
        hit = None
        for i, act in enumerate(actual_annotations):
            if i in matched_actual_idx:
                continue
            if anchor_overlaps(exp["anchor"], act.get("anchor", "")):
                hit = (i, act)
                break
        if hit and hit[1].get("type") == exp["annotation_type"]:
            matched_actual_idx.add(hit[0])
            caught.append((exp, hit[1]))
        elif hit:
            matched_actual_idx.add(hit[0])
            missed.append((exp, hit[1], "wrong_type"))
        else:
            missed.append((exp, None, "not_found"))

    extra = [act for i, act in enumerate(actual_annotations) if i not in matched_actual_idx]

    anchor_mismatches = [
        act for act in actual_annotations
        if act.get("anchor", "") not in passage
    ]

    return {
        "caught": caught,
        "missed": missed,
        "extra": extra,
        "anchor_mismatches": anchor_mismatches,
        "recall": len(caught) / len(expected) if expected else 0.0,
    }


def print_report(result: dict) -> None:
    n_exp = len(result["caught"]) + len(result["missed"])
    print(f"\n{'='*60}")
    print("  GOLDEN PARAGRAPH EVAL (Moby-Dick Ch. 42)")
    print(f"{'='*60}")
    print(f"  Caught  : {len(result['caught'])}/{n_exp}")
    print(f"  Missed  : {len(result['missed'])}")
    print(f"  Extra   : {len(result['extra'])} (not in gold set -- may be valid, just unscored)")
    print(f"  Anchor mismatches (not verbatim in passage): {len(result['anchor_mismatches'])}")
    print(f"  Recall  : {result['recall']:.1%}")
    print(f"{'-'*60}")

    if result["caught"]:
        print("\nCAUGHT:")
        for exp, act in result["caught"]:
            print(f"  ✓ [{exp['annotation_type']}] {exp['anchor']!r}")

    if result["missed"]:
        print("\nMISSED:")
        for exp, act, reason in result["missed"]:
            if reason == "wrong_type":
                print(f"  ✗ [{exp['annotation_type']}] {exp['anchor']!r} -- got type {act['type']!r} instead")
            else:
                print(f"  ✗ [{exp['annotation_type']}] {exp['anchor']!r} -- not produced")

    if result["anchor_mismatches"]:
        print("\nANCHOR MISMATCHES (should never happen -- repair step failed):")
        for act in result["anchor_mismatches"]:
            print(f"  ! {act.get('anchor')!r}")

    print()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", required=True, help="Path to a premium-mode JSON run dump")
    parser.add_argument("--gold", default=str(DEFAULT_GOLD))
    args = parser.parse_args()

    gold = load_gold(Path(args.gold))
    run = json.loads(Path(args.run).read_text())

    para = find_scored_paragraph(run, gold["passage"])
    if para is None:
        print(f"Golden paragraph not found in run file {args.run}", file=sys.stderr)
        print("(paragraph text must match the gold set exactly)", file=sys.stderr)
        sys.exit(1)

    result = score(gold, para.get("annotations", []), para["passage"])
    print_report(result)


if __name__ == "__main__":
    main()
