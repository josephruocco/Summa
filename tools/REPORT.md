# Annotation quality fix: Phase 5 report

Run scored: `tools/runs/md_ch42_premium_1783720483.json` (Moby Dick, Chapter 42, premium mode, claude sonnet 4.6, generated 2026 07 10)
Baseline compared: `tools/baseline/md_ch42_legacy.tsv` / `.log` (same chapter, legacy per candidate pipeline)
Gold set: `tools/gold_sets/moby_dick_ch42_golden_paragraph.json`

## Definition of done: not met on this run

The spec's target was catching at least 70% of the hand spec'd expected annotations for the golden paragraph, with zero anchor mismatches. Zero anchor mismatches is met. Recall is not.

## Golden paragraph score

Paragraph scored: the "White Steed of the Prairies" paragraph (Chapter 42's `<p>` element beginning "Most famous in our Western annals...").

| Expected anchor | Expected type | Result |
|---|---|---|
| elected Xerxes | allusion | caught, exact type match |
| the Alleghanies | philology | missed entirely |
| Adam walked majestic as a god | allusion | missed entirely |
| like an Ohio | context | caught span, model labeled it philology instead |
| commanding worship...nameless terror | interpretation | caught span, model labeled it callback instead |

Strict recall (exact anchor and exact type): 1/5, 20%.
Loose recall (anchor caught under any of the five types): 3/5, 60%.

The gap between strict and loose is mostly the taxonomy's soft category boundaries, not missed content. "Like an Ohio" genuinely is both a geographic fact (context) and a word doing double duty as a common noun (philology); the model's callback reading of "commanding worship...terror" (an explicit echo of the albatross passage's language) is arguably a better catch than the interpretation label I hand spec'd. Two misses are real gaps: "the Alleghanies" and the Adam allusion were never touched by any annotation.

One data point worth flagging: the legacy baseline caught "the Alleghanies" (resolved to the Allegheny Mountains Wikipedia article) and premium mode did not. Premium is not a strict superset of legacy's recall on proper nouns; it is a different pass with its own gaps.

The callback this paragraph was originally chosen to test ("the White Steed and Albatross") turned out to sit in the next `<p>` element, one sentence after the scored passage, not inside it. Checked by hand against the same run: it is caught there, correctly labeled callback. See `tools/gold_sets/moby_dick_ch42_golden_paragraph.json`'s `adjacent_examples_not_scored` for the pointer.

## What premium mode adds that legacy structurally cannot produce

Legacy's candidate extraction (`Tokenizer.extractCandidates`) only surfaces capitalized proper noun phrases, so `philology` and `interpretation` annotations are impossible under that architecture regardless of prompt quality (this was the root cause finding from Phase 0, ahead of the spec's own "cheap model" diagnosis, which turned out to already be fixed). Premium mode's paragraph level pass produced real examples of both in this run, for instance:

- philology: "housings" ("ornamental cloths draped over a horse's back and flanks"), "bluff chested" (nautical sense of "bluff"), "overscorning carriage" (archaic sense of "carriage" as bearing, not vehicle)
- interpretation: "warm nostrils reddening through his cool milkiness" (reading the intrusion of blood warmth into the white body as the passage's subtlest moment)
- callback: "A most imperial and archangelical apparition" (echoing the albatross footnote's language a few paragraphs earlier)

These are not in the gold set (which only covers five hand picked spans) but they demonstrate the pipeline reaching annotation types legacy cannot reach at all.

## Cost and latency

| Metric | Value |
|---|---|
| Model | claude sonnet 4.6 |
| Input tokens (full chapter) | 350,125 |
| Output tokens | 32,102 |
| Estimated cost | $1.53 |
| Wall clock latency | 1,641 seconds (about 27 minutes) |
| Paragraphs processed | 31 |
| Total annotations (final) | 218 |
| Anchors dropped during repair | 7 (about 3% of raw candidates; genuine paraphrase, not copied verbatim, so safely excluded rather than emitted broken) |
| Anchor mismatches in final output | 0 |

Cost is within the spec's accepted $1 to $3 per chapter range. Latency is high: each paragraph runs two sequential model calls (first pass plus critique), and paragraphs are processed one at a time. Twenty seven minutes for a fifteen page chapter is not something to fix under this spec's non goals (cost optimization and batch processing are explicitly out of scope), but it is worth knowing before this runs on anything longer than one chapter.

## Two bugs found and fixed during verification

Both are committed on `feature/annotation-quality-premium`, separately from the phase commits, since they surfaced only once real runs were attempted:

1. Paragraph splitting: `source.plainText` collapses all whitespace to single spaces for the legacy flat token pipeline, so splitting it on blank lines (my first attempt) treated the entire chapter as one passage, which overran the per call output token budget and produced zero valid annotations. Fixed by recovering real paragraph boundaries from `source.chapterHTML`'s `<p>` tags instead.
2. Anchor quote mismatches: the model consistently emits straight quotes even where the source passage uses curly ones, which silently dropped otherwise correct annotations at the anchor verification step. Fixed by normalizing quote style before falling back to a drop.

## Recommendation

Per the spec's Phase 5 gate: no further prompt tuning until this report is read. The honest summary is that premium mode reaches annotation types legacy structurally cannot, at an acceptable cost, with no anchor mismatches reaching the final output, but it does not yet hit 70% recall on the one scored paragraph, and it has at least one real regression against legacy (missing "the Alleghanies"). Whether to tune the prompt, expand the gold set to reduce the effect of category boundary disagreements, or treat this paragraph as too small a sample to act on is a call for human review, not something to resolve by iterating further right now.
