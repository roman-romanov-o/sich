"""Normalize Claude Code hook payloads into typed signal events (Step 1).

This is the *normalization* seam only — the HTTP transport (a local
``127.0.0.1`` receiver) is out of scope and modeled as a pure function over
already-received payloads, so it is testable without a server or a live agent
(TC-INT-001 feeds canonical payload dicts).

A Claude Code hook POST carries ``hook_event_name``, ``session_id``, a timestamp
and event-specific fields. ``running-tests`` is inferred from a ``PreToolUse``
whose ``tool_input.command`` runs a known test runner (``research/06``).
"""

from datetime import UTC, datetime
from typing import Any

from mission_control.detector.events import SignalEvent, SignalKind, SignalSource

# Claude Code hook event name → normalized signal kind.
_HOOK_KIND: dict[str, SignalKind] = {
    "SessionStart": SignalKind.SESSION_START,
    "UserPromptSubmit": SignalKind.USER_INPUT,
    "PreToolUse": SignalKind.TOOL_USE,
    "PostToolUse": SignalKind.TOOL_USE,
    "PostToolUseFailure": SignalKind.ERROR_EXIT,
    "PermissionRequest": SignalKind.PERMISSION_REQUEST,
    "PermissionDenied": SignalKind.ERROR_EXIT,
    "Stop": SignalKind.STOP,
    "StopFailure": SignalKind.ERROR_EXIT,
}

# Substrings in a Bash command that mean "this tool call is a test run".
_TEST_RUNNERS: tuple[str, ...] = (
    "pytest",
    "jest",
    "vitest",
    "cargo test",
    "go test",
    "npm test",
)


def _parse_timestamp(payload: dict[str, Any]) -> datetime:
    """Read the payload timestamp; default to epoch-naive only if truly absent.

    Accepts ISO-8601 strings or epoch seconds; missing → ``datetime.min`` (UTC),
    keeping the function total without inventing a clock read.
    """
    raw = payload.get("timestamp")
    if isinstance(raw, int | float):
        return datetime.fromtimestamp(raw, tz=UTC)
    if isinstance(raw, str):
        return datetime.fromisoformat(raw)
    return datetime.min.replace(tzinfo=UTC)


def _is_test_command(payload: dict[str, Any]) -> bool:
    """True when a PreToolUse Bash command invokes a known test runner."""
    if payload.get("tool_name") != "Bash":
        return False
    command = payload.get("tool_input", {}).get("command", "")
    return any(runner in command for runner in _TEST_RUNNERS)


def _resolve_kind(payload: dict[str, Any]) -> SignalKind:
    """Map a hook event name to a kind, promoting test-running tool calls."""
    name = payload.get("hook_event_name", "")
    kind = _HOOK_KIND.get(name, SignalKind.UNKNOWN)
    if name == "PreToolUse" and _is_test_command(payload):
        return SignalKind.TEST_RUN_START
    return kind


def normalize_hook(payload: dict[str, Any]) -> SignalEvent:
    """Map one Claude Code hook payload to a typed :class:`SignalEvent`."""
    return SignalEvent(
        kind=_resolve_kind(payload),
        source=SignalSource.HOOK,
        session_id=payload.get("session_id", ""),
        timestamp=_parse_timestamp(payload),
        raw=payload,
    )


def normalize_sequence(payloads: list[dict[str, Any]]) -> list[SignalEvent]:
    """Normalize a recorded sequence of hook payloads, preserving order."""
    return [normalize_hook(p) for p in payloads]
