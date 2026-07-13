# Research: Existing time/capacity surfaces a calendar feature would touch

**Date:** 2026-07-08
**Status:** Complete
**Researcher:** Sahaidachny Research Agent

## Summary

The app already models time-bounded capacity for machine pools — quota gauges carry `reset: Date?` with `windowReset`/`weeklyReset` refill kinds, rendered as reset lines in the quota panel, and a pure `QuotaAdvisor` turns gauges into a routing recommendation. A calendar boundary is structurally the same shape for the *human* pool: a "resource unavailable until T" reading. The in-process poller pattern (`NativeQuotaPoller`) is the established way to ingest a new periodic source without violating watcher-not-spawner.

## Research Questions

1. Where does the app already reason about future time boundaries?
2. What ingestion patterns exist for a new data source?
3. Where would a calendar signal surface in the UI?

## Key Findings

### 1. Quota model already speaks "capacity that refills at a future instant"

**Evidence:** `app/Sources/GhostlingCore/QuotaGauge.swift:38-39,52`

```swift
case windowReset = "window_reset"
case weeklyReset = "weekly_reset"
...
public let reset: Date?
```

**Implication:** The two Anthropic pools are modeled as depletable resources with known refill instants. Human attention is the third scarce resource (task-02's core thesis: attention, not tokens, is the binding constraint) and a calendar busy-block is its "depleted until `Date`" reading. A `HumanAvailability` reading can mirror the `QuotaSourceInput`/gauge shape — including the confidence labeling (measured vs. user-attested vs. unknown) the quota stack already has (`ConfidenceKind` in QuotaGauge.swift:3).

### 2. The panel already renders future-instant lines — the natural home for "free until"

**Evidence:** `app/Sources/GhostlingApp/QuotaGaugeRow.swift:48-97` (`resetText`, `resetLine()` rendering); `app/Sources/GhostlingCore/QuotaRecommendation.swift` (`QuotaAdvisor.recommend` — pure, unit-testable, four-branch heuristic over the two Anthropic pools).

**Implication:** Two cheap, high-visibility integration points already exist:
- a gauge-row-style line in the capacity panel ("You: free until 14:00 · then busy 45m", or "You: availability unknown");
- `QuotaAdvisor`'s `detail`/`headline` seam — its doc comment says the future allocator "upgrades `QuotaAdvisor.recommend` in place; the `action`/`headline`/`detail` shape is the stable seam the panel renders". A launch recommendation that ignores an imminent hard boundary is exactly what task-06 forbids ("Focus work must fit before the next busy block").

### 3. The ingestion pattern is established: in-process poll, off-main-actor read, main-actor sink

**Evidence:** `app/Sources/GhostlingApp/QuotaSidecar.swift` — `NativeQuotaPoller` (15s timer, walks `~/.claude/projects/**/*.jsonl` off the main actor, `inFlight` guard so slow ticks never stack, delivers `[QuotaSourceInput]` to a main-actor sink; "Watcher-not-spawner: it never spawns `claude -p` and binds no port").

**Implication:** A calendar provider should be `NativeQuotaPoller`-shaped: a `CalendarAvailabilityPoller` producing `[BusyInterval]`/`AvailabilityReading` on a timer (EventKit also offers `EKEventStoreChanged` notifications, better than polling). No sidecar, no HTTP, no subprocess — matching the post-cutover "no Python receiver" architecture.

### 4. Session/card timing exists but is backward-looking only

**Evidence:** `app/Sources/GhostlingCore/SessionSnapshot.swift:15` (`createdAt`), `app/Sources/GhostlingCore/BoardCard.swift:70-75` (`updatedAt` — "the freshness key the board ranks by"), `app/Sources/GhostlingCore/Attention.swift:10-16` (`Attention` counts cards whose `state.needsAttention`).

**Implication:** The board knows *what needs attention now* and *how stale things are*, but has no notion of *when the human stops being available*. Calendar data is the first forward-looking human-side input. The `Attention` count + next-boundary pairing ("3 cards need you, and you have 40 min before standup") is the smallest genuinely useful composition.

### 5. Precedent for parsing/handling reset instants and timezone-safe date math

**Evidence:** `app/Sources/GhostlingCore/ClaudeUsagePanel.swift:36-115` — `parseReset(_:now:calendar:)` resolves ambiguous "resets 3pm" strings against `Foundation.Calendar` with injected `now`/`calendar` for testability.

**Implication:** The codebase's convention is pure functions with injected clocks/calendars — the calendar-availability math (union of busy intervals, half-open windows, "free until" derivation per task-06 §6.2) should follow the same pattern in `GhostlingCore`, fully testable without EventKit.

## Validated Assumptions

| Assumption | Status | Evidence |
|------------|--------|----------|
| Capacity planning is already time-based (quota resets) | Confirmed | `QuotaGauge.swift:38-52`, `QuotaGaugeRow.swift:48-97` |
| A quota sidecar process would need extending | Incorrect | Sidecar is gone; quota is read in-process (`QuotaSidecar.swift` header: "no sidecar, no HTTP (DD-001)") |
| There is an existing recommendation seam to plug availability into | Confirmed | `QuotaRecommendation.swift` — `QuotaAdvisor` documented as the upgrade-in-place seam |
| Sessions carry timing usable for scheduling | Partial | Only `createdAt`/`updatedAt` freshness; no duration/forecast model yet (task-02 still in Planning) |

## Risks Identified

### 1. Two-pool invariant contamination (Severity: Low)

**Description:** Human availability must be a *third, separate* reading — never netted against or blended into the two Anthropic pool gauges (the "never-single-pool" invariant is enforced in `QuotaProjection`/`QuotaAdvisor`).

**Mitigation:** Model availability as its own type, not a `QuotaGauge`; only the advisor composes them.

### 2. "No silent zeros" discipline (Severity: Medium)

**Description:** The quota stack visibly labels unknown sources. If calendar permission is denied or data is stale, a blank/absent line reads as "no meetings" — precisely the false claim task-06 §13 forbids.

**Mitigation:** Availability reading must carry freshness + permission state and render an explicit "unknown" state, mirroring `QuotaGauge`'s `isUnknown` handling.

## Open Questions

- [ ] Poll vs. `EKEventStoreChanged` notification — notification is cheaper and fresher; verify it fires reliably for delegate/subscribed (Google) calendars.
- [ ] Where exactly in `QuotaPanel`/`QuotaShell` the availability row lives (needs the designer agent once stories exist).

## Recommendations

Build the calendar feature as: pure interval math in `GhostlingCore` (injected clock, task-06 §6.2 semantics) + an EventKit-backed provider in `GhostlingApp` following the `NativeQuotaPoller` shape + one availability row in the capacity panel + a one-line upgrade to `QuotaAdvisor.recommend` ("hold: busy in 10m"). Everything is read-only; nothing spawns.

## References

- `app/Sources/GhostlingCore/QuotaGauge.swift`, `QuotaRecommendation.swift`, `ClaudeUsagePanel.swift`
- `app/Sources/GhostlingApp/QuotaSidecar.swift`, `QuotaGaugeRow.swift`
- `docs/tasks/task-06-proactive-mission-control/task-description.md` §6.2
