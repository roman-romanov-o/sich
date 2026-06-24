"""TC-UNIT-001..003 + the spec table — pure state classifier (no I/O, no mocks)."""

from datetime import UTC, datetime

import pytest

from mission_control.detector.classifier import classify
from mission_control.detector.events import (
    SessionState,
    SignalEvent,
    SignalKind,
    SignalSource,
)

pytestmark = pytest.mark.unit


def test_tc_unit_001_permission_request_to_waiting_for_input():
    """TC-UNIT-001: running + PermissionRequest → waiting-for-input."""
    assert (
        classify(SessionState.RUNNING, SignalKind.PERMISSION_REQUEST)
        is SessionState.WAITING_FOR_INPUT
    )


def test_tc_unit_002_stop_to_done():
    """TC-UNIT-002: running + Stop → done."""
    assert classify(SessionState.RUNNING, SignalKind.STOP) is SessionState.DONE


def test_tc_unit_003_stale_timeout_to_unknown_never_done():
    """TC-UNIT-003: running + StaleTimeout → unknown (never invented done)."""
    result = classify(SessionState.RUNNING, SignalKind.STALE_TIMEOUT)

    assert result is SessionState.UNKNOWN
    assert result is not SessionState.DONE


@pytest.mark.parametrize(
    ("prior", "event", "expected"),
    [
        (SessionState.IDLE, SignalKind.SESSION_START, SessionState.RUNNING),
        (SessionState.RUNNING, SignalKind.TOOL_USE, SessionState.RUNNING),
        (
            SessionState.RUNNING,
            SignalKind.PERMISSION_REQUEST,
            SessionState.WAITING_FOR_INPUT,
        ),
        (SessionState.WAITING_FOR_INPUT, SignalKind.USER_INPUT, SessionState.RUNNING),
        (SessionState.RUNNING, SignalKind.TEST_RUN_START, SessionState.RUNNING_TESTS),
        (SessionState.RUNNING, SignalKind.ERROR_EXIT, SessionState.BLOCKED),
        (SessionState.RUNNING, SignalKind.STOP, SessionState.DONE),
        (SessionState.RUNNING, SignalKind.STALE_TIMEOUT, SessionState.UNKNOWN),
        (
            SessionState.RUNNING,
            SignalKind.CONTRADICTORY_SIGNALS,
            SessionState.UNKNOWN,
        ),
    ],
    ids=[
        "start",
        "stays-running",
        "needs-human",
        "resumed",
        "tests",
        "crash",
        "clean-finish",
        "stale-no-guess",
        "conflict",
    ],
)
def test_classifier_table(prior, event, expected):
    """The exact mapping table from the unit spec."""
    assert classify(prior, event) is expected


@pytest.mark.parametrize(
    "prior",
    [
        SessionState.IDLE,
        SessionState.RUNNING,
        SessionState.WAITING_FOR_INPUT,
        SessionState.RUNNING_TESTS,
        SessionState.BLOCKED,
        SessionState.DONE,
        SessionState.UNKNOWN,
    ],
)
def test_contradictory_signals_always_unknown(prior):
    """`any + ContradictorySignals → unknown`, regardless of prior state."""
    assert (
        classify(prior, SignalKind.CONTRADICTORY_SIGNALS) is SessionState.UNKNOWN
    )


def test_classify_accepts_full_signal_event():
    """The reconciler passes whole events; classify reads only their kind."""
    event = SignalEvent(
        kind=SignalKind.STOP,
        source=SignalSource.HOOK,
        session_id="s1",
        timestamp=datetime(2026, 6, 16, 12, 0, tzinfo=UTC),
    )
    assert classify(SessionState.RUNNING, event) is SessionState.DONE


def test_user_input_outside_waiting_does_not_guess():
    """UserInput on a non-waiting prior leaves state untouched, no guess."""
    assert classify(SessionState.RUNNING, SignalKind.USER_INPUT) is SessionState.RUNNING
    assert classify(SessionState.IDLE, SignalKind.USER_INPUT) is SessionState.IDLE
