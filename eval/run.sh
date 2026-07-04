#!/usr/bin/env bash
# Runs the annotation pipeline on every fixture in both legacy and premium mode,
# writing timestamped JSON to eval/baseline/ and eval/premium/ so runs can be
# diffed across commits.
#
# Requires: ANTHROPIC_API_KEY in the environment.
#
# Usage:
#   ./eval/run.sh                     # all fixtures, both modes
#   ./eval/run.sh moby_dick_ch42      # one fixture, both modes
#   ./eval/run.sh moby_dick_ch42 premium   # one fixture, one mode

set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ANTHROPIC_API_KEY is not set. See eval/README.md." >&2
  exit 1
fi

FIXTURES=("moby_dick_ch42" "plain_call_of_wild" "bible_adjacent_utc")
MODES=("legacy" "premium")

if [ -n "${1:-}" ]; then
  FIXTURES=("$1")
fi
if [ -n "${2:-}" ]; then
  MODES=("$2")
fi

for fixture in "${FIXTURES[@]}"; do
  for mode in "${MODES[@]}"; do
    out_dir="eval/baseline"
    [ "$mode" = "premium" ] && out_dir="eval/premium"
    echo "=== $fixture / $mode ==="
    python3 -m eval.run_pipeline "$fixture" "$mode" "$out_dir"
  done
done
