"""The "who needs me" attention derivation (US-005), pure over card state.

A session needs the operator when it is ``waiting-for-input`` or ``blocked``.
These helpers only *route* attention — they read card state and return a count
or a filtered list. They never mutate, notify, or act for the user (US-005
suggest-only constraint). Zero is the quiet, no-false-alarm state (AC#3).
"""

from collections.abc import Iterable

from mission_control.board.card import Card
from mission_control.detector.events import SessionState

# Exactly the states that route attention to the operator (US-005 AC#1).
_NEEDS_ATTENTION: frozenset[SessionState] = frozenset(
    {SessionState.WAITING_FOR_INPUT, SessionState.BLOCKED}
)


def attention_cards(cards: Iterable[Card]) -> list[Card]:
    """Cards in ``waiting-for-input`` or ``blocked``, in input order.

    ``idle``/``running`` (and every other state) are never included, so the
    operator only sees genuine blockers.
    """
    return [card for card in cards if card.state in _NEEDS_ATTENTION]


def attention_count(cards: Iterable[Card]) -> int:
    """How many sessions need the operator (AC#1); ``0`` means quiet (AC#3)."""
    return len(attention_cards(cards))


__all__ = ["attention_cards", "attention_count"]
