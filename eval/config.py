"""Config for the premium annotation pipeline.

ANNOTATION_QUALITY_MODE selects between:
  - "legacy":  cheap model, single-pass, paragraph-only context (the failure mode
               this spec fixes: "ChatGPT with a UI").
  - "premium": frontier model, full-chapter context (+ book digest for long
               chapters), editorial-taxonomy prompt, two-pass critique loop.

This pipeline is intentionally standalone (see eval/README.md) — it does not
touch the shipped app's Lookups/Wikipedia.swift term-lookup engine or the
OverlayController UI. It exists to measure and improve annotation *quality*
for a new, richer annotation type (editorial prose notes), independent of the
app's live Wikipedia/dictionary term-linking feature.
"""

import os

ANNOTATION_QUALITY_MODE = os.environ.get("ANNOTATION_QUALITY_MODE", "legacy")

# Model IDs are config values, not hardcoded literals in the pipeline logic.
# The spec named "claude-sonnet-4-6" for premium mode; that model has since
# been superseded, so premium defaults to the current frontier balanced model
# instead. Override either via env var without touching code.
MODEL_PREMIUM = os.environ.get("ANNOTATION_MODEL_PREMIUM", "claude-sonnet-5")
MODEL_LEGACY = os.environ.get("ANNOTATION_MODEL_LEGACY", "claude-haiku-4-5")

# Full-chapter-in-prompt threshold (spec: "chapter <= ~20k tokens"). Above
# this, Phase 1's sliding-window + book-digest path is used instead.
FULL_CHAPTER_TOKEN_THRESHOLD = 20_000

# Two-pass critique loop only runs in premium mode (spec Phase 4).
CRITIQUE_LOOP_ENABLED = ANNOTATION_QUALITY_MODE == "premium"

# Pricing table ($ per million tokens), used for cost logging.
# Source: Claude API pricing as of 2026-07 (claude-api skill cache, 2026-06-24).
PRICING_PER_MTOK = {
    "claude-sonnet-5": {"input": 3.00, "output": 15.00},
    "claude-haiku-4-5": {"input": 1.00, "output": 5.00},
    "claude-opus-4-8": {"input": 5.00, "output": 25.00},
}


def model_for_mode(mode: str) -> str:
    return MODEL_PREMIUM if mode == "premium" else MODEL_LEGACY


def estimate_cost(model: str, input_tokens: int, output_tokens: int) -> float:
    """Rough $ estimate from token usage. Unknown models price at 0 (log a warning upstream)."""
    prices = PRICING_PER_MTOK.get(model)
    if not prices:
        return 0.0
    return (input_tokens / 1_000_000) * prices["input"] + (output_tokens / 1_000_000) * prices["output"]
