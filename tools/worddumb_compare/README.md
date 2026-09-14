# Summa vs WordDumb — head-to-head on one chapter

Question: is Summa's annotation output actually different from what
[WordDumb](https://github.com/xxyzz/WordDumb) already produces for free, or is it
a costlier restatement of the same thing?

Test text: Moby-Dick ch. 42, "The Whiteness of the Whale" (Gutenberg #2701),
3,651 words. Chosen because it is the most reference-dense chapter in the book —
the best case for WordDumb's entity extraction and the hardest case for a
restraint claim.

## Running it

```
pip install spacy && python3 -m spacy download en_core_web_sm
python3 worddumb_approx.py ch42.txt --json worddumb_ch42.json
python3 compare.py --worddumb worddumb_ch42.json --summa summa_ch42.json
```

## What each side is

**WordDumb side** (`worddumb_approx.py`) is an approximation, not WordDumb. It
reproduces the *selection* logic — spaCy NER filtered to WordDumb's `NER_LABELS`
frozenset with its documented cleanup rules, plus a frequency-list stand-in for
the Wiktionary difficulty levels its Word Wise uses. It does not fetch the
Wikipedia/Wikidata/Wiktionary prose. Selection is what is under test.

**Summa side** (`summa_ch42.json`) is the shipped `SYSTEM_PROMPT` from
`server/summa-proxy/worker.js` applied to the chapter, with the shipped type
vocabulary and restraint rules. Generated directly by Claude rather than through
the deployed Worker (no API key in the build container).

## Result

| | count | words per annotation |
|---|---|---|
| WordDumb | 449 (57 X-Ray + 392 Word Wise) | 8 |
| Summa | 39 | 94 |

Summa annotates **12x less** on the same text.

Span overlap, measured two ways:

- **Loose** (any word in the anchor appears in WordDumb's output): 30/39 covered.
- **Strict** (the whole anchor is itself an entity or glossed lemma): 20/39 covered,
  19 unique to Summa.

By type, strict, unique to Summa: philology 8, context 6, allusion 4,
interpretation 1.

## The caveat that matters

Coverage means WordDumb selects the same **span**, not that it produces the same
**note**. On "Xerxes" WordDumb emits an encyclopedia summary of the Achaemenid
king; Summa says why Melville reached for him. Neither script measures that, and
it is the whole differentiation. A reader-facing comparison of note *content* on
the ~20 shared anchors is the missing experiment.
