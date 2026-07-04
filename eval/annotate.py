"""Core annotation pipeline. Orchestrates context assembly (Phase 1), model call
(Phase 2), prompt (Phase 3), and the two-pass critique loop (Phase 4)."""

import json
import re

from . import client as api_client
from . import config
from . import prompt as prompt_mod
from . import schema


def _extract_json(text: str):
    """Model output is asked to be bare JSON but may still wrap in ```json fences."""
    text = text.strip()
    fence = re.match(r"^```(?:json)?\s*(.*?)\s*```$", text, re.DOTALL)
    if fence:
        text = fence.group(1)
    return json.loads(text)


def split_paragraphs(text: str) -> list[str]:
    paras = re.split(r"\n\s*\n", text.strip())
    return [p.strip() for p in paras if p.strip()]


def run_legacy(chapter_text: str) -> dict:
    """Legacy mode: single-pass, cheap model, paragraph-only context (the
    diagnosed 'ChatGPT with a UI' failure mode)."""
    paragraphs = split_paragraphs(chapter_text)
    all_accepted, all_rejected = [], []
    total_cost = 0.0
    total_latency = 0.0
    total_usage = {"input_tokens": 0, "output_tokens": 0}
    per_call_log = []

    for para in paragraphs:
        system, user = prompt_mod.build_legacy_messages(para)
        result = api_client.call(config.MODEL_LEGACY, system, user, max_tokens=1024)
        per_call_log.append({"model": result["model"], "usage": result["usage"], "cost_usd": result["cost_usd"], "latency_ms": result["latency_ms"]})
        total_cost += result["cost_usd"]
        total_latency += result["latency_ms"]
        total_usage["input_tokens"] += result["usage"]["input_tokens"]
        total_usage["output_tokens"] += result["usage"]["output_tokens"]

        try:
            raw = _extract_json(result["text"])
        except (json.JSONDecodeError, ValueError):
            all_rejected.append({"reason": "unparseable model output", "raw_text": result["text"][:200]})
            continue

        accepted, rejected = schema.validate_and_repair(raw, para)
        all_accepted.extend(accepted)
        all_rejected.extend(rejected)

    return {
        "mode": "legacy",
        "model": config.MODEL_LEGACY,
        "annotations": all_accepted,
        "rejected": all_rejected,
        "cost_usd": round(total_cost, 6),
        "latency_ms": round(total_latency, 1),
        "usage": total_usage,
        "calls": per_call_log,
    }


def run_premium(chapter_text: str, book_ctx: dict) -> dict:
    """Premium mode: full-chapter context, editorial-taxonomy prompt,
    frontier model, two-pass critique loop."""
    book_context_block = "\n".join(
        [
            f"Title: {book_ctx['title']}",
            f"Author: {book_ctx['author']}",
            f"Location: {book_ctx['chapter_label']}",
            f"Notes: {book_ctx.get('literary_note', '')}",
        ]
    )

    # Full-chapter mode: the whole chapter is the passage; no separate
    # before/after context is needed since it's all inside <passage>.
    system, user = prompt_mod.build_premium_messages(
        passage=chapter_text,
        context_before="",
        context_after="",
        book_title=book_ctx["title"],
        book_author=book_ctx["author"],
        chapter_label=book_ctx["chapter_label"],
        literary_note=book_ctx.get("literary_note", ""),
        digest=book_ctx.get("digest"),
    )

    first_pass = api_client.call(config.MODEL_PREMIUM, system, user, max_tokens=4096)
    total_cost = first_pass["cost_usd"]
    total_latency = first_pass["latency_ms"]
    total_usage = dict(first_pass["usage"])
    calls_log = [{"pass": "first", "model": first_pass["model"], "usage": first_pass["usage"], "cost_usd": first_pass["cost_usd"], "latency_ms": first_pass["latency_ms"]}]

    try:
        raw_first = _extract_json(first_pass["text"])
    except (json.JSONDecodeError, ValueError):
        raw_first = []
        calls_log.append({"error": "unparseable first-pass output", "raw_text": first_pass["text"][:300]})

    accepted_first, rejected_first = schema.validate_and_repair(raw_first, chapter_text)

    delta = {"added": [], "removed": []}
    final_annotations = accepted_first
    rejected_all = list(rejected_first)

    if config.CRITIQUE_LOOP_ENABLED:
        crit_system, crit_user = prompt_mod.build_critique_messages(
            passage=chapter_text,
            context_before="",
            context_after="",
            book_context_block=book_context_block,
            first_pass_annotations=accepted_first,
        )
        critique = api_client.call(config.MODEL_PREMIUM, crit_system, crit_user, max_tokens=2048)
        total_cost += critique["cost_usd"]
        total_latency += critique["latency_ms"]
        total_usage["input_tokens"] += critique["usage"]["input_tokens"]
        total_usage["output_tokens"] += critique["usage"]["output_tokens"]
        calls_log.append({"pass": "critique", "model": critique["model"], "usage": critique["usage"], "cost_usd": critique["cost_usd"], "latency_ms": critique["latency_ms"]})

        try:
            crit_result = _extract_json(critique["text"])
            missed_raw = crit_result.get("missed", [])
            cut_anchors = set(crit_result.get("cut", []))
        except (json.JSONDecodeError, ValueError, AttributeError):
            missed_raw, cut_anchors = [], set()
            calls_log.append({"error": "unparseable critique output", "raw_text": critique["text"][:300]})

        missed_accepted, missed_rejected = schema.validate_and_repair(missed_raw, chapter_text)
        rejected_all.extend(missed_rejected)

        kept = [a for a in accepted_first if a["anchor"] not in cut_anchors]
        removed = [a for a in accepted_first if a["anchor"] in cut_anchors]

        final_annotations = kept + missed_accepted
        delta["added"] = missed_accepted
        delta["removed"] = removed

    return {
        "mode": "premium",
        "model": config.MODEL_PREMIUM,
        "annotations": final_annotations,
        "rejected": rejected_all,
        "critique_delta": delta,
        "cost_usd": round(total_cost, 6),
        "latency_ms": round(total_latency, 1),
        "usage": total_usage,
        "calls": calls_log,
    }


def annotate(chapter_text: str, book_ctx: dict, mode: str) -> dict:
    if mode == "premium":
        return run_premium(chapter_text, book_ctx)
    return run_legacy(chapter_text)
