"""In-process fake-agent fixture — drives sessions without spending quota.

The E2E harness note (test-specs) requires a fixture that emits the *same* hook
events a real Claude run would, fed through the *real*
:class:`StateReconciler` into a shared :class:`SessionRegistry`. There is no
``claude`` process, no network, no PTY — just scripted :class:`SignalEvent`s, so
the suite is deterministic and never burns the pool.

A script is an ordered list of target-state names (the E2E test data shape,
e.g. ``["running", "waiting-for-input"]``). Each target is realized by the
:class:`SignalKind` that classifies to it, stamped with a deterministic,
caller-controlled clock. The sentinel :data:`GO_SILENT` advances the clock past
the stale threshold so ``unknown``/stale can be exercised via the reconciler's
:meth:`tick`.
"""

from collections.abc import Iterable
from datetime import datetime, timedelta

from mission_control.detector.events import (
    SessionState,
    SignalEvent,
    SignalKind,
    SignalSource,
)
from mission_control.detector.reconciler import StateReconciler
from mission_control.detector.registry import SessionRegistry

# Sentinel script step: the fixture stops emitting and time passes (zombie path).
GO_SILENT = "go-silent"

# Target state name → the hook signal that classifies to it. Each target is
# reachable absolutely (independent of prior state) except the waiting→running
# resume, which USER_INPUT covers; TOOL_USE also lands running from any prior.
_TARGET_KIND: dict[str, SignalKind] = {
    SessionState.IDLE.value: SignalKind.UNKNOWN,
    SessionState.RUNNING.value: SignalKind.TOOL_USE,
    SessionState.WAITING_FOR_INPUT.value: SignalKind.PERMISSION_REQUEST,
    SessionState.RUNNING_TESTS.value: SignalKind.TEST_RUN_START,
    SessionState.BLOCKED.value: SignalKind.ERROR_EXIT,
    SessionState.DONE.value: SignalKind.STOP,
}


class FakeAgent:
    """A scripted, quota-free driver for one session into a shared registry.

    Holds the session identity and the injected clock; :meth:`drive` plays a
    script of target states (and ``GO_SILENT`` gaps) through the supplied
    reconciler, exactly as a real run's hooks would.
    """

    def __init__(
        self,
        session_id: str,
        reconciler: StateReconciler,
        clock: datetime,
        step: timedelta = timedelta(seconds=1),
        silence_gap: timedelta = timedelta(seconds=31),
    ) -> None:
        self.session_id = session_id
        self._reconciler = reconciler
        self._clock = clock
        self._step = step
        self._silence_gap = silence_gap

    def drive(self, script: Iterable[str]) -> None:
        """Play ``script`` step by step, advancing the injected clock each step."""
        for target in script:
            if target == GO_SILENT:
                self._go_silent()
            else:
                self._emit_target(target)

    def _emit_target(self, target: str) -> None:
        """Realize one target state via its hook signal, then advance the clock."""
        kind = _TARGET_KIND[target]
        self._clock += self._step
        event = SignalEvent(
            kind=kind,
            source=SignalSource.HOOK,
            session_id=self.session_id,
            timestamp=self._clock,
        )
        self._reconciler.ingest(self.session_id, [event])

    def _go_silent(self) -> None:
        """Emit nothing; let time pass past the stale threshold and reap (tick)."""
        self._clock += self._silence_gap
        self._reconciler.tick(self.session_id, now=self._clock)


def drive(
    session_id: str,
    script: Iterable[str],
    reconciler: StateReconciler,
    clock: datetime,
    **kwargs: timedelta,
) -> FakeAgent:
    """Build a :class:`FakeAgent`, play ``script``, and return it for chaining."""
    agent = FakeAgent(session_id, reconciler, clock, **kwargs)
    agent.drive(script)
    return agent


def seed_idle(session_id: str, registry: SessionRegistry, clock: datetime) -> None:
    """Register a session as ``idle`` (the E2E preconditions seed three of these)."""
    registry.update(session_id, SessionState.IDLE, clock)


__all__ = ["GO_SILENT", "FakeAgent", "drive", "seed_idle"]
