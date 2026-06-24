"""TC-INT-101..104 — quota pool aggregation from heterogeneous sources."""

from datetime import UTC, datetime, timedelta

import pytest

from mission_control.quota.aggregator import QuotaAggregator
from mission_control.quota.models import (
    Confidence,
    PoolGauge,
    PoolState,
    RefillKind,
    SourceReading,
)
from mission_control.quota.sources import StubSource

pytestmark = pytest.mark.integration

T0 = datetime(2026, 6, 16, 12, 0, 0, tzinfo=UTC)


def _interactive_source(remaining=0.7, available=True, state=PoolState.ACTIVE):
    """Inferred interactive gauge (window math is not a clean API)."""
    return StubSource(
        provider="anthropic",
        pool="interactive",
        reading=SourceReading(
            remaining_fraction=remaining,
            inferred=True,
            available=available,
            reset=T0 + timedelta(hours=5),
            refill_kind=RefillKind.ROLLING_WINDOW,
            state=state,
        ),
    )


def _agent_sdk_source(remaining=0.4, available=True, state=PoolState.ACTIVE):
    """Precise (measured) Agent SDK credit balance."""
    return StubSource(
        provider="anthropic",
        pool="agent_sdk_credit",
        reading=SourceReading(
            remaining_amount=20.0 * remaining,
            unit="USD",
            inferred=False,
            available=available,
            reset=T0 + timedelta(days=14),
            refill_kind=RefillKind.MONTHLY_HARD_STOP,
            state=state,
        ),
    )


def _absent_gemini_source():
    """Gemini exposes no usable signal this cycle."""
    return StubSource(
        provider="google",
        pool="gemini",
        reading=SourceReading(available=False, inferred=True),
    )


@pytest.fixture
def quota_sources():
    """Precise Agent SDK, inferred interactive, absent Gemini."""
    return [
        _interactive_source(),
        _agent_sdk_source(),
        _absent_gemini_source(),
    ]


def _by_pool(gauges, pool):
    return next(g for g in gauges if g.pool == pool)


def test_tc_int_101_anthropic_pools_assembled_independently():
    """TC-INT-101: interactive and Agent SDK are separate, non-fungible gauges."""
    drained = QuotaAggregator(
        sources=[_interactive_source(remaining=0.0), _agent_sdk_source(remaining=0.4)]
    ).gauges()
    baseline = QuotaAggregator(
        sources=[_interactive_source(remaining=0.7), _agent_sdk_source(remaining=0.4)]
    ).gauges()

    drained_sdk = _by_pool(drained, "agent_sdk_credit")
    baseline_sdk = _by_pool(baseline, "agent_sdk_credit")

    # Draining interactive must not change Agent SDK remaining.
    assert drained_sdk.remaining_amount == baseline_sdk.remaining_amount
    assert _by_pool(drained, "interactive") is not drained_sdk
    assert {g.pool for g in drained} == {"interactive", "agent_sdk_credit"}


def test_tc_int_102_inferred_source_carries_confidence(quota_sources):
    """TC-INT-102: inferred → estimated, measured → measured."""
    gauges = QuotaAggregator(sources=quota_sources).gauges()

    assert _by_pool(gauges, "interactive").confidence == Confidence.ESTIMATED
    assert _by_pool(gauges, "agent_sdk_credit").confidence == Confidence.MEASURED


def test_tc_int_103_absent_source_is_unknown_not_zero_or_full(quota_sources):
    """TC-INT-103: absent Gemini → unknown, remaining is None (not 0, not 1.0)."""
    gauges = QuotaAggregator(sources=quota_sources).gauges()
    gemini = _by_pool(gauges, "gemini")

    assert gemini.state == PoolState.UNKNOWN
    assert gemini.remaining_fraction is None
    assert gemini.remaining_amount is None
    assert gemini.confidence == Confidence.ESTIMATED


def test_tc_int_104_exhausted_states_distinguished_by_refill():
    """TC-INT-104: Agent SDK hard-stop/no-fallback vs. interactive window reset."""
    sources = [
        _interactive_source(remaining=0.0, state=PoolState.EXHAUSTED),
        _agent_sdk_source(remaining=0.0, state=PoolState.EXHAUSTED),
    ]
    gauges = QuotaAggregator(sources=sources).gauges()

    sdk = _by_pool(gauges, "agent_sdk_credit")
    interactive = _by_pool(gauges, "interactive")

    assert sdk.state == PoolState.EXHAUSTED
    assert sdk.refill_kind == RefillKind.MONTHLY_HARD_STOP
    assert sdk.fallback == "none"

    assert interactive.state == PoolState.EXHAUSTED
    assert interactive.refill_kind == RefillKind.ROLLING_WINDOW
    assert interactive.reset is not None


def test_gauges_are_pool_gauge_models(quota_sources):
    gauges = QuotaAggregator(sources=quota_sources).gauges()
    assert all(isinstance(g, PoolGauge) for g in gauges)
    assert len(gauges) == 3
