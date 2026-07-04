"""Book digest generation (spec Phase 1, sliding-window path).

For chapters over FULL_CHAPTER_TOKEN_THRESHOLD, annotate.py uses a sliding
window of +/-3 paragraphs around the target passage, plus a one-time-generated
book digest (characters, motifs, prior-chapter events, recurring symbols)
cached per document and injected into every annotation call in that mode.

None of the three golden fixtures exceed the threshold, so this path isn't
exercised by eval/run.sh today -- it exists so the pipeline has a real answer
for chapters that don't fit whole. Digest is cached to disk per book so it's
generated once, not once per passage.
"""

import hashlib
import json
import os

from . import client as api_client
from . import config

DIGEST_CACHE_DIR = os.path.join(os.path.dirname(__file__), ".digest_cache")

DIGEST_SYSTEM_PROMPT = """You are preparing editorial reference material for annotating a long \
novel chapter-by-chapter. Given prior chapters' text, produce a compact digest covering: main \
characters introduced so far and their relationships, recurring motifs/symbols, and the key plot \
events needed to recognize a callback in a later chapter. Be dense and factual -- this digest is \
injected into every future annotation call, so keep it under 400 words. Respond with plain text, \
no headers, no markdown."""


def _cache_path(book_id: str) -> str:
    key = hashlib.sha256(book_id.encode()).hexdigest()[:16]
    return os.path.join(DIGEST_CACHE_DIR, f"{key}.txt")


def get_or_generate_digest(book_id: str, prior_chapters_text: str) -> str:
    """Returns a cached digest for book_id, generating (and caching) it on first use."""
    os.makedirs(DIGEST_CACHE_DIR, exist_ok=True)
    path = _cache_path(book_id)
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            return f.read()

    result = api_client.call(
        model=config.MODEL_PREMIUM,
        system=DIGEST_SYSTEM_PROMPT,
        user=prior_chapters_text,
        max_tokens=800,
    )
    digest = result["text"].strip()
    with open(path, "w", encoding="utf-8") as f:
        f.write(digest)
    return digest
