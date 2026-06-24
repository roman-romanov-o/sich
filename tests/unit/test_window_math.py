"""TC-UNIT-101..104 — interactive-pool window math (pure, clock injected)."""

from datetime import UTC, datetime, timedelta

import pytest

from mission_control.quota.window_math import (
    UsageEvent,
    Window,
    interactive_remaining,
)

pytestmark = pytest.mark.unit

T0 = datetime(2026, 6, 16, 12, 0, 0, tzinfo=UTC)
WINDOW = timedelta(hours=5)
WINDOW_CAP = 100.0
WEEKLY_CAP = 1000.0


def _eval(usage, now, weekly_used=0.0):
    """Run the pure function with the standard fixed window/caps."""
    return interactive_remaining(
        usage=usage,
        now=now,
        window=Window(duration=WINDOW, cap=WINDOW_CAP),
        weekly_cap=WEEKLY_CAP,
        weekly_used=weekly_used,
    )


def test_tc_unit_101_fresh_window_near_full():
    """TC-UNIT-101: empty usage → ~100% remaining, reset = now + window."""
    result = _eval(usage=[], now=T0)

    assert result.remaining_fraction == pytest.approx(1.0)
    assert result.window_reset == T0 + WINDOW
    assert result.bound_by != "weekly"


def test_tc_unit_102_usage_ages_out_of_window():
    """TC-UNIT-102: a spike at T0 no longer counts at T0+5h01m."""
    spike = [UsageEvent(at=T0, amount=80.0)]

    inside = _eval(usage=spike, now=T0 + timedelta(hours=1))
    aged_out = _eval(usage=spike, now=T0 + timedelta(hours=5, minutes=1))

    assert inside.remaining_fraction == pytest.approx(0.20)
    assert aged_out.remaining_fraction == pytest.approx(1.0)
    assert aged_out.remaining_fraction > inside.remaining_fraction


def test_tc_unit_103_weekly_cap_dominates_when_window_fresh():
    """TC-UNIT-103: fresh window but weekly near cap → bound by weekly."""
    result = _eval(usage=[], now=T0, weekly_used=950.0)

    # 50 of 1000 weekly left = 0.05; window is full (1.0) → min is weekly.
    assert result.remaining_fraction == pytest.approx(0.05)
    assert result.bound_by == "weekly"


def test_tc_unit_104_reset_is_earliest_binding_reset():
    """TC-UNIT-104: reported reset = sooner-to-bind of window/weekly."""
    spike = [UsageEvent(at=T0, amount=40.0)]
    now = T0 + timedelta(hours=1)
    result = interactive_remaining(
        usage=spike,
        now=now,
        window=Window(duration=WINDOW, cap=WINDOW_CAP),
        weekly_cap=WEEKLY_CAP,
        weekly_used=200.0,
        weekly_reset=now + timedelta(days=2),
    )

    # window reset (event_at + 5h) is sooner than weekly reset (+2 days).
    expected_window_reset = T0 + WINDOW
    assert result.window_reset == expected_window_reset
    assert result.reset == expected_window_reset
    assert result.reset < now + timedelta(days=2)


@pytest.mark.parametrize(
    ("usage", "now", "weekly_used", "expected_basis", "expected_fraction"),
    [
        ([], T0, 0.0, "window", 1.0),
        ([UsageEvent(at=T0, amount=50.0)], T0 + timedelta(hours=1), 0.0, "window", 0.5),
        (
            [UsageEvent(at=T0, amount=50.0)],
            T0 + timedelta(hours=5, minutes=1),
            0.0,
            "window",
            1.0,
        ),
        ([], T0, 900.0, "weekly", 0.10),
        (
            [UsageEvent(at=T0, amount=30.0)],
            T0 + timedelta(hours=1),
            500.0,
            "weekly",
            0.50,
        ),
    ],
    ids=["fresh", "within-window", "aged-out", "weekly-bound", "both-partial"],
)
def test_window_math_table(usage, now, weekly_used, expected_basis, expected_fraction):
    """Parameterized table from the spec."""
    result = _eval(usage=usage, now=now, weekly_used=weekly_used)

    assert result.bound_by == expected_basis
    assert result.remaining_fraction == pytest.approx(expected_fraction)
