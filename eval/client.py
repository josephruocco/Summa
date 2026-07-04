"""Thin Anthropic API wrapper: makes one call, returns (text, usage, cost, latency_ms)."""

import time

import anthropic

from . import config

_client = None


def _get_client() -> anthropic.Anthropic:
    global _client
    if _client is None:
        _client = anthropic.Anthropic()
    return _client


def call(model: str, system: str, user: str, max_tokens: int = 4096) -> dict:
    client = _get_client()
    start = time.monotonic()

    kwargs: dict = dict(
        model=model,
        max_tokens=max_tokens,
        system=system,
        messages=[{"role": "user", "content": user}],
    )
    # effort/adaptive thinking only apply to models that support them; Haiku errors on it.
    if model != config.MODEL_LEGACY:
        kwargs["output_config"] = {"effort": "high"}

    response = client.messages.create(**kwargs)
    latency_ms = (time.monotonic() - start) * 1000

    text = "".join(block.text for block in response.content if block.type == "text")
    usage = {
        "input_tokens": response.usage.input_tokens,
        "output_tokens": response.usage.output_tokens,
        "cache_read_input_tokens": getattr(response.usage, "cache_read_input_tokens", 0) or 0,
        "cache_creation_input_tokens": getattr(response.usage, "cache_creation_input_tokens", 0) or 0,
    }
    cost = config.estimate_cost(model, usage["input_tokens"], usage["output_tokens"])

    return {
        "text": text,
        "usage": usage,
        "cost_usd": round(cost, 6),
        "latency_ms": round(latency_ms, 1),
        "model": model,
    }
