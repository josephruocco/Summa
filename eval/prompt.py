"""Prompt construction — Phase 1 (context), Phase 3 (editorial-taxonomy prompt), Phase 4 (critique)."""

FEW_SHOT_PASSAGE = (
    "Four score and seven years ago our fathers brought forth on this continent, "
    "a new nation, conceived in Liberty, and dedicated to the proposition that all "
    "men are created equal."
)

FEW_SHOT_ANNOTATIONS = [
    {
        "anchor": "Four score and seven years ago",
        "type": "philology",
        "note": "\"Score\" = twenty. Biblical cadence (cf. Psalm 90:10, \"threescore years and ten\") rather than plain \"eighty-seven years.\"",
    },
    {
        "anchor": "conceived in Liberty",
        "type": "callback",
        "note": "Echoes the natural-rights language of the Declaration of Independence, not a new formulation.",
    },
    {
        "anchor": "all men are created equal",
        "type": "allusion",
        "note": "Direct quotation from the U.S. Declaration of Independence (1776).",
    },
]

PREMIUM_SYSTEM_PROMPT = """You are an editor preparing a Norton Critical Edition of a literary text. \
Your audience is an intelligent reader who wants to know what they would MISS on a close reading \
— not what they would already catch.

Annotate the passage delimited by <passage></passage> tags. Surrounding <context_before> and \
<context_after> tags, plus <book_context>, are given only so you can recognize callbacks and \
allusions correctly — do NOT annotate anything outside the <passage> tags.

## Annotation types
Every annotation must be tagged with exactly one of:
- allusion — biblical, classical, literary, or mythological sources
- context — historical, period, nautical, or ethnographic facts needed to parse the passage
- callback — a reference to an earlier moment in THIS book (use <book_context> for this)
- philology — an archaic or shifted word meaning, or etymology, where it carries the sentence
- interpretation — a critical reading, clearly framed as a reading and not a fact. At most 1-2 per passage.

## Selectivity rules (read carefully — this is where quality is won or lost)
- Annotate only what a smart, well-read adult would miss on a first careful reading.
- NEVER define a common word. NEVER summarize the plot. NEVER write a note that just restates \
what the passage already says in plain language.
- Density target: roughly one annotation per 2-4 sentences on allusion-dense text, and FEWER on \
plain text. On a passage with no allusions, historical references, callbacks, or archaic usage, \
the correct output is an EMPTY array. Zero annotations is a valid and often correct result — do \
not force annotations to justify the pass.
- Register: terse, factual, no throat-clearing. Never write phrases like "this suggests that the \
author may be..." — state the fact or the reading directly.

## Example
Passage: "{few_shot_passage}"

Correct output:
{few_shot_json}

## Output schema
Respond with ONLY a JSON array (no prose, no markdown fences). Each element:
{{"anchor": "<exact verbatim substring of the passage>", "type": "<one of the five types above>", "note": "<factual note, <= 60 words>"}}

The "anchor" MUST be an exact, verbatim substring of the passage text — copy it character for \
character, including original punctuation and capitalization, so the UI can highlight it. Do not \
paraphrase the anchor."""


def _format_few_shot_json() -> str:
    import json

    return json.dumps(FEW_SHOT_ANNOTATIONS, indent=2)


def build_premium_messages(
    passage: str,
    context_before: str,
    context_after: str,
    book_title: str,
    book_author: str,
    chapter_label: str,
    literary_note: str,
    digest: str | None = None,
) -> tuple[str, str]:
    """Returns (system, user) for the premium first pass."""
    system = PREMIUM_SYSTEM_PROMPT.format(
        few_shot_passage=FEW_SHOT_PASSAGE,
        few_shot_json=_format_few_shot_json(),
    )

    book_context_parts = [f"Title: {book_title}", f"Author: {book_author}", f"Location: {chapter_label}"]
    if literary_note:
        book_context_parts.append(f"Notes: {literary_note}")
    if digest:
        book_context_parts.append(f"Book digest (characters, motifs, prior events): {digest}")
    book_context_block = "\n".join(book_context_parts)

    user = f"""<book_context>
{book_context_block}
</book_context>

<context_before>
{context_before}
</context_before>

<passage>
{passage}
</passage>

<context_after>
{context_after}
</context_after>

Annotate only the text inside <passage></passage>."""
    return system, user


CRITIQUE_SYSTEM_PROMPT = """You are the senior editor reviewing a junior editor's annotations of the \
same passage, for the same Norton Critical Edition. You have the same <passage>, <context_before>, \
<context_after>, and <book_context> the junior editor had, plus their draft annotations.

List, in one JSON object:
- "missed": significant allusions, callbacks, historical/nautical context, or philological points the \
  junior editor MISSED. Same schema as their annotations: {"anchor": "<exact substring of passage>", \
  "type": "<allusion|context|callback|philology|interpretation>", "note": "<factual note, <= 60 words>"}.
- "cut": the exact "anchor" strings of any of the junior editor's annotations that are WRONG, obvious \
  (define a common word, restate the passage), or padding, and should be removed.

Apply the same selectivity bar as the first pass: don't manufacture misses just to have something to \
report. If the junior editor's annotations are already correct and complete, return empty arrays for \
both. Respond with ONLY the JSON object, no prose, no markdown fences:
{"missed": [...], "cut": ["<anchor1>", "<anchor2>", ...]}"""


def build_critique_messages(
    passage: str,
    context_before: str,
    context_after: str,
    book_context_block: str,
    first_pass_annotations: list[dict],
) -> tuple[str, str]:
    import json

    user = f"""<book_context>
{book_context_block}
</book_context>

<context_before>
{context_before}
</context_before>

<passage>
{passage}
</passage>

<context_after>
{context_after}
</context_after>

Junior editor's draft annotations:
{json.dumps(first_pass_annotations, indent=2)}"""
    return CRITIQUE_SYSTEM_PROMPT, user


LEGACY_SYSTEM_PROMPT = """You are annotating a book passage for a reader. Point out anything \
interesting or important in the following paragraph."""


def build_legacy_messages(paragraph: str) -> tuple[str, str]:
    """The 'before' picture: single-pass, cheap model, paragraph-only context, generic prompt.
    Diagnosed root cause from the spec: cheap model + single-pass + paragraph-only context +
    weak prompt. Output schema is the same 5-type JSON so legacy vs premium is an apples-to-apples
    ablation, not a format difference."""
    user = f"""Paragraph:
{paragraph}

Respond with ONLY a JSON array of annotations, no prose. Each element: \
{{"anchor": "<substring of the paragraph>", "type": "<allusion|context|callback|philology|interpretation>", "note": "<note>"}}"""
    return LEGACY_SYSTEM_PROMPT, user
