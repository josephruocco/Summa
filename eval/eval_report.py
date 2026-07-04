#!/usr/bin/env python3
"""Phase 5 verify: diff a pipeline run's annotations against eval/expected_ch42.md
and print a catch/miss table plus cost/latency. Only meaningful for moby_dick_ch42 runs
(expected_ch42.md is hand-spec'd for that fixture's golden paragraph only).

Usage:
    python3 -m eval.eval_report <run.json> [baseline_run.json]
"""

import json
import re
import sys
from pathlib import Path


def parse_expected_table(md_path: Path) -> list[dict]:
    text = md_path.read_text(encoding="utf-8")
    rows = []
    in_table = False
    for line in text.splitlines():
        if line.strip().startswith("| anchor"):
            in_table = True
            continue
        if in_table:
            if not line.strip().startswith("|"):
                break
            if line.strip().startswith("|---"):
                continue
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) < 3:
                continue
            anchor = cells[0].strip("`")
            ann_type = cells[1]
            note = cells[2]
            rows.append({"anchor": anchor, "type": ann_type, "note": note})
    return rows


def _norm(s: str) -> str:
    return re.sub(r"\s+", " ", s.lower()).strip()


def catch_rate(run_annotations: list[dict], expected: list[dict]) -> tuple[list, list]:
    caught, missed = [], []
    run_anchors_norm = [_norm(a["anchor"]) for a in run_annotations]
    for exp in expected:
        exp_norm = _norm(exp["anchor"])
        hit = any(exp_norm in ra or ra in exp_norm for ra in run_anchors_norm if ra)
        (caught if hit else missed).append(exp)
    return caught, missed


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        raise SystemExit(1)

    run_path = Path(sys.argv[1])
    run = json.loads(run_path.read_text(encoding="utf-8"))

    print(f"=== {run_path.name} ===")
    print(f"mode={run['mode']} model={run['model']} fixture={run.get('fixture', '?')}")
    print(f"annotations={len(run['annotations'])} rejected={len(run.get('rejected', []))}")
    print(f"cost=${run['cost_usd']:.4f} latency={run['latency_ms']:.0f}ms usage={run['usage']}")
    if run.get("critique_delta"):
        d = run["critique_delta"]
        print(f"critique delta: +{len(d['added'])} added, -{len(d['removed'])} removed")

    if run.get("fixture") == "moby_dick_ch42":
        expected_path = Path(__file__).parent / "expected_ch42.md"
        expected = parse_expected_table(expected_path)
        caught, missed = catch_rate(run["annotations"], expected)
        pct = 100 * len(caught) / len(expected) if expected else 0.0
        print(f"\ngolden-paragraph catch rate: {len(caught)}/{len(expected)} ({pct:.0f}%)")
        for c in caught:
            print(f"  CAUGHT  {c['anchor']!r}")
        for m in missed:
            print(f"  MISSED  {m['anchor']!r}")

        anchor_mismatches = [a for a in run["annotations"] if not a.get("anchor")]
        print(f"anchor mismatches in accepted set: {len(anchor_mismatches)} (should be 0 -- schema.py already filters these)")

    if len(sys.argv) > 2:
        baseline_path = Path(sys.argv[2])
        baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
        print(f"\n=== vs baseline ({baseline_path.name}) ===")
        print(f"baseline: annotations={len(baseline['annotations'])} cost=${baseline['cost_usd']:.4f}")
        print(f"premium:  annotations={len(run['annotations'])} cost=${run['cost_usd']:.4f}")


if __name__ == "__main__":
    main()
