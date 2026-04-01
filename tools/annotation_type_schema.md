# Annotation Type Schema

Goal: make Summa behave more like a literary annotator than a generic entity linker.

## Annotation Types

Each candidate reference should be classified into exactly one of these outputs before any Wikipedia resolution:

### `wikipedia`

Use when the phrase names a true linkable reference with a stable encyclopedic target.

Examples:
- `Great Jove` -> `Jupiter (god)`
- `Romish` -> `Catholic Church`
- `Ahab` -> `Captain Ahab`
- `Siam` -> `Thailand`

Required fields:
- `annotation_type = "wikipedia"`
- `confidence`
- `reason`
- `wikipedia_title`

Optional fields:
- `match_type = "exact" | "underlying_referent"`

### `gloss`

Use when the passage clearly invokes a meaningful cultural, literary, ritual, adjectival, or historical reference, but forcing a Wikipedia title would be brittle, misleading, or lower quality than a short explanatory note.

Examples:
- `Cæsarian` -> gloss like `imperial / Caesar-like; invoking Roman imperial inheritance`
- `White Dog` -> gloss like `reference to the Iroquois White Dog sacrifice`
- `Red Men of America` -> gloss like `period literary label for Indigenous peoples of the Americas`

Required fields:
- `annotation_type = "gloss"`
- `confidence`
- `reason`
- `gloss`

Optional fields:
- `gloss_title`

### `suppress`

Use when the phrase should not be annotated.

Examples:
- chapter headings
- thematic labels
- loose symbolic expressions
- generic descriptors
- weak or collision-prone matches

Required fields:
- `annotation_type = "suppress"`
- `confidence`
- `reason`

## Decision Flow

1. Candidate extraction
2. Annotation-type classification
3. If `suppress`: stop
4. If `gloss`: emit a gloss annotation
5. If `wikipedia`: run Wikipedia resolution

This is the key architectural change. Wikipedia resolution should only happen for candidates already classified as true linkable references.

## Runtime JSON Shape

Classifier output:

```json
{
  "annotation_type": "gloss",
  "confidence": 0.94,
  "reason": "ritual reference; modern title collisions are unsafe",
  "wikipedia_title": null,
  "gloss_title": "White Dog sacrifice",
  "gloss": "Reference to the Iroquois White Dog sacrifice, a midwinter ritual offering."
}
```

## Acceptance Policy

- Accept `suppress` only if `confidence >= 0.90`
- Accept `gloss` only if `confidence >= 0.90`
- Accept `wikipedia` only if `confidence >= 0.90`
- Otherwise fall back to the existing resolver path

## Eval Policy

Annotation-type eval should judge:
- did we choose the right output type?
- for `wikipedia`, was the title right?
- for `gloss`, was the gloss present?
- for `suppress`, did we avoid annotation?

This avoids over-optimizing for title matching on phrases that should really be glossed or suppressed.
