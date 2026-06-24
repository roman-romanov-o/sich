"""Dependency-injectable stub/fixture sources (no real I/O).

These satisfy :class:`QuotaSource` for tests and for wiring the aggregator
before real provider adapters exist. The interactive source derives its reading
from the pure :func:`interactive_remaining` math.
"""

from dataclasses import dataclass, field
from datetime import datetime

from mission_control.quota.models import PoolState, RefillKind, SourceReading
from mission_control.quota.window_math import (
    UsageEvent,
    Window,
    interactive_remaining,
)


@dataclass(frozen=True)
class StubSource:
    """Returns a fixed, injected reading. The simplest source."""

    provider: str
    pool: str
    reading: SourceReading

    def read(self) -> SourceReading:
        return self.reading


@dataclass(frozen=True)
class InteractiveWindowSource:
    """Interactive Anthropic pool, derived from window math (inferred).

    Remaining is computed, not measured, so the reading is always
    ``inferred=True`` — confidence display is a hard requirement (US-006 AC#3).
    """

    now: datetime
    window: Window
    weekly_cap: float
    usage: list[UsageEvent] = field(default_factory=list)
    weekly_used: float = 0.0
    weekly_reset: datetime | None = None
    provider: str = "anthropic"
    pool: str = "interactive"

    def read(self) -> SourceReading:
        result = interactive_remaining(
            usage=self.usage,
            now=self.now,
            window=self.window,
            weekly_cap=self.weekly_cap,
            weekly_used=self.weekly_used,
            weekly_reset=self.weekly_reset,
        )
        exhausted = result.remaining_fraction <= 0.0
        return SourceReading(
            available=True,
            inferred=True,
            remaining_fraction=result.remaining_fraction,
            reset=result.reset,
            refill_kind=RefillKind.ROLLING_WINDOW,
            state=PoolState.EXHAUSTED if exhausted else PoolState.ACTIVE,
        )


@dataclass(frozen=True)
class AgentSdkCreditSource:
    """Agent SDK credit balance — measured, monthly hard-stop, no fallback."""

    balance: float
    cap: float
    reset: datetime
    unit: str = "USD"
    provider: str = "anthropic"
    pool: str = "agent_sdk_credit"

    def read(self) -> SourceReading:
        exhausted = self.balance <= 0.0
        return SourceReading(
            available=True,
            inferred=False,
            remaining_amount=self.balance,
            remaining_fraction=max(0.0, min(1.0, self.balance / self.cap)),
            unit=self.unit,
            reset=self.reset,
            refill_kind=RefillKind.MONTHLY_HARD_STOP,
            state=PoolState.EXHAUSTED if exhausted else PoolState.ACTIVE,
        )


@dataclass(frozen=True)
class AbsentSource:
    """A provider with no usable signal this cycle → unknown (TC-INT-103)."""

    provider: str
    pool: str

    def read(self) -> SourceReading:
        return SourceReading(available=False, inferred=True)
