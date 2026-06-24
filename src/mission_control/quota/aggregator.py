"""Assemble quota sources into independent pool gauges.

Each source becomes its own :class:`PoolGauge`. Pools are never netted against
each other — the two Anthropic pools do not fungibly trade (``research/10``), so
draining one cannot change another's remaining (TC-INT-101).
"""

from dataclasses import dataclass

from mission_control.quota.models import (
    Confidence,
    Fallback,
    PoolGauge,
    PoolState,
    RefillKind,
    SourceReading,
)
from mission_control.quota.sources.base import QuotaSource

_FALLBACK_BY_REFILL: dict[RefillKind, Fallback] = {
    RefillKind.MONTHLY_HARD_STOP: "none",
    RefillKind.ROLLING_WINDOW: "window_reset",
    RefillKind.WEEKLY: "weekly_reset",
    RefillKind.UNKNOWN: "unknown",
}


def _confidence(reading: SourceReading) -> Confidence:
    """Inferred readings are estimated; measured ones are measured (AC#3)."""
    return Confidence.ESTIMATED if reading.inferred else Confidence.MEASURED


def _state(reading: SourceReading) -> PoolState:
    """An unavailable source is UNKNOWN; otherwise trust the source's state."""
    return PoolState.UNKNOWN if not reading.available else reading.state


def _to_gauge(source: QuotaSource, reading: SourceReading) -> PoolGauge:
    """Project one source's reading onto its own independent gauge.

    An absent source yields ``UNKNOWN`` with no remaining value — not 0, not
    100% (TC-INT-103).
    """
    state = _state(reading)
    if state is PoolState.UNKNOWN:
        return PoolGauge(
            provider=source.provider,
            pool=source.pool,
            state=PoolState.UNKNOWN,
            confidence=_confidence(reading),
        )
    return PoolGauge(
        provider=source.provider,
        pool=source.pool,
        state=state,
        confidence=_confidence(reading),
        refill_kind=reading.refill_kind,
        fallback=_FALLBACK_BY_REFILL[reading.refill_kind],
        remaining_fraction=reading.remaining_fraction,
        remaining_amount=reading.remaining_amount,
        unit=reading.unit,
        reset=reading.reset,
    )


@dataclass
class QuotaAggregator:
    """Reads a set of injected sources into independent pool gauges."""

    sources: list[QuotaSource]

    def gauges(self) -> list[PoolGauge]:
        """One gauge per source, in source order. No cross-pool arithmetic."""
        return [_to_gauge(s, s.read()) for s in self.sources]
