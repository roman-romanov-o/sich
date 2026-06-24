"""Typed signal model for session state detection (US-004 / Phase 02).

The detector consumes heterogeneous Claude Code signals — HTTP hooks (primary,
HIGH confidence per ``research/06``), JSONL tail, and PTY scraping — and
normalizes them all into one :class:`SignalEvent`. The classifier and reconciler
read only this typed event, never raw provider payloads, so later providers
(Codex/Gemini) can plug in without touching the state machine.
"""

from datetime import datetime
from enum import StrEnum
from typing import Any

from pydantic import BaseModel, ConfigDict


class SignalKind(StrEnum):
    """A normalized lifecycle signal, provider-agnostic.

    The names mirror the classifier's mapping table in the spec; ``StaleTimeout``
    and ``ContradictorySignals`` are synthesized by the reconciler (not a hook),
    and ``Unknown`` is the catch-all for payloads we can't positively classify.
    """

    SESSION_START = "session-start"
    TOOL_USE = "tool-use"
    PERMISSION_REQUEST = "permission-request"
    USER_INPUT = "user-input"
    TEST_RUN_START = "test-run-start"
    ERROR_EXIT = "error-exit"
    STOP = "stop"
    STALE_TIMEOUT = "stale-timeout"
    CONTRADICTORY_SIGNALS = "contradictory-signals"
    UNKNOWN = "unknown"


class SignalSource(StrEnum):
    """Where a signal came from — drives reconciliation precedence.

    Hooks are the most trustworthy (push-based, HIGH confidence); JSONL tail
    reconciles dropped hooks; PTY scraping is the last resort.
    """

    HOOK = "hook"
    JSONL = "jsonl"
    PTY = "pty"


class SessionState(StrEnum):
    """The card state a session is classified into.

    The first six are the US-003 board columns; ``UNKNOWN`` is the explicit
    not-positively-determined indicator required by US-004 AC#3 — never a guess.
    """

    IDLE = "idle"
    RUNNING = "running"
    WAITING_FOR_INPUT = "waiting-for-input"
    RUNNING_TESTS = "running-tests"
    BLOCKED = "blocked"
    DONE = "done"
    UNKNOWN = "unknown"


class SignalEvent(BaseModel):
    """One normalized signal for a single session.

    ``raw`` keeps the original payload for debugging/audit without leaking its
    shape into the state machine, which reads only ``kind``/``source``.
    """

    model_config = ConfigDict(frozen=True)

    kind: SignalKind
    source: SignalSource
    session_id: str
    timestamp: datetime
    raw: dict[str, Any] | None = None
