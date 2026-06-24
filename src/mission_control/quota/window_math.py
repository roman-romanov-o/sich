"""Pure interactive-pool window math (TC-UNIT-101..104).

Computes remaining capacity for a 5-hour **rolling window** plus a **weekly
cap**, and the earliest binding reset. The clock is injected via ``now`` — this
module never reads the system clock, keeping it deterministic and testable.
"""

from datetime import datetime, timedelta
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

BoundBy = Literal["window", "weekly"]


class UsageEvent(BaseModel):
    """A single usage spike charged against the rolling window."""

    model_config = ConfigDict(frozen=True)

    at: datetime
    amount: float = Field(ge=0.0)


class Window(BaseModel):
    """A rolling-window definition: how long events count, and its cap."""

    model_config = ConfigDict(frozen=True)

    duration: timedelta
    cap: float = Field(gt=0.0)


class WindowResult(BaseModel):
    """Output of :func:`interactive_remaining`."""

    model_config = ConfigDict(frozen=True)

    remaining_fraction: float
    bound_by: BoundBy
    reset: datetime
    window_reset: datetime
    weekly_reset: datetime | None = None


def _active_window_usage(usage: list[UsageEvent], now: datetime, duration: timedelta) -> float:
    """Sum usage whose age is still inside the rolling window at ``now``."""
    cutoff = now - duration
    return sum(e.amount for e in usage if e.at > cutoff)


def _window_reset(usage: list[UsageEvent], now: datetime, duration: timedelta) -> datetime:
    """When the window first frees capacity = oldest in-window event ages out.

    With no active usage the window is fresh, so it resets a full duration out.
    """
    cutoff = now - duration
    in_window = [e.at for e in usage if e.at > cutoff]
    if not in_window:
        return now + duration
    return min(in_window) + duration


def _fraction(remaining: float, cap: float) -> float:
    """Clamp ``remaining / cap`` to ``[0.0, 1.0]``."""
    return max(0.0, min(1.0, remaining / cap))


def interactive_remaining(
    usage: list[UsageEvent],
    now: datetime,
    window: Window,
    weekly_cap: float,
    weekly_used: float = 0.0,
    weekly_reset: datetime | None = None,
) -> WindowResult:
    """Remaining interactive capacity, bound by whichever cap is tighter.

    The window and weekly cap are independent constraints; effective remaining
    is the smaller of the two fractions. The reported reset is the sooner of the
    two relevant resets — but only the binding constraint(s) can move it.
    """
    window_used = _active_window_usage(usage, now, window.duration)
    window_fraction = _fraction(window.cap - window_used, window.cap)
    weekly_fraction = _fraction(weekly_cap - weekly_used, weekly_cap)

    win_reset = _window_reset(usage, now, window.duration)
    bound_by: BoundBy = "weekly" if weekly_fraction < window_fraction else "window"
    remaining_fraction = min(window_fraction, weekly_fraction)
    reset = _binding_reset(bound_by, win_reset, weekly_reset)

    return WindowResult(
        remaining_fraction=remaining_fraction,
        bound_by=bound_by,
        reset=reset,
        window_reset=win_reset,
        weekly_reset=weekly_reset,
    )


def _binding_reset(
    bound_by: BoundBy, window_reset: datetime, weekly_reset: datetime | None
) -> datetime:
    """Earliest reset that relieves the binding constraint (TC-UNIT-104)."""
    if bound_by == "weekly" and weekly_reset is not None:
        return weekly_reset
    if weekly_reset is None:
        return window_reset
    return min(window_reset, weekly_reset)
