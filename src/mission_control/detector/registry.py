"""In-memory per-session state registry (Step 3 sink).

The reconciler writes each session's current :class:`SessionState` here; Phase 03
(board placement) reads it. Simple, typed, no I/O — the clock is supplied by the
caller (``at``) so the registry never reads it itself.
"""

from datetime import datetime

from pydantic import BaseModel, ConfigDict

from mission_control.detector.events import SessionState


class SessionStatus(BaseModel):
    """A session's current state and when it was last updated."""

    model_config = ConfigDict(frozen=True)

    session_id: str
    state: SessionState
    updated_at: datetime


class SessionRegistry:
    """Holds the latest :class:`SessionStatus` per session id, in memory."""

    def __init__(self) -> None:
        self._by_session: dict[str, SessionStatus] = {}

    def update(self, session_id: str, state: SessionState, at: datetime) -> SessionStatus:
        """Record ``state`` as ``session_id``'s current state at time ``at``."""
        status = SessionStatus(session_id=session_id, state=state, updated_at=at)
        self._by_session[session_id] = status
        return status

    def get(self, session_id: str) -> SessionStatus | None:
        """Return the session's current status, or ``None`` if untracked."""
        return self._by_session.get(session_id)

    def states(self) -> dict[str, SessionState]:
        """Snapshot of every tracked session's current state."""
        return {sid: status.state for sid, status in self._by_session.items()}
