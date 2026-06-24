"""Pydantic V2 models for the two-pool quota gauge.

A ``PoolGauge`` is the pure data structure a UI would render; this layer never
draws anything. An absent source becomes ``state=UNKNOWN`` with no remaining
value — explicitly *not* 0 and *not* 100% (TC-INT-103).
"""

from datetime import datetime
from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, ConfigDict


class Confidence(StrEnum):
    """Whether a remaining value is observed or derived (window math)."""

    MEASURED = "measured"
    ESTIMATED = "estimated"


class PoolState(StrEnum):
    """Coarse availability of a pool."""

    ACTIVE = "active"
    EXHAUSTED = "exhausted"
    UNKNOWN = "unknown"


class RefillKind(StrEnum):
    """How a pool replenishes — drives how the UI warns on exhaustion.

    The Agent SDK credit is a monthly hard-stop with no interactive fallback;
    the interactive pool replenishes as usage ages out of the rolling window
    (and on the weekly reset). These differ, so they are modeled distinctly
    (TC-INT-104).
    """

    MONTHLY_HARD_STOP = "monthly_hard_stop"
    ROLLING_WINDOW = "rolling_window"
    WEEKLY = "weekly"
    UNKNOWN = "unknown"


# What a pool falls back to once exhausted. ``"none"`` = hard-stop (Agent SDK).
Fallback = Literal["none", "window_reset", "weekly_reset", "unknown"]


class SourceReading(BaseModel):
    """The typed value a quota source adapter returns.

    Carries availability and the inferred flag so the aggregator can map them to
    pool state and confidence without re-deciding policy per source.
    """

    model_config = ConfigDict(frozen=True)

    available: bool = True
    inferred: bool = False
    remaining_fraction: float | None = None
    remaining_amount: float | None = None
    unit: str | None = None
    reset: datetime | None = None
    refill_kind: RefillKind = RefillKind.UNKNOWN
    state: PoolState = PoolState.ACTIVE


class PoolGauge(BaseModel):
    """An independent, renderable gauge for a single quota pool.

    Never combined with another pool — the two Anthropic pools do not fungibly
    trade (``research/10``), so no arithmetic nets one against another.
    """

    model_config = ConfigDict(frozen=True)

    provider: str
    pool: str
    state: PoolState
    confidence: Confidence
    refill_kind: RefillKind = RefillKind.UNKNOWN
    fallback: Fallback = "unknown"
    remaining_fraction: float | None = None
    remaining_amount: float | None = None
    unit: str | None = None
    reset: datetime | None = None
