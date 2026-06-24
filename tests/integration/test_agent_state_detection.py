"""TC-INT-001..004 — agent state detection against recorded fixtures (no live agent).

Each fixture line is a recorded Claude Code signal carrying a ``source`` field
(``hook`` or ``jsonl``); we route it through the matching normalizer and drive
the reconciler. The clock is supplied explicitly, never read from the system.
"""

import json
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from mission_control.detector.events import (
    SessionState,
    SignalEvent,
    SignalSource,
)
from mission_control.detector.hook_receiver import normalize_hook
from mission_control.detector.jsonl_tail import normalize_jsonl
from mission_control.detector.reconciler import StateReconciler
from mission_control.detector.registry import SessionRegistry

pytestmark = pytest.mark.integration

FIXTURES = Path(__file__).parent.parent / "fixtures" / "claude_hooks"


def _normalize_record(record: dict) -> SignalEvent:
    """Route a fixture line to its source-specific normalizer."""
    if record.get("source") == "jsonl":
        return normalize_jsonl(record)
    return normalize_hook(record)


def _load(name: str) -> list[SignalEvent]:
    """Load a recorded fixture as an ordered list of normalized events."""
    lines = FIXTURES.joinpath(name).read_text().splitlines()
    return [_normalize_record(json.loads(line)) for line in lines if line.strip()]


def _states(reconciler: StateReconciler, session_id: str) -> list[SessionState]:
    """The emitted state path for a session, in order."""
    return [t.state for t in reconciler.transitions_for(session_id)]


def test_tc_int_001_hooks_drive_correct_transitions():
    """TC-INT-001: canonical hook sequence → running→waiting→running→done."""
    events = _load("normal_turn.jsonl")
    reconciler = StateReconciler(SessionRegistry())

    reconciler.ingest("sess-normal", events)

    # session-start→running, tool-use stays running (no-op, not re-emitted),
    # permission→waiting, tool-use→running, stop→done.
    assert _states(reconciler, "sess-normal") == [
        SessionState.RUNNING,
        SessionState.WAITING_FOR_INPUT,
        SessionState.RUNNING,
        SessionState.DONE,
    ]


def test_tc_int_001_waiting_entered_exactly_on_permission_request():
    """TC-INT-001: waiting-for-input is entered precisely at the permission event."""
    events = _load("normal_turn.jsonl")
    reconciler = StateReconciler(SessionRegistry())

    reconciler.ingest("sess-normal", events)

    waiting = [t for t in reconciler.transitions_for("sess-normal")
               if t.state is SessionState.WAITING_FOR_INPUT]
    assert len(waiting) == 1
    assert waiting[0].at == datetime(2026, 6, 16, 12, 0, 10, tzinfo=UTC)
    assert waiting[0].source is SignalSource.HOOK


def test_tc_int_002_dropped_stop_reconciled_to_done_via_jsonl():
    """TC-INT-002: stop hook omitted; JSONL turn-completed converges to done."""
    events = _load("dropped_stop.jsonl")
    registry = SessionRegistry()
    reconciler = StateReconciler(registry)

    reconciler.ingest("sess-dropped", events)

    final = registry.get("sess-dropped").state
    assert final is SessionState.DONE
    # Did not lock in running, and never emitted a wrong terminal blocked.
    assert final is not SessionState.RUNNING
    assert SessionState.BLOCKED not in _states(reconciler, "sess-dropped")


def test_tc_int_003_silence_past_threshold_is_unknown_not_running():
    """TC-INT-003: running then silence beyond threshold → unknown, never done."""
    events = _load("silent_after_running.jsonl")
    registry = SessionRegistry()
    reconciler = StateReconciler(registry, stale_threshold=timedelta(seconds=30))

    reconciler.ingest("sess-silent", events)
    assert registry.get("sess-silent").state is SessionState.RUNNING

    last_event_at = datetime(2026, 6, 16, 12, 0, 3, tzinfo=UTC)
    reconciler.tick("sess-silent", now=last_event_at + timedelta(seconds=31))

    final = registry.get("sess-silent").state
    assert final is SessionState.UNKNOWN
    assert final is not SessionState.RUNNING
    assert final is not SessionState.DONE


def test_tc_int_003_within_threshold_stays_running():
    """TC-INT-003 guard: silence still inside the threshold is not yet stale."""
    events = _load("silent_after_running.jsonl")
    registry = SessionRegistry()
    reconciler = StateReconciler(registry, stale_threshold=timedelta(seconds=30))

    reconciler.ingest("sess-silent", events)
    last_event_at = datetime(2026, 6, 16, 12, 0, 3, tzinfo=UTC)
    reconciler.tick("sess-silent", now=last_event_at + timedelta(seconds=10))

    assert registry.get("sess-silent").state is SessionState.RUNNING


def test_tc_int_004_rapid_transitions_coalesce_to_final_running():
    """TC-INT-004: sub-second running→waiting→running settles on running."""
    events = _load("rapid_transitions.jsonl")
    registry = SessionRegistry()
    reconciler = StateReconciler(registry, coalesce_window=timedelta(seconds=1))

    reconciler.ingest("sess-rapid", events)

    assert registry.get("sess-rapid").state is SessionState.RUNNING
    emitted = _states(reconciler, "sess-rapid")
    # Bounded, no flicker storm: the intermediate waiting is coalesced away.
    assert emitted == [SessionState.RUNNING]
    assert SessionState.WAITING_FOR_INPUT not in emitted


def test_tc_int_004_bounded_number_of_emitted_updates():
    """TC-INT-004: emissions are bounded well below the raw event count."""
    events = _load("rapid_transitions.jsonl")
    reconciler = StateReconciler(SessionRegistry(), coalesce_window=timedelta(seconds=1))

    reconciler.ingest("sess-rapid", events)

    assert len(reconciler.transitions_for("sess-rapid")) <= 2
    assert len(events) == 5


def test_final_state_written_to_registry_for_phase_03():
    """DoD: the reconciled state is observable on the registry."""
    events = _load("normal_turn.jsonl")
    registry = SessionRegistry()

    StateReconciler(registry).ingest("sess-normal", events)

    assert registry.states() == {"sess-normal": SessionState.DONE}
