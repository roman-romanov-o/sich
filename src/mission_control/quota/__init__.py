"""Two-pool quota model (US-006 / Phase 04).

Models the heterogeneous quota pools a parallel-agent user draws on as
independent gauges. The two Anthropic pools — interactive (5h rolling window +
weekly cap) and the separate Agent SDK credit (monthly hard-stop, no fallback) —
do *not* fungibly trade, so they are never netted against each other.

Pure and dependency-injected: no network, no provider calls, no system-clock
read. The interactive window math takes the clock as a parameter.
"""

from mission_control.quota.aggregator import QuotaAggregator
from mission_control.quota.models import (
    Confidence,
    PoolGauge,
    PoolState,
    RefillKind,
    SourceReading,
)
from mission_control.quota.window_math import (
    UsageEvent,
    Window,
    WindowResult,
    interactive_remaining,
)

__all__ = [
    "Confidence",
    "PoolGauge",
    "PoolState",
    "QuotaAggregator",
    "RefillKind",
    "SourceReading",
    "UsageEvent",
    "Window",
    "WindowResult",
    "interactive_remaining",
]
