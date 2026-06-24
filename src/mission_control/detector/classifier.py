"""Pure state-classification function (TC-UNIT-001..003 + the spec table).

The heart of US-004: map ``(prior_state, signal)`` to the next state. No I/O, no
clock read, no mocks — just the fiddly branching the spec enumerates. Ambiguous
or contradictory signals MUST yield :attr:`SessionState.UNKNOWN`, never a guess
(US-004 AC#3); ``StaleTimeout`` is never silently promoted to ``done``.
"""

from mission_control.detector.events import SessionState, SignalEvent, SignalKind

# Signals whose target state never depends on the prior state.
_ABSOLUTE: dict[SignalKind, SessionState] = {
    SignalKind.SESSION_START: SessionState.RUNNING,
    SignalKind.TOOL_USE: SessionState.RUNNING,
    SignalKind.PERMISSION_REQUEST: SessionState.WAITING_FOR_INPUT,
    SignalKind.TEST_RUN_START: SessionState.RUNNING_TESTS,
    SignalKind.ERROR_EXIT: SessionState.BLOCKED,
    SignalKind.STOP: SessionState.DONE,
    SignalKind.STALE_TIMEOUT: SessionState.UNKNOWN,
    SignalKind.CONTRADICTORY_SIGNALS: SessionState.UNKNOWN,
    SignalKind.UNKNOWN: SessionState.UNKNOWN,
}


def _kind_of(event: SignalEvent | SignalKind) -> SignalKind:
    """Accept either a raw kind or a full event (the reconciler passes events)."""
    return event if isinstance(event, SignalKind) else event.kind


def classify(prior: SessionState, event: SignalEvent | SignalKind) -> SessionState:
    """Return the next state for ``prior`` given a single normalized signal.

    ``UserInput`` resumes a waiting session to ``running``; on any non-waiting
    prior it leaves the state untouched rather than guessing. Every other signal
    maps absolutely via :data:`_ABSOLUTE`.
    """
    kind = _kind_of(event)

    if kind is SignalKind.USER_INPUT:
        return SessionState.RUNNING if prior is SessionState.WAITING_FOR_INPUT else prior

    return _ABSOLUTE.get(kind, SessionState.UNKNOWN)
