"""cmux-style session card model (US-003 AC#2).

A :class:`Card` is the pure data a board column would render: which session,
where it lives, which agent runs it, which flow it belongs to, and its current
:class:`SessionState`. Rendering, focus, and timing are the Swift app's job —
this module only produces the structure.
"""

from enum import StrEnum

from pydantic import BaseModel, ConfigDict

from mission_control.detector.events import SessionState


class Agent(StrEnum):
    """The agentic-coding CLI driving a session (cmux metadata)."""

    CLAUDE = "claude"
    CODEX = "codex"
    GEMINI = "gemini"


class Flow(StrEnum):
    """Two-flow tag: A autonomous (API pool) vs. B interactive (subscription)."""

    A = "A"
    B = "B"


class Card(BaseModel):
    """One session's board card: identity + cmux metadata + current state."""

    model_config = ConfigDict(frozen=True)

    session_id: str
    project_dir: str
    agent: Agent
    flow: Flow
    state: SessionState


__all__ = ["Agent", "Card", "Flow"]
