"""Tie hooks + JSONL + PTY into one trustworthy state (Step 3, TC-INT-001..004).

The reconciler is where timing and multi-source policy live (the classifier
stays pure). It:

- applies source **precedence** hooks → JSONL → PTY when sources disagree;
- recovers from a **dropped hook** via a lower-precedence JSONL signal
  (TC-INT-002) — converging to ``done`` instead of locking in ``running``;
- **coalesces** sub-second rapid transitions so the board sees the settled
  state, not a flicker storm (TC-INT-004);
- flips to ``unknown`` on **silence past a stale threshold** (TC-INT-003).

The clock is injected on every timing-sensitive call (``now`` / event
timestamps); the reconciler never reads the system clock, so staleness is
deterministically testable.
"""

from collections.abc import Iterable
from datetime import datetime, timedelta

from pydantic import BaseModel, ConfigDict

from mission_control.detector.classifier import classify
from mission_control.detector.events import (
    SessionState,
    SignalEvent,
    SignalSource,
)
from mission_control.detector.registry import SessionRegistry

_SOURCE_RANK: dict[SignalSource, int] = {
    SignalSource.HOOK: 3,
    SignalSource.JSONL: 2,
    SignalSource.PTY: 1,
}

DEFAULT_COALESCE_WINDOW = timedelta(seconds=1)
DEFAULT_STALE_THRESHOLD = timedelta(seconds=30)

# States that have positively terminated — silence after them is not "stale".
_TERMINAL: frozenset[SessionState] = frozenset(
    {SessionState.DONE, SessionState.BLOCKED}
)


class StateTransition(BaseModel):
    """One emitted state change, with the time and source that drove it."""

    model_config = ConfigDict(frozen=True)

    session_id: str
    state: SessionState
    at: datetime
    source: SignalSource


def _coalesce(events: list[SignalEvent], window: timedelta) -> list[list[SignalEvent]]:
    """Group consecutive events into sub-``window`` bursts (ordered by time).

    Each returned group settles to the state of its *last* event, so rapid
    running→waiting→running within ``window`` collapses to one emission.
    """
    ordered = sorted(events, key=lambda e: e.timestamp)
    groups: list[list[SignalEvent]] = []
    for event in ordered:
        if groups and event.timestamp - groups[-1][0].timestamp <= window:
            groups[-1].append(event)
        else:
            groups.append([event])
    return groups


def _dominant(events: list[SignalEvent]) -> SignalEvent:
    """Pick the burst's deciding event: highest-precedence, then latest.

    Precedence (hooks > JSONL > PTY) lets a real hook override a noisier
    lower-source signal in the same burst, while still falling back to JSONL
    when no hook is present (TC-INT-002).
    """
    return max(events, key=lambda e: (_SOURCE_RANK[e.source], e.timestamp))


class StateReconciler:
    """Reduces a per-session signal stream to emitted transitions + registry state."""

    def __init__(
        self,
        registry: SessionRegistry,
        coalesce_window: timedelta = DEFAULT_COALESCE_WINDOW,
        stale_threshold: timedelta = DEFAULT_STALE_THRESHOLD,
    ) -> None:
        self._registry = registry
        self._coalesce_window = coalesce_window
        self._stale_threshold = stale_threshold
        self._transitions: dict[str, list[StateTransition]] = {}
        self._last_event_at: dict[str, datetime] = {}

    @property
    def transitions(self) -> dict[str, list[StateTransition]]:
        """Emitted transitions per session, in order (tests assert on this)."""
        return self._transitions

    def transitions_for(self, session_id: str) -> list[StateTransition]:
        """Ordered emitted transitions for one session."""
        return self._transitions.get(session_id, [])

    def ingest(self, session_id: str, events: Iterable[SignalEvent]) -> None:
        """Fold a (possibly bursty) signal stream into coalesced transitions."""
        for burst in _coalesce(list(events), self._coalesce_window):
            self._apply_burst(session_id, burst)

    def tick(self, session_id: str, now: datetime) -> None:
        """Flag the session ``unknown`` if it has been silent past the threshold.

        Compared against the injected ``now`` — never the system clock. A
        positively terminal state (``done``/``blocked``) is left untouched.
        """
        status = self._registry.get(session_id)
        last = self._last_event_at.get(session_id)
        if status is None or last is None or status.state in _TERMINAL:
            return
        if now - last > self._stale_threshold:
            self._emit(session_id, SessionState.UNKNOWN, now, SignalSource.PTY)

    def _current_state(self, session_id: str) -> SessionState:
        status = self._registry.get(session_id)
        return status.state if status is not None else SessionState.IDLE

    def _apply_burst(self, session_id: str, burst: list[SignalEvent]) -> None:
        """Classify a coalesced burst by its dominant event and emit once."""
        decisive = _dominant(burst)
        self._last_event_at[session_id] = max(e.timestamp for e in burst)
        next_state = classify(self._current_state(session_id), decisive)
        self._emit(session_id, next_state, decisive.timestamp, decisive.source)

    def _emit(
        self, session_id: str, state: SessionState, at: datetime, source: SignalSource
    ) -> None:
        """Record a transition only when the state actually changes (no flicker)."""
        if state is self._current_state(session_id):
            self._registry.update(session_id, state, at)
            return
        self._registry.update(session_id, state, at)
        self._transitions.setdefault(session_id, []).append(
            StateTransition(session_id=session_id, state=state, at=at, source=source)
        )


def reconcile_stream(
    session_id: str,
    events: Iterable[SignalEvent],
    registry: SessionRegistry | None = None,
    **kwargs: timedelta,
) -> StateReconciler:
    """Convenience: build a reconciler, ingest one stream, return it."""
    reconciler = StateReconciler(registry or SessionRegistry(), **kwargs)
    reconciler.ingest(session_id, events)
    return reconciler


__all__ = [
    "DEFAULT_COALESCE_WINDOW",
    "DEFAULT_STALE_THRESHOLD",
    "StateReconciler",
    "StateTransition",
    "reconcile_stream",
]
