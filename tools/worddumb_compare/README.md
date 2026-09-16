# Summa vs WordDumb — head-to-head on one chapter

Question: is Summa's annotation output actually different from what
[WordDumb](https://github.com/xxyzz/WordDumb) already produces for free, or is it
a costlier restatement of the same thing?

Test text: two chapters of Moby-Dick (Gutenberg #2701). Ch. 42 "The Whiteness of
the Whale" (3,651 words) is the most reference-dense chapter in the book — the
best case for WordDumb's entity extraction and the hardest case for a restraint
claim. Ch. 26 "Knights and Squires" (1,221 words) is ordinary narrative, and is
the control.

## Running it

```
pip install spacy && python3 -m spacy download en_core_web_sm
python3 worddumb_approx.py ch42.txt --json worddumb_ch42.json
python3 compare.py     --worddumb worddumb_ch42.json --summa summa_ch42.json
python3 side_by_side.py --worddumb worddumb_ch42.json --summa summa_ch42.json
```

`compare.py` measures which spans each tool selects. `side_by_side.py` measures
what each one says about the spans they both select — add `--offline` to skip the
Wikipedia and kaikki fetches and fall back to article titles.

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

| | words | WordDumb | Summa | ratio |
|---|---|---|---|---|
| ch. 42 | 3,651 | 449 (57 X-Ray + 392 Word Wise) | 39 | 12x |
| ch. 26 | 1,221 | 148 (14 X-Ray + 134 Word Wise) | 13 | 11x |
| total | 4,872 | 597 | 52 | **11.5x** |

Strict span overlap — the whole anchor is itself an X-Ray entity or a Word Wise
lemma — leaves 28/52 (54%) that WordDumb's selection cannot reach. By type:

| type | unique to Summa | |
|---|---|---|
| philology | 12/13 | 92% |
| interpretation | 2/2 | 100% |
| context | 10/26 | 38% |
| allusion | 4/11 | 36% |

Allusions in this prose are proper nouns, and NER catches proper nouns — so
`allusion` is the type WordDumb covers *best*, not worst. `philology` is where it
structurally cannot follow. On the control chapter its X-Ray found only 14
entities and its output collapsed into a dictionary, while Summa still found 13
things: uniqueness rises on plain prose (69%) rather than falling (49%).

Positioning consequences: `docs/calibre-plugin-scope.md`.

## The caveat that matters

Coverage means WordDumb selects the same **span**, not that it produces the same
**note**. On "Xerxes" WordDumb emits an encyclopedia summary of the Achaemenid
king; Summa says why Melville reached for him. Neither script measures that, and
it is the whole differentiation. A reader-facing comparison of note *content* on
the ~20 shared anchors is the missing experiment.
