"""Board derivations (Phase 03 logic subset) — pure data for the Swift UI.

Reads the detector's :class:`SessionRegistry` and turns it into the structures a
board would render: cmux-style :class:`Card`s, state-column :func:`place`ment,
and the "who needs me" :func:`attention_count`. No rendering, focus, or timing
lives here — those are the native app's job. Everything is a pure function over
state, so it is deterministic and never touches a live agent.
"""

from mission_control.board.attention import attention_cards, attention_count
from mission_control.board.card import Agent, Card, Flow
from mission_control.board.placement import Column, column_for_state, place

__all__ = [
    "Agent",
    "Card",
    "Column",
    "Flow",
    "attention_cards",
    "attention_count",
    "column_for_state",
    "place",
]
