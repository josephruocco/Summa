#!/usr/bin/env python3
"""CLI entrypoint: run the annotation pipeline on one fixture in one mode,
dump a timestamped JSON result. Invoked by eval/run.sh.

Usage:
    python3 -m eval.run_pipeline <fixture_name> <legacy|premium> [output_dir]

Requires ANTHROPIC_API_KEY in the environment (see eval/README.md).
"""

import datetime
import json
import os
import sys

FIXTURES_DIR = os.path.join(os.path.dirname(__file__), "fixtures")


def load_fixture(name: str) -> tuple[str, dict]:
    with open(os.path.join(FIXTURES_DIR, "book_context.json"), "r", encoding="utf-8") as f:
        all_ctx = json.load(f)
    if name not in all_ctx:
        raise SystemExit(f"Unknown fixture {name!r}. Known: {list(all_ctx)}")

    text_path = os.path.join(FIXTURES_DIR, f"{name}.txt")
    if name == "moby_dick_ch42":
        text_path = os.path.join(FIXTURES_DIR, "moby_dick_ch42.txt")
    elif name == "plain_call_of_wild":
        text_path = os.path.join(FIXTURES_DIR, "plain_call_of_wild.txt")
    elif name == "bible_adjacent_utc":
        text_path = os.path.join(FIXTURES_DIR, "bible_adjacent_utc.txt")

    with open(text_path, "r", encoding="utf-8") as f:
        text = f.read()
    return text, all_ctx[name]


def main() -> None:
    if len(sys.argv) < 3:
        print(__doc__)
        raise SystemExit(1)

    fixture_name, mode = sys.argv[1], sys.argv[2]
    output_dir = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.dirname(__file__), mode if mode == "baseline" else mode)
    if mode not in ("legacy", "premium"):
        raise SystemExit(f"mode must be 'legacy' or 'premium', got {mode!r}")

    # Set env var so config.py (imported by annotate.py) picks the right models/thresholds.
    os.environ["ANNOTATION_QUALITY_MODE"] = mode

    from . import annotate as annotate_mod  # deferred: reads ANNOTATION_QUALITY_MODE at import time

    chapter_text, book_ctx = load_fixture(fixture_name)
    result = annotate_mod.annotate(chapter_text, book_ctx, mode)
    result["fixture"] = fixture_name
    result["timestamp"] = datetime.datetime.now(datetime.timezone.utc).isoformat()

    os.makedirs(output_dir, exist_ok=True)
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = os.path.join(output_dir, f"{fixture_name}_{mode}_{ts}.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)

    print(f"Wrote {out_path}")
    print(f"  annotations={len(result['annotations'])} rejected={len(result.get('rejected', []))} "
          f"cost=${result['cost_usd']:.4f} latency={result['latency_ms']:.0f}ms")


if __name__ == "__main__":
    main()
