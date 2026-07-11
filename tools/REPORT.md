# Annotation quality fix: Phase 5 report

Run scored: `tools/runs/md_ch42_premium_1783799478.json` (Moby Dick, Chapter 42, premium mode, claude sonnet 4.6, generated 2026 07 11)
Baseline compared: `tools/baseline/md_ch42_legacy.tsv` / `.log` (same chapter, legacy per candidate pipeline)
Gold set: `tools/gold_sets/moby_dick_ch42_golden_paragraph.json` (4 paragraphs, 21 expected annotations)

Updated from the first version of this report after two follow up fixes: the gold set grew from 5 hand picked spans in one paragraph to 21 spans across four paragraphs (a 5 item sample was too small to tell a real recall problem from scoring noise), and premium mode now merges in legacy's per candidate Wikipedia and gloss resolution rather than relying on the LLM passage pass alone.

## Definition of done: close, not quite met

Target was at least 70% recall on the golden paragraph with zero anchor mismatches. Zero anchor mismatches is met. Recall, on the larger and more reliable sample: strict 67%, loose 86%.

| | First report (5 items, 1 paragraph) | This report (21 items, 4 paragraphs) |
|---|---|---|
| Strict recall (span and type both right) | 20% | 67% |
| Loose recall (span caught, any type) | 60% | 86% |

## Score by paragraph

| Paragraph | Expected | Strict | Loose |
|---|---|---|---|
| white_steed | 5 | 2/5 (40%) | 4/5 (80%) |
| opening_catalog | 10 | 7/10 (70%) | 8/10 (80%) |
| albatross_footnote | 4 | 4/4 (100%) | 4/4 (100%) |
| albino_man | 2 | 1/2 (50%) | 2/2 (100%) |
| **Total** | **21** | **14/21 (67%)** | **18/21 (86%)** |

## What the legacy merge fixed

Legacy's per candidate planner (real Wikipedia search plus a prompt already tuned with specific gloss examples) now runs over the same paragraph and merges in anything it confidently resolves: it enriches an overlapping premium annotation with a real Wikipedia link, or adds a new annotation for a span premium missed outright. Across the whole chapter this added 11 new annotations and enriched 29 existing ones with a real Wikipedia title. On the golden paragraphs specifically, this fixed the exact regression the first report flagged: "the Alleghanies" is now caught (legacy resolves it to the Allegheny Mountains), and "like an Ohio" and "Red Men of America" moved from missed to caught.

## What is still actually missing

Two real gaps remain in this run:

- "Adam walked majestic as a god" (allusion): still never produced by either path.
- The Latin word for white/alb etymology (philology): premium proposed it, then its own critique pass cut it (visible in the new per annotation critique trace: `cutByCritique` lists it directly by anchor, along with the Hanoverian flag and the ermine of the Judge). Whether the critique pass is being too aggressive here, or whether it made a defensible call, is worth a human read of the actual cut list in the run JSON rather than a guess from this report.

One new problem, not a miss: "Lord of the White Elephants" scores as missed, but it is not actually absent. Premium produced one long annotation spanning the whole clause ("kings of Pegu placing the title 'Lord of the White Elephants' above all their other magniloquent ascriptions of dominion") instead of two tight ones. The scorer's one to one matching gives that span credit for "Pegu" and has nothing left for "Lord of the White Elephants." This is an anchor tightness problem in the first pass prompt, not a recall problem: the prompt's own rule ("no annotation should just restate the passage") is being violated by the model on longer sentences. Worth a prompt tweak later, not fixed in this pass.

## Per annotation critique trace (new this round)

The run JSON now records, per paragraph, the exact annotations the critique pass added (`addedByCritique`) and cut (`cutByCritique`), not just counts. This is what made the "alb etymology" diagnosis above possible instead of a guess. Spot check on the opening_catalog paragraph: critique added 10 annotations (mostly interpretation and philology, the two hardest types) and cut 5, including one legitimate looking philology annotation. The critique pass is doing real work in both directions, not just padding or just trimming.

## Cost and latency

| Metric | This run | First run |
|---|---|---|
| Estimated cost | $1.61 | $1.53 |
| Wall clock latency | 944 seconds (about 16 minutes) | 1,641 seconds (about 27 minutes) |
| Total annotations | 231 | 218 |
| Anchor mismatches in final output | 0 | 0 |
| Anchors dropped during repair | 9 | 7 |

Cost moved up only slightly despite the added legacy resolution calls, because most legacy candidate lookups are fast Wikipedia API calls, not LLM calls. Latency dropped, most likely normal variance between runs rather than anything this change did; sequential per paragraph processing is still the main latency driver and is unchanged.

## Recommendation

Recall is close enough to the 70% target that the honest read is "probably fine, verify with a bigger sample" rather than "needs more work." The one concrete, well understood fix left on the table is anchor tightness on long enumerative sentences (the Pegu example above); that is a small, scoped prompt change, not a rework. The Adam allusion miss and the alb etymology cut are worth a look in the actual run JSON before deciding whether to touch the prompt again. Per the original spec's Phase 5 gate, this is a stopping point for a human read, not a build further signal.
