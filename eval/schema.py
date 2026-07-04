"""Output schema + anchor verification/repair for premium annotations (spec Phase 3.5).

Schema: JSON array of {anchor, type, note}.
  - anchor: must be an exact verbatim substring of the passage (so the UI can
    highlight it). Anchors that don't match exactly are repaired via
    whitespace/quote normalization before being rejected.
  - type: one of allusion | context | callback | philology | interpretation
  - note: <= 60 words
"""

import re

ANNOTATION_TYPES = {"allusion", "context", "callback", "philology", "interpretation"}
MAX_NOTE_WORDS = 60


def _normalize(s: str) -> str:
    s = s.replace("‘", "'").replace("’", "'")
    s = s.replace("“", '"').replace("”", '"')
    s = re.sub(r"\s+", " ", s).strip()
    return s


def _find_repaired_anchor(anchor: str, passage: str) -> str | None:
    """Try to relocate a non-exact anchor in the passage. Returns the verbatim
    passage substring to use, or None if no reasonable match is found."""
    if anchor in passage:
        return anchor

    norm_anchor = _normalize(anchor)
    norm_passage = _normalize(passage)
    idx = norm_passage.find(norm_anchor)
    if idx == -1:
        return None

    # Map the normalized-passage match back to a verbatim passage substring by
    # scanning: find a run of raw passage text whose normalized form equals
    # norm_anchor. Whitespace/quote drift is the only thing normalize() fixes,
    # so raw and normalized lengths track closely; walk outward from a direct
    # substring guess anchored on the first/last words of the anchor.
    words = anchor.split()
    if not words:
        return None
    first_word, last_word = words[0], words[-1]
    for m_start in re.finditer(re.escape(first_word), passage):
        start = m_start.start()
        tail_search_from = start
        for m_end in re.finditer(re.escape(last_word), passage[tail_search_from:]):
            end = tail_search_from + m_end.end()
            candidate = passage[start:end]
            if _normalize(candidate) == norm_anchor:
                return candidate
    return None


def validate_and_repair(raw_annotations: list[dict], passage: str) -> tuple[list[dict], list[dict]]:
    """Returns (accepted, rejected). Each rejected entry carries a 'reason'."""
    accepted, rejected = [], []
    for ann in raw_annotations:
        anchor = ann.get("anchor")
        ann_type = ann.get("type")
        note = ann.get("note")

        if not isinstance(anchor, str) or not anchor:
            rejected.append({**ann, "reason": "missing/empty anchor"})
            continue
        if ann_type not in ANNOTATION_TYPES:
            rejected.append({**ann, "reason": f"invalid type {ann_type!r}"})
            continue
        if not isinstance(note, str) or not note.strip():
            rejected.append({**ann, "reason": "missing/empty note"})
            continue
        if len(note.split()) > MAX_NOTE_WORDS:
            rejected.append({**ann, "reason": f"note exceeds {MAX_NOTE_WORDS} words"})
            continue

        repaired = _find_repaired_anchor(anchor, passage)
        if repaired is None:
            rejected.append({**ann, "reason": "anchor not found in passage (unrepairable)"})
            continue

        accepted.append({"anchor": repaired, "type": ann_type, "note": note.strip()})

    return accepted, rejected
