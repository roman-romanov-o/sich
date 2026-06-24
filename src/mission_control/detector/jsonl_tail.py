"""Normalize Claude Code JSONL transcript lines into signal events (fallback).

JSONL is the reconciliation fallback (lower precedence than hooks per
``research/06``): ``~/.claude/projects/<cwd>/<session-id>.jsonl`` is appended in
real time with transcript records. We read only the coarse turn-lifecycle shape
needed to recover from a dropped hook (TC-INT-002) — a record marking the turn
complete becomes a :attr:`SignalKind.STOP`.

Like :mod:`hook_receiver`, this is the *normalization* seam only; the actual
``tail -f`` / FSEvents transport is out of scope and modeled as a function over
already-read records, keeping it testable without touching the filesystem.
"""

from datetime import UTC, datetime
from typing import Any

from mission_control.detector.events import SignalEvent, SignalKind, SignalSource

# JSONL transcript record ``type`` → normalized signal kind.
_JSONL_KIND: dict[str, SignalKind] = {
    "turn_completed": SignalKind.STOP,
    "turn_started": SignalKind.SESSION_START,
    "tool_use": SignalKind.TOOL_USE,
    "tool_result": SignalKind.TOOL_USE,
    "error": SignalKind.ERROR_EXIT,
}


def _parse_timestamp(record: dict[str, Any]) -> datetime:
    """Read a record timestamp (ISO-8601 or epoch); absent → epoch-min UTC."""
    raw = record.get("timestamp")
    if isinstance(raw, int | float):
        return datetime.fromtimestamp(raw, tz=UTC)
    if isinstance(raw, str):
        return datetime.fromisoformat(raw)
    return datetime.min.replace(tzinfo=UTC)


def normalize_jsonl(record: dict[str, Any]) -> SignalEvent:
    """Map one JSONL transcript record to a typed :class:`SignalEvent`."""
    return SignalEvent(
        kind=_JSONL_KIND.get(record.get("type", ""), SignalKind.UNKNOWN),
        source=SignalSource.JSONL,
        session_id=record.get("session_id", ""),
        timestamp=_parse_timestamp(record),
        raw=record,
    )
