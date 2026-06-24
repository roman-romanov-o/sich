"""Transport-agnostic ingest service for live hook/JSONL delivery (Phase 02 wiring).

The live HTTP endpoint (:mod:`mission_control.server.endpoint`) is a thin shim
over this service: it parses one raw payload off the wire and hands it here.
*All* classification/reconciliation stays in the existing detector modules — this
file only routes a payload to the right normalizer, ingests it through the real
:class:`StateReconciler`, and injects a wall-clock ``now`` so staleness ticking
stays deterministic (the clock is a constructor dependency, never read inline).

Each live arrival is ingested on its own, so it forms its own coalesce burst —
which is the correct real-time behavior (events are reconciled as they land).
"""

from collections.abc import Callable
from datetime import UTC, datetime
from typing import Any

from mission_control.detector.events import SignalEvent, SignalSource
from mission_control.detector.hook_receiver import normalize_hook
from mission_control.detector.jsonl_tail import normalize_jsonl
from mission_control.detector.reconciler import StateReconciler
from mission_control.detector.registry import SessionRegistry, SessionStatus


def _utc_now() -> datetime:
    """Default wall-clock source (injectable so tests stay deterministic)."""
    return datetime.now(UTC)


def normalize_payload(payload: dict[str, Any]) -> SignalEvent:
    """Route one raw payload to the source-specific detector normalizer.

    A ``source: "jsonl"`` marker selects the JSONL-tail normalizer; everything
    else is treated as a Claude Code hook POST (the primary, HIGH-confidence
    signal). The normalizers themselves are unchanged detector code.
    """
    if payload.get("source") == SignalSource.JSONL.value:
        return normalize_jsonl(payload)
    return normalize_hook(payload)


class IngestService:
    """Owns the registry + reconciler and ingests live payloads into them.

    A single instance is shared by the HTTP endpoint so reads (``status_of`` /
    ``snapshot``) observe exactly what live POSTs reconciled — this is the
    registry handle Phase 03's board will consume.
    """

    def __init__(
        self,
        registry: SessionRegistry | None = None,
        reconciler: StateReconciler | None = None,
        clock: Callable[[], datetime] = _utc_now,
    ) -> None:
        self._registry = registry or SessionRegistry()
        self._reconciler = reconciler or StateReconciler(self._registry)
        self._clock = clock

    @property
    def registry(self) -> SessionRegistry:
        """The shared session-state source of truth (for Phase 03 to read)."""
        return self._registry

    def ingest_payload(self, payload: dict[str, Any]) -> SessionStatus:
        """Normalize one live payload and reconcile it; return its new status.

        A fresh arrival is never stale, so ingest does *not* tick — staleness is
        a separate periodic concern (:meth:`sweep_stale`), driven off the
        injected wall clock so it stays deterministic and never collides with a
        fixture's historical event timestamps.
        """
        event = normalize_payload(payload)
        self._reconciler.ingest(event.session_id, [event])
        status = self._registry.get(event.session_id)
        assert status is not None  # ingest always writes the session through.
        return status

    def sweep_stale(self, session_id: str | None = None) -> None:
        """Flip sessions silent past the stale threshold to ``unknown``.

        Called by a background timer with the injected wall clock. With no id,
        sweeps every tracked session; the reconciler leaves terminal states and
        recently-active sessions untouched.
        """
        now = self._clock()
        ids = [session_id] if session_id else list(self._registry.states())
        for sid in ids:
            self._reconciler.tick(sid, now=now)

    def status_of(self, session_id: str) -> SessionStatus | None:
        """Current status for one session, or ``None`` if untracked."""
        return self._registry.get(session_id)

    def snapshot(self) -> dict[str, SessionStatus]:
        """All tracked sessions' current status (for the GET endpoints)."""
        statuses = (self._registry.get(sid) for sid in self._registry.states())
        return {s.session_id: s for s in statuses if s is not None}
