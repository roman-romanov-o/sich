"""Place each session-card into exactly one state column (US-003 AC#1).

Pure derivation over :class:`Card` state: a session appears as a single card in
the column matching its :class:`SessionState`. The detector's ``stale``/
``unknown`` outcome maps to the explicit ``unknown`` column — never silently
left in ``running`` or guessed into ``done`` (US-004 AC#3).
"""

from collections.abc import Iterable
from enum import StrEnum

from mission_control.board.card import Card
from mission_control.detector.events import SessionState


class Column(StrEnum):
    """The v1 board columns: the six state-columns plus an explicit ``unknown``."""

    IDLE = "idle"
    RUNNING = "running"
    WAITING_FOR_INPUT = "waiting-for-input"
    RUNNING_TESTS = "running-tests"
    BLOCKED = "blocked"
    DONE = "done"
    UNKNOWN = "unknown"


_STATE_COLUMN: dict[SessionState, Column] = {
    SessionState.IDLE: Column.IDLE,
    SessionState.RUNNING: Column.RUNNING,
    SessionState.WAITING_FOR_INPUT: Column.WAITING_FOR_INPUT,
    SessionState.RUNNING_TESTS: Column.RUNNING_TESTS,
    SessionState.BLOCKED: Column.BLOCKED,
    SessionState.DONE: Column.DONE,
    SessionState.UNKNOWN: Column.UNKNOWN,
}


def column_for_state(state: SessionState) -> Column:
    """Map a detector state to its board column; unknown/stale → ``unknown``."""
    return _STATE_COLUMN.get(state, Column.UNKNOWN)


def place(cards: Iterable[Card]) -> dict[Column, list[Card]]:
    """Group cards by column — one card per session, stable input ordering.

    Every column key is present (empty list when no cards land there) so a
    renderer can draw all columns without re-deriving the set.
    """
    placed: dict[Column, list[Card]] = {column: [] for column in Column}
    for card in cards:
        placed[column_for_state(card.state)].append(card)
    return placed


__all__ = ["Column", "column_for_state", "place"]
