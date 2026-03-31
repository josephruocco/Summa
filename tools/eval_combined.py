#!/usr/bin/env python3
"""
Run both the legacy title-link eval and the newer annotation-type eval on the same input.

Usage:
  cd /Users/josephruocco/Downloads/Summa-main/GutenbergTest
  swift run gutenberg-test 2701 2>&1 | python3 ../tools/eval_combined.py
"""

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
TITLE_EVAL = SCRIPT_DIR / "eval_quality.py"
TYPE_EVAL = SCRIPT_DIR / "eval_annotation_types.py"


def run_eval(script_path: Path, raw: str) -> str:
    proc = subprocess.run(
        [sys.executable, str(script_path)],
        input=raw,
        text=True,
        capture_output=True,
        check=False,
    )
    output = proc.stdout
    if proc.stderr:
        output += ("\n" if output else "") + proc.stderr
    return output


def main():
    parser = argparse.ArgumentParser(description="Run legacy and annotation-type evals together")
    parser.add_argument("--tsv", help="Read from TSV file instead of stdin")
    args = parser.parse_args()

    if args.tsv:
        raw = Path(args.tsv).read_text()
    else:
        raw = sys.stdin.read()

    print("### Title-Link Eval ###")
    print(run_eval(TITLE_EVAL, raw).rstrip())
    print("\n### Annotation-Type Eval ###")
    print(run_eval(TYPE_EVAL, raw).rstrip())


if __name__ == "__main__":
    main()
