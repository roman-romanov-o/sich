"""TC-E2E-001/002/004 (logic level) — the headline mission-control loop.

Pure-logic end of the board flow: the fake-agent fixture emits the same hook
events a real run would, through the real :class:`StateReconciler` into a shared
:class:`SessionRegistry`; we then derive board :class:`Card`s, state-column
placement, and the "who needs me" count. No Swift/UI, no live ``claude``, no
quota — rendering, click-to-focus, <500ms timing and real-process kill are the
native app's job and out of scope here.
"""

from datetime import UTC, datetime, timedelta

import pytest

from mission_control.board.attention import attention_cards, attention_count
from mission_control.board.card import Agent, Card, Flow
from mission_control.board.placement import Column, place
from mission_control.detector.events import SessionState
from mission_control.detector.reconciler import StateReconciler
from mission_control.detector.registry import SessionRegistry
from tests.fixtures.fake_agent import GO_SILENT, drive, seed_idle

pytestmark = pytest.mark.e2e

CLOCK = datetime(2026, 6, 16, 12, 0, 0, tzinfo=UTC)
PROJECT_DIRS = {"projA": "~/proj-a", "projB": "~/proj-b", "projC": "~/proj-c"}


def _card_for(registry: SessionRegistry, session_id: str) -> Card:
    """Build the cmux-style card for one session from its reconciled state."""
    status = registry.get(session_id)
    return Card(
        session_id=session_id,
        project_dir=PROJECT_DIRS[session_id],
        agent=Agent.CLAUDE,
        flow=Flow.B,
        state=status.state,
    )


def _all_cards(registry: SessionRegistry) -> list[Card]:
    """Cards for the three seeded sessions, in stable projA/projB/projC order."""
    return [_card_for(registry, sid) for sid in ("projA", "projB", "projC")]


@pytest.fixture
def seeded() -> tuple[SessionRegistry, StateReconciler]:
    """Three fake sessions in distinct dirs, all idle (E2E preconditions)."""
    registry = SessionRegistry()
    reconciler = StateReconciler(registry)
    for sid in ("projA", "projB", "projC"):
        seed_idle(sid, registry, CLOCK)
    return registry, reconciler


def _column_of(placed: dict[Column, list[Card]], session_id: str) -> Column:
    """The single column a session's card landed in (one card per session)."""
    return next(col for col, cards in placed.items()
               for card in cards if card.session_id == session_id)


def test_tc_e2e_001_sessions_appear_as_cards_placed_by_state(seeded):
    """TC-E2E-001: one card per session, each in its correct state column."""
    registry, reconciler = seeded
    drive("projA", ["running"], reconciler, CLOCK)
    drive("projB", ["running", "waiting-for-input"], reconciler, CLOCK)

    cards = _all_cards(registry)
    placed = place(cards)

    # Exactly three cards, no duplicates.
    assert len(cards) == 3
    placed_ids = [c.session_id for cards in placed.values() for c in cards]
    assert sorted(placed_ids) == ["projA", "projB", "projC"]

    assert _column_of(placed, "projA") is Column.RUNNING
    assert _column_of(placed, "projB") is Column.WAITING_FOR_INPUT
    assert _column_of(placed, "projC") is Column.IDLE


def test_tc_e2e_001_each_card_carries_cmux_metadata(seeded):
    """TC-E2E-001: cards show dir, agent=Claude, flow tag B, and current state."""
    registry, reconciler = seeded
    drive("projB", ["running", "waiting-for-input"], reconciler, CLOCK)

    card = _card_for(registry, "projB")
    assert card.project_dir == "~/proj-b"
    assert card.agent is Agent.CLAUDE
    assert card.flow is Flow.B
    assert card.state is SessionState.WAITING_FOR_INPUT


def test_tc_e2e_002_who_needs_me_count_reflects_blockers(seeded):
    """TC-E2E-002: count == waiting+blocked; projC (idle) is never counted."""
    registry, reconciler = seeded
    drive("projA", ["running"], reconciler, CLOCK)
    drive("projB", ["running", "waiting-for-input"], reconciler, CLOCK)

    # End state of TC-E2E-001: only projB waits.
    assert attention_count(_all_cards(registry)) == 1

    # projA running → blocked: now two sessions need attention.
    drive("projA", ["blocked"], reconciler, CLOCK + timedelta(seconds=10))
    needing = attention_cards(_all_cards(registry))

    assert attention_count(_all_cards(registry)) == 2
    assert {c.session_id for c in needing} == {"projA", "projB"}
    assert "projC" not in {c.session_id for c in needing}


def test_tc_e2e_002_quiet_when_all_running_or_idle(seeded):
    """TC-E2E-002: resolving every blocker reads exactly 0 — no false alarm (AC#3)."""
    registry, reconciler = seeded
    drive("projA", ["running", "blocked"], reconciler, CLOCK)
    drive("projB", ["running", "waiting-for-input"], reconciler, CLOCK)
    assert attention_count(_all_cards(registry)) == 2

    # Resolve both: projA blocked→running, projB waiting→running.
    drive("projA", ["running"], reconciler, CLOCK + timedelta(seconds=20))
    drive("projB", ["running"], reconciler, CLOCK + timedelta(seconds=20))

    cards = _all_cards(registry)
    assert attention_count(cards) == 0
    assert attention_cards(cards) == []


def test_tc_e2e_004_ambiguous_signal_shows_unknown_not_a_guess(seeded):
    """TC-E2E-004: running then silence past the threshold → unknown, not a guess."""
    registry, reconciler = seeded
    drive("projC", ["running", GO_SILENT], reconciler, CLOCK)

    card = _card_for(registry, "projC")
    placed = place(_all_cards(registry))

    assert card.state is SessionState.UNKNOWN
    assert _column_of(placed, "projC") is Column.UNKNOWN
    # Never left confidently running, never invented a clean exit.
    assert card.state is not SessionState.RUNNING
    assert card.state is not SessionState.DONE


def test_tc_e2e_005_clean_exit_lands_in_done_column(seeded):
    """Bonus: a clean stop hook lands the card in ``done`` (not stale/unknown)."""
    registry, reconciler = seeded
    drive("projA", ["running", "done"], reconciler, CLOCK)

    card = _card_for(registry, "projA")
    placed = place(_all_cards(registry))

    assert card.state is SessionState.DONE
    assert _column_of(placed, "projA") is Column.DONE


def test_fixture_spends_no_quota_only_in_process_signals(seeded):
    """Guardrail: the fixture drives purely in-process — no agent, no network."""
    registry, reconciler = seeded
    agent = drive("projA", ["running"], reconciler, CLOCK)

    # The driver only ever touched the injected reconciler/registry.
    assert agent.session_id == "projA"
    assert registry.get("projA").state is SessionState.RUNNING
