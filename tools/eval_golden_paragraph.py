#!/usr/bin/env python3
"""
Score a passage-level annotation run against hand-spec'd golden paragraphs.

Usage:
  python3 tools/eval_golden_paragraph.py --run tools/runs/md_ch42_premium_<timestamp>.json

The run file is expected to contain a "paragraphs" list where each entry has
"passage" and "annotations" (list of {anchor, type, note}); see
PremiumAnnotator's dump format in GutenbergTest. The gold file has its own
"paragraphs" list (label, passage, expected_annotations); each gold passage
is matched to a run paragraph by exact text and scored independently, then
totals are reported across all of them.
"""

import argparse
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
DEFAULT_GOLD = SCRIPT_DIR / "gold_sets" / "moby_dick_ch42_golden_paragraph.json"


def load_gold(path: Path) -> dict:
    return json.loads(path.read_text())


def find_run_paragraph(run: dict, gold_passage: str) -> dict | None:
    gold_norm = " ".join(gold_passage.split())
    for para in run.get("paragraphs", []):
        if " ".join(para.get("passage", "").split()) == gold_norm:
            return para
    return None


def anchor_overlaps(a: str, b: str) -> bool:
    a, b = a.lower().strip(), b.lower().strip()
    return a == b or a in b or b in a


def score_paragraph(expected: list[dict], actual_annotations: list[dict], passage: str) -> dict:
    caught, wrong_type, missed = [], [], []
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
            wrong_type.append((exp, hit[1]))
        else:
            missed.append(exp)

    extra = [act for i, act in enumerate(actual_annotations) if i not in matched_actual_idx]
    anchor_mismatches = [act for act in actual_annotations if act.get("anchor", "") not in passage]

    return {
        "caught": caught,
        "wrong_type": wrong_type,
        "missed": missed,
        "extra": extra,
        "anchor_mismatches": anchor_mismatches,
    }


def print_report(label: str, result: dict) -> None:
    n_exp = len(result["caught"]) + len(result["wrong_type"]) + len(result["missed"])
    strict = len(result["caught"])
    loose = len(result["caught"]) + len(result["wrong_type"])

    print(f"\n=== {label} ({n_exp} expected) ===")
    print(f"  Strict recall (span + type): {strict}/{n_exp}  ({strict/n_exp:.0%})" if n_exp else "  (no expected annotations)")
    print(f"  Loose recall (span only):    {loose}/{n_exp}  ({loose/n_exp:.0%})" if n_exp else "")
    if result["anchor_mismatches"]:
        print(f"  Anchor mismatches: {len(result['anchor_mismatches'])}")

    if result["caught"]:
        print("  Caught:")
        for exp, act in result["caught"]:
            print(f"    + [{exp['annotation_type']}] {exp['anchor']!r}")
    if result["wrong_type"]:
        print("  Caught span, wrong type:")
        for exp, act in result["wrong_type"]:
            print(f"    ~ [{exp['annotation_type']}] {exp['anchor']!r}: got {act['type']!r}")
    if result["missed"]:
        print("  Missed entirely:")
        for exp in result["missed"]:
            print(f"    - [{exp['annotation_type']}] {exp['anchor']!r}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", required=True, help="Path to a premium-mode JSON run dump")
    parser.add_argument("--gold", default=str(DEFAULT_GOLD))
    args = parser.parse_args()

    gold = load_gold(Path(args.gold))
    run = json.loads(Path(args.run).read_text())

    print(f"\n{'='*60}")
    print("  GOLDEN PARAGRAPH EVAL (Moby-Dick Ch. 42)")
    print(f"{'='*60}")

    totals = {"caught": 0, "wrong_type": 0, "missed": 0}
    for gp in gold["paragraphs"]:
        run_para = find_run_paragraph(run, gp["passage"])
        if run_para is None:
            print(f"\n=== {gp['label']} ===\n  NOT FOUND in run file (paragraph text must match exactly)", file=sys.stderr)
            continue
        result = score_paragraph(gp["expected_annotations"], run_para.get("annotations", []), run_para["passage"])
        print_report(gp["label"], result)
        totals["caught"] += len(result["caught"])
        totals["wrong_type"] += len(result["wrong_type"])
        totals["missed"] += len(result["missed"])

    n_exp = totals["caught"] + totals["wrong_type"] + totals["missed"]
    strict = totals["caught"]
    loose = totals["caught"] + totals["wrong_type"]
    print(f"\n{'='*60}")
    print(f"  TOTAL: {n_exp} expected annotations across {len(gold['paragraphs'])} paragraphs")
    print(f"  Strict recall: {strict}/{n_exp}  ({strict/n_exp:.0%})" if n_exp else "  (no expected annotations)")
    print(f"  Loose recall:  {loose}/{n_exp}  ({loose/n_exp:.0%})" if n_exp else "")
    print(f"{'='*60}\n")


if __name__ == "__main__":
    main()
