# Calibre plugin — scope

Written after measuring Summa against
[WordDumb](https://github.com/xxyzz/WordDumb) on two chapters of Moby-Dick.
Harness and raw output: `tools/worddumb_compare/`.

## The evidence

Two chapters, chosen as best case and control. Ch. 42 "The Whiteness of the
Whale" is a catalogue of proper nouns — the best case for entity extraction and
the hardest case for a restraint claim. Ch. 26 "Knights and Squires" is ordinary
narrative.

| | words | WordDumb | Summa | ratio |
|---|---|---|---|---|
| ch. 42 | 3,651 | 449 | 39 | 12x |
| ch. 26 | 1,221 | 148 | 13 | 11x |
| **total** | **4,872** | **597** | **52** | **11.5x** |

Strict span overlap — the whole anchor is itself an X-Ray entity or a Word Wise
lemma — leaves 28 of 52 Summa annotations (54%) that WordDumb's selection
cannot reach. Broken out by type:

| type | unique to Summa | |
|---|---|---|
| philology | 12/13 | **92%** |
| interpretation | 2/2 | 100% |
| context | 10/26 | 38% |
| allusion | 4/11 | 36% |

## What that changes

The intuition was that `allusion` is the differentiator, because only a language
model can notice that a phrase echoes Ecclesiastes. The measurement says the
opposite.

Allusions in 19th-century prose are overwhelmingly **proper nouns** — Xerxes,
Froissart, Coleridge, Great Jove — and spaCy NER catches proper nouns. That is
its entire job. On the allusion type WordDumb's selection already covers 64% of
what Summa finds.

`philology` is where WordDumb structurally cannot follow: **alb, Romish,
Cæsarian, Requin, hypo, off soundings, snow-howdahed, swart, the fishery,
lowering for whales, twice-baked biscuit**. Not entities, so NER misses them.
Multi-word or too rare to sit in a frequency list, so Word Wise misses them too.

The control chapter sharpens it. On ordinary narrative WordDumb's X-Ray found
only 14 entities and its output collapsed almost entirely into a dictionary
(134 of 148), while Summa still found 13 things. **Uniqueness rises on plain
prose (69%) rather than falling (49% on ch. 42).** Most of a novel is plain
prose.

## Scope

**Ship:** `philology`, `context`.

**Ship, quietly:** `allusion`. It is the type readers will name when they
describe the product, and it is genuinely better than a Wikipedia biography
stub even where the span overlaps — but it is not the differentiator and should
not carry the pitch.

**Ship behind a default-off switch:** `interpretation`. 100% unique, and the
whole hallucination surface. One per passage at most, already enforced by the
prompt.

**Do not build:** a whole-book entity index, a character list, a locator map,
word-difficulty levels, KFX/AZW3/MOBI, multi-language. WordDumb does all of it,
for free, deterministically, in 23 languages, with six years of maintenance.

## The prompt change this implies

`server/summa-proxy/worker.js:56` currently clamps the differentiating type
hardest:

> `philology`: an archaic or shifted word meaning, or an etymology, **where it
> carries the sentence**.

That qualifier suppresses exactly the annotations the measurement says are the
product. Loosening it is the single highest-value prompt edit available.

**Not applied.** The same prompt serves the macOS app, and the eval harness in
`tools/` is calibrated against it. Changing it means re-running
`eval_annotation_types.py` and `eval_quality.py` against the gold sets first.

## Pitch

Complementary, not competitive. WordDumb handles vocabulary difficulty and
entity indexing; Summa handles the period vocabulary and idiom that a frequency
list cannot rank and NER cannot see. Same EPUB, different footnotes, both
installed.

"Here's a WordDumb alternative" is a post that gets ignored. "Here's the other
half" is not.

## Known weakness

Span overlap is not content equivalence, and the reverse is also true: on the 20
shared ch. 42 anchors, WordDumb resolves "Coleridge" to a biography of Samuel
Taylor Coleridge while Summa says the Ancient Mariner killed an albatross and
Ishmael insists he felt the dread before reading the poem. That gap is the real
case, it is visible to any reader, and nothing here measures it —
`side_by_side.py` prints the pairs but needs network access to fetch the prose
WordDumb would actually print.
