# Annotation quality eval harness

Implements the annotation-quality-fix spec's eval/pipeline work (Phases 0-5). Read this
before running anything.

## Scope note (read this first)

The shipped Summa app annotates by linking a term to a Wikipedia article or dictionary
definition (`Lookups/Wikipedia.swift`) — it has no concept of a 60-word editorial prose
note tagged allusion/context/callback/philology/interpretation. Building that as a new
annotation *type* inside the live term-lookup overlay would be a UI/UX change, which the
spec explicitly rules out ("pipeline-only, no UI/UX change").

So this harness is a **new, standalone pipeline**, living entirely under `eval/`. It does
not import, call, or modify `Lookups/Wikipedia.swift`, `OverlayController`, or any other
shipped app code. `ANNOTATION_QUALITY_MODE=legacy` and `=premium` are two configurations
of *this* pipeline, not a switch on the shipped app:

- **legacy** — reproduces the spec's diagnosed failure mode: cheap model
  (`claude-haiku-4-5`), single-pass, paragraph-only context, a generic one-line prompt.
  This is the "before" picture, not the shipped Wikipedia-lookup feature.
- **premium** — full-chapter context, `claude-sonnet-5` (the spec named `claude-sonnet-4-6`,
  since superseded; the model string is a config value in `config.py`, override via
  `ANNOTATION_MODEL_PREMIUM`), the 5-type editorial-taxonomy prompt with few-shot example,
  and a two-pass critique loop.

Both modes emit the same `{anchor, type, note}` JSON schema, so legacy vs. premium is an
apples-to-apples ablation on context + model + prompt — exactly the three variables the
spec's root-cause diagnosis names.

## Setup

```bash
pip install -r eval/requirements.txt
export ANTHROPIC_API_KEY=sk-ant-...
```

## Fixtures

| name | source | density |
|---|---|---|
| `moby_dick_ch42` | Melville, *Moby-Dick*, Ch. 42 (Gutenberg #2701) | dense allusion (golden fixture) |
| `bible_adjacent_utc` | Stowe, *Uncle Tom's Cabin*, Ch. 27 opening (Gutenberg #203) | dense biblical allusion |
| `plain_call_of_wild` | London, *The Call of the Wild*, Ch. 1 opening (Gutenberg #215) | plain/terse, near-zero annotation density expected |

Fixture texts were pulled from GITenberg's GitHub mirrors of the Gutenberg editions (this
sandbox has no direct network route to gutenberg.org) and are unmodified Gutenberg text —
public domain. `fixtures/book_context.json` carries the book digest / literary-note input
for Phase 1's context assembly.

## Running

```bash
./eval/run.sh                              # all fixtures, legacy + premium
./eval/run.sh moby_dick_ch42                # one fixture, both modes
./eval/run.sh moby_dick_ch42 premium        # one fixture, premium only
```

Output: timestamped JSON per run in `eval/baseline/` (legacy) or `eval/premium/`, e.g.
`eval/premium/moby_dick_ch42_premium_20260704T120000Z.json`, containing the final
annotation list, rejected/repaired anchors, per-call token usage, `$` cost, latency, and
(premium only) the critique-pass delta (`added`/`removed`).

## Verifying (Phase 5)

```bash
python3 -m eval.eval_report eval/premium/moby_dick_ch42_premium_<timestamp>.json
```

Diffs the run's annotations for the golden paragraph against `eval/expected_ch42.md` and
prints a catch/miss table plus cost and latency. See `eval/REPORT.md` once a real run has
been made — it is not generated from synthetic data.

## Files

- `config.py` — `ANNOTATION_QUALITY_MODE`, model IDs, pricing table for cost estimation.
- `schema.py` — output schema validation + anchor repair (whitespace/quote normalization);
  anchors that can't be relocated verbatim in the passage are rejected, not silently kept.
- `prompt.py` — Phase 3 editorial-taxonomy system prompt (role, 5 types, selectivity rules,
  few-shot example) plus the Phase 4 critique-pass prompt and the legacy-mode prompt.
- `client.py` — thin Anthropic API wrapper; logs tokens/cost/latency per call.
- `digest.py` — Phase 1 book-digest generator for chapters over the full-chapter token
  threshold (not exercised by the three fixtures above, all of which fit whole).
- `annotate.py` — orchestrates context assembly + prompt + model call + critique loop.
- `run_pipeline.py` / `run.sh` — CLI entrypoints.
