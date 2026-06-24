# DD-002: Pomodoro integration coupling — loose (sibling app feeds an effort log) over vendoring the engine

**Status:** Accepted
**Date:** 2026-06-20
**Deciders:** Roman Romanov (operator)

## Context

[DD-001](DD-001-effort-attribution-pomodoro-self-report.md) chose a Pomodoro self-report as the effort-attribution mechanism. The timer is **already ~80% built** in the sibling repo `macos-flow` — a standalone SwiftUI menu-bar app the operator already runs daily, with a pure engine and a `task-02-todoist-sync` task that already designed "select active task → write each completed work-phase back to it, idempotently." This decision picks *how* that timer reaches the kanban.

### Constraints

- **Watcher-not-spawner.** The kanban must not *drive* or *control* the operator's focus tool — it may only *read*. (See watcher-not-spawner-quota-constraint memory.)
- `macos-flow` is already in daily use; the operator owns that surface.
- Both apps are AppKit/SwiftUI macOS apps — vendoring is *technically* possible.
- The kanban app is early; large new UI surfaces there carry risk.
- Minimize ongoing drift between the two repos.

### Requirements

- Each completed `work` phase reaches the kanban, attributed to a card.
- The kanban side is **read-only** with respect to the timer.

## Options Considered

### Option 1: Loose coupling — `macos-flow` appends a local effort log; the kanban tails it

**Description:** `macos-flow` stays standalone and gains a *local-file* writeback target (a fork of `todoist-sync` US-003, pointing at a local card-id line instead of the Todoist API). The kanban adds a `SignalSource.POMODORO` reader that tails that append-only log — exactly how it already tails PTY/hooks/JSONL. The only shared concept is "active card."

**Pros:**
- **Honors watcher-not-spawner literally** — the kanban *reads* the log, never drives the timer.
- The kanban already *is* a tail-a-source watcher; this is one more source, no new architecture.
- Apps stay independent; the operator keeps the focus tool they already use.
- Mirrors `macos-flow` DD-002's own *local, no-backend, explicit-refresh* stance — the log is a local file, no IPC server.
- Lowest immediate effort: retarget an already-designed writeback.

**Cons:**
- The "active card" contract lives in two places → possible drift.
- The operator runs two app surfaces.

**Effort:** Low–Medium.

### Option 2: Vendor the engine into the kanban app

**Description:** Copy the pure engine (`Phase` + `PomodoroState` + `TimerEngine` + `TimeSource`, ~240 LOC, no UI coupling) into the kanban app and surface a Pomodoro in the board's menu bar. One app.

**Pros:**
- One app, one surface; a single active-card source of truth; no log-contract drift.

**Cons:**
- More work now — a new menu-bar/timer UI on the *early* kanban app (bigger blast radius).
- **Duplicates a timer that already exists** in `macos-flow` → two engine copies to maintain.
- Couples the two products' release cycles in practice.

**Effort:** Medium–High.

### Option 3: Extract a shared Swift package both apps depend on

**Description:** Factor the engine into a shared package consumed by both repos.

**Pros:**
- No engine duplication; single source of truth for the timer logic.

**Cons:**
- Premature — neither repo is set up for a shared package; over-engineering for two solo apps; highest coordination cost.

**Effort:** High.

## Decision

**Chosen Option:** **Option 1 — loose coupling** (`macos-flow` appends a local effort log; the kanban tails it as `SignalSource.POMODORO`). **Reversible** to Option 2 if drift between the two "active card" definitions proves painful in practice.

### Rationale

Loose coupling is the only option that honors watcher-not-spawner *literally* (read-only), reuses the existing tail-a-source architecture, keeps the operator's focus tool independent, and costs the least to ship. Its weakness — a contract in two places — is contained by keeping that contract *tiny* (a card-id plus a log line). Vendoring trades that small drift risk for real cost on an early app and a duplicated engine; it stays on the table as the reversal path, not the starting point.

### Key Factors

1. **Watcher-not-spawner literalness** — read-only is structurally guaranteed when the kanban only tails a file.
2. **Reuse with least effort** — retarget the `todoist-sync` writeback to a local card-id.
3. **Small blast radius** — no new UI on the early kanban app.
4. **Reversibility** — vendoring remains available if the loose contract drifts.

## Consequences

### Positive

- Cleanest honoring of the core constraint; independent apps; fastest path to a working effort feed.

### Negative

- The "active card" contract is maintained in two places (mitigated: keep it to a card-id + one log line).
- The operator runs two app surfaces.

### Neutral

- Defines a **local append-only effort-log format** with an idempotency key = completed-phase event id.
- Revisit vendoring (Option 2) only if drift hurts.

## Implementation Notes

- **Log line (append-only, local):** `started_at`, `active_seconds`, `card_id` (nullable), `phase_event_id` (idempotency key). One line per completed `work` phase.
- **`macos-flow` side:** add a local-file writeback target — a fork of `todoist-sync` US-003 (timestamp + duration, idempotent per phase, no write when no card selected) writing the line above instead of a Todoist comment.
- **Kanban side:** a `POMODORO` source reader in the detector that tails the log and emits `EffortReading`s (per DD-001), deduped on `phase_event_id`.
- **Active-card contract:** the kanban *offers* the current card (terminal `cwd → project → card`); `macos-flow` lets the operator confirm/override. An auto-offered-but-unconfirmed card is recorded as `ESTIMATED` attribution (per DD-001) until the operator confirms it, so the log never claims a guess is human-confirmed. Keep the shared surface to the card-id only.

## Related

- **Task:** [task-02-estimation README](../README.md)
- **Related Decisions:** [DD-001](DD-001-effort-attribution-pomodoro-self-report.md) (the mechanism this integrates).
- **Research:** [effort-awareness-and-attribution.md](../research/effort-awareness-and-attribution.md) (loose-vs-vendor analysis).

## References

- `macos-flow/docs/tasks/task-02-todoist-sync/` — US-002 (select active task), US-003 (idempotent work-completion writeback), DD-002 (filter-first, local, no webhooks).
- `macos-flow/MacOSFlow/Engine/` — `PomodoroState.swift`, `TimerEngine.swift`; `MacOSFlow/Models/Phase.swift`; `MacOSFlow/Protocols/TimeSource.swift`.
