# Design Decisions

Architectural decisions and their rationale.

## Contents

| ID | Title | Status | Date |
|----|-------|--------|------|
| DD-001 | Effort attribution via Pomodoro self-report ("no silent zeros," not surveillance) | Accepted | 2026-06-20 |
| DD-002 | Pomodoro integration coupling — loose over vendoring the engine | Accepted | 2026-06-20 |

## Decision Log

### Accepted
- DD-001: Effort attribution via Pomodoro self-report — fill the invisible-work bucket by self-report (consensual, content-blind, exact, human-attributed) governed by "no silent zeros"; reject ambient OS/window surveillance.
- DD-002: Pomodoro integration coupling — `macos-flow` stays standalone and appends a local effort log; the kanban tails it as `SignalSource.POMODORO` (read-only). Reversible to vendoring the engine if the "active card" contract drifts.

### Proposed
_None_

### Deprecated
_None_

## Not yet decided (candidate DDs from the research)

**Directly downstream of DD-001/DD-002:**
- **Attribution default — auto-tag vs explicit tap.** DD-001 fixes the *mechanism* and decides a guess is recorded as `ESTIMATED`, but leaves open whether to auto-tag the active card from terminal focus at all (zero-friction, drift-prone) or always require an explicit tap (`MEASURED`, higher friction). Flagged by the planning review and by [effort-awareness-and-attribution.md](../research/effort-awareness-and-attribution.md).
- **Effort-log location & format** — the local append-only schema + idempotency key (DD-002 implementation note); promote to a DD if a second consumer ever reads the log.

**Foundational estimation stances** from [poc-estimation-framework.md](../research/poc-estimation-framework.md), available to lock when the estimation framework itself is scheduled:
- No-estimate inputs (forecast from measured flow only).
- Monte-Carlo-only probabilistic forecasting (never single-date ETAs).
- Two-axis capacity, smaller axis binds (attention × quota).
- Verification as a first-class measured state.
