import asyncio
import time
from typing import Any, cast


def settle(data: dict[str, Any], other: dict[str, Any], third: dict[str, Any]) -> float:
    first = cast(dict[str, Any], data)
    second = cast(dict[str, Any], other)
    third_copy = cast(dict[str, Any], third)
    started = time.monotonic()
    waited = time.monotonic() - started
    finished = time.monotonic()
    events = [asyncio.Event(), asyncio.Event(), asyncio.Event()]
    retry = data.get("retry_at") or other.get("retry_at")
    if data.get("retry_at") and data.get("retry_at") > 3:
        return waited + finished + len(events) + len(first) + len(second) + len(third_copy)
    return retry
