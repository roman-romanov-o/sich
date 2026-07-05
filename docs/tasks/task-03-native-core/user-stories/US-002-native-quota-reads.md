# US-002: Native interactive-quota reads

**Status:** Draft
**Priority:** Critical
**Persona:** Capacity Planner
**Estimated Complexity:** M
**Last Updated:** 2026-06-26

## User Story

As a **capacity planner**,
I want the interactive-pool gauge **populated by Swift reading my Claude transcripts directly**,
So that **the two-pool panel works with no Python sidecar feeding it**.

## Description

Port `quota/jsonl_usage.py` + the source-assembly half of `quota/live.py` into a Swift
`QuotaUsageReader` (in `GhostlingCore`). It walks `~/.claude/projects/**/*.jsonl`, sums the
token usage on each `assistant` turn, ages the events to the 5h rolling window + weekly cap,
and produces the **same `[QuotaSourceInput]`** the existing `QuotaProjection` already consumes —
**in-process**, bypassing the `/quota` HTTP wire entirely. The projection math is **not** ported
(it already exists in Swift); only the source readings change origin.

## Acceptance Criteria

- [ ] **AC1 — same interactive reading:** For a fixed JSONL fixture + fixed `now`, the Swift
  reader yields the same interactive-pool `remainingFraction`/`remainingAmount`, `inferred=true`,
  and reset time as `live.build_quota_response()` does for the same input.
- [ ] **AC2 — same four sources, never netted:** The reader emits exactly four sources —
  interactive (estimated), Agent-SDK-credit / Codex / Gemini all **UNKNOWN** (not 0, not 100%) —
  and the projection still renders them as distinct, never-netted gauges.
- [ ] **AC3 — honest degradation:** No transcripts (`~/.claude/projects` absent/empty) →
  interactive pool reads **fresh/empty from real zero usage**; the three non-local pools read
  **`unknown`**. Neither is faked to a full or empty bar dishonestly.
- [ ] **AC4 — calibration knobs preserved:** The 5h-window and weekly token caps remain
  overridable (env or config) exactly as `GHOSTLING_WINDOW_CAP_TOKENS` /
  `GHOSTLING_WEEKLY_CAP_TOKENS` are today — they are estimates, hence the gauge stays `inferred`.

## Edge Cases

1. **Malformed / partial JSONL line**
   - Trigger: a transcript line is truncated or not valid JSON.
   - Expected: that line is skipped (matches Python `_events_in_file`'s try/except); the rest of
     the file still contributes. No crash, no whole-file drop.

2. **Usage events older than the weekly lookback**
   - Trigger: transcripts contain turns older than 7 days.
   - Expected: events before `now - lookback` are excluded from the weekly total and the window.

3. **Large history**
   - Trigger: weeks of transcripts.
   - Expected: a poll completes fast enough not to stutter the UI. (Python re-reads every file
     per call; Swift may cache by file mtime — `ponytail:` only if a poll measures slow.)

## Dependencies

- **Requires:** the existing Swift `QuotaProjection` / `QuotaSourceInput` / `QuotaSourceReading`
  (in `GhostlingCore`) — already present.
- **Enables:** US-001 (single binary), US-004 (delete `quota/` Python).

## Related Decisions

- DD-001 (port to Swift). Inherits task-01 US-006 (the two-pool model this feeds).

## Notes

Source files to port: `quota/jsonl_usage.py` (the JSONL walk + token sum + window aging),
`quota/live.py::live_sources/build_quota_response` (source assembly — minus the wire models,
which disappear). `quota/window_math.py`'s logic already has a Swift counterpart via `QuotaGauge`;
confirm and reuse rather than re-port.
