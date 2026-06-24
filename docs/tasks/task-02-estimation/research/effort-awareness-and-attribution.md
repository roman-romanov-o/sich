# Research: Effort awareness — can the product see *all* the effort on a task?

**Date:** 2026-06-20
**Status:** Complete (design proposal — folds an existing sibling project into the model)
**Researcher:** Synthesis over the `mission_control` watcher model + the existing `macos-flow` Pomodoro app
**Relationship:** Fourth article in the estimation task. The taxonomy article proved the watcher is structurally blind to coordination (#4) and planning (#5) and demanded an *explicit untracked bucket, never a silent zero*. This article answers **how to fill that bucket** — and finds the mechanism already built in a sibling repo.

## Summary

**Can the product be aware of *all* effort spent on a task? No — and "all" is the wrong target.** The achievable, correct goal is a **provenance-honest ledger**: every effort category is either measured or *visibly marked un-measured*, so the total reads as "observed + inferred + a known gap," never a single false-precise number. The decisive reframe: **effort awareness is an *attribution* problem, not a *capture* problem.** Capturing raw activity is easy (OS APIs, calendars, git); the hard, partly-unsolvable part is tying an activity to *this task*. A terminal session self-identifies (`cwd → project → card`); a Slack DM is "about task X" only in the operator's head. So fidelity is bounded by **attribution strength**, not capture volume.

The honest mechanism for the invisible rung (coordination, planning) is **self-report reframed as a focus tool**: a **Pomodoro timer**, where the operator tags which card a work-session is for. This **inverts the surveillance tradeoff** — consensual, content-blind, exact duration, human-*declared* attribution — and it is near-zero-friction because the operator runs the timer for focus anyway; the attribution falls out as a byproduct. Critically, **~80% of this is already built** in the `macos-flow` repo, whose `task-02-todoist-sync` is a direct blueprint: *select an active task → write each completed work-phase back to it, idempotently*. Swap the writeback target from Todoist's API to a local kanban card-id and it becomes the **human's signal source** — the one source in our watcher that represents the operator instead of an agent.

## Research questions

1. Is total effort-awareness possible — and if not, what *is* the right target?
2. Why is attribution (not capture) the binding constraint?
3. What is the least-surveillant mechanism for the invisible work-types (#4 coordination, #5 planning)?
4. How much of it already exists in `macos-flow`, and how should it plug into `mission_control`?

## The reframe: capture is easy, *attribution* is the hard bound

Raw activity is cheap to record and mostly solved off-the-shelf. The genuinely hard — and in the general case unsolvable — part is tying a given activity to **the right card**. So the fidelity of effort-awareness is set by *how strongly an activity self-identifies its task*, not by how much you can capture. That gives a ladder.

### The attribution-strength ladder

| Rung | Attribution | Confidence | Example signals | Human effort |
|------|-------------|-----------|-----------------|--------------|
| **1 — Self-identifying** | the activity *carries* the card id | **high, automatic** | terminal signals (`cwd → project → card`); git commits / PR review on the task branch | none |
| **2 — Task-shaped but unlabeled** | a *heuristic guess* | **low** | OS active-app/window focus (Slack/Zoom/browser is foreground); calendar-busy block | none, but lossy |
| **3 — Invisible** | only the human knows | **n/a unless declared** | thinking, whiteboard, hallway chat, a meeting about the design | one tap to attribute |

Rung 1 we already harvest (the detector). Rung 2 is the surveillance temptation — high capture, *no consent*, *guessed* attribution. Rung 3 — the work-types the taxonomy flagged as invisible — **cannot be auto-captured even in principle**; it can only be *self-reported or lost*.

### The fundamental limit → the real principle

Because rung 3 is un-capturable automatically, **100% automatic awareness is impossible.** The design target is therefore not coverage but honesty:

> **No silent zeros.** Every effort category is either measured or *explicitly marked un-measured*. Observed cycle time is shown as the **lower bound** it actually is; the gap to true Flow Time is a visible *unknown band*, not a fake zero.

This is the same stance the taxonomy article landed on, now made into the load-bearing requirement.

## The Pomodoro answer: rung-3 attribution, *de-surveilled*

The honest way to fill rung 3 is **explicit self-report** — but a logging chore won't get used. A **Pomodoro timer that tags the active card** turns the chore into a *focus tool the operator wants to run anyway*, so the attribution is a free byproduct. It **inverts the surveillance tradeoff on every axis the operator cares about**:

| | Ambient/OS capture (rung 2, surveillance) | Pomodoro (rung 3, self-report) |
|---|---|---|
| Consent | passive, implicit | **operator presses start** |
| Content | observes what you do | **content-blind by construction** |
| Attribution | *heuristic guess* | **human-declared** (best possible for invisible work) |
| Duration fidelity | fuzzy (idle detection) | **exact — the timer *is* the clock** |
| Coverage | high | only while running ← the *only* weakness |

The single weakness (coverage only when the timer runs) is **already handled by "no silent zeros"**: un-timed work falls into the visible unknown band. So the Pomodoro trades away *nothing the operator values* to delete the panopticon — it raises the *floor* of what's known without pretending to be the ceiling.

## ~80% is already built: the `macos-flow` reuse path

`macos-flow` (sibling repo in `MyProjects`) is a saha-built SwiftUI menu-bar Pomodoro app with the same project structure as this one. Two things make it a direct fit:

**1. A clean, pure, already-tested engine** (zero UI coupling, ~240 LOC total):
- `MacOSFlow/Models/Phase.swift` — `idle / work / shortBreak / longBreak`. **Only `.work` is effort**; breaks are not — the distinction is already encoded.
- `MacOSFlow/Engine/PomodoroState.swift` — `@Observable` phase machine; increments `completedPomodoros` only on `.work`; emits `phaseCompletedPublisher.send((completed, next))` on every phase boundary. *That publisher is the effort-event source.*
- `MacOSFlow/Engine/TimerEngine.swift` + `Protocols/TimeSource.swift` — injectable clock → deterministic, unit-tested.

**2. A whole task that already designed task-attribution + writeback** — `docs/tasks/task-02-todoist-sync`. It is the same mechanism we need, pointed at the wrong target (Todoist instead of a kanban card):
- **US-002 "Filter and Select Active Task"** → our *attribution*: pick which **card** the next work-sessions count toward. (Persist the selected id locally; clear if the card disappears.)
- **US-003 "Write Work Completion"** → our *ledger append*. Its acceptance criteria are exactly the effort-ledger semantics we want, verbatim:
  - *"On work phase completion, app writes one [entry] to selected task"* — one `EffortReading` per completed `.work` phase.
  - *"includes timestamp and session duration"* — the two fields of an `EffortReading`.
  - *"Sync is idempotent per completed phase event"* — **how we avoid double-counting effort** on restart/retry.
  - *"No write occurs when no task is selected"* — untagged ⇒ no per-card attribution (becomes "focused work, unattributed").
- **DD-002 "Filter-First, No Webhooks"** → reinforces *local, no-backend, explicit-refresh* — which is exactly the coupling discipline we want below.

So the work is **retargeting a built pattern**, not green-field invention.

## Architecture: the Pomodoro as the *human's* signal source

A completed `.work` phase becomes one reading, mirroring the `quota/` design:

```python
# new sibling to SourceReading / SignalSource in the detector
class EffortReading(BaseModel):          # frozen, Pydantic V2 — like PoolGauge's readings
    source: SignalSource                 # new member: POMODORO (alongside PTY/HOOK/JSONL)
    card_id: str | None                  # the tagged card; None ⇒ unattributed focus
    started_at: datetime
    active_seconds: int                  # exact, from the timer
    duration_confidence:    Confidence   # MEASURED — the timer measured it
    attribution_confidence: Confidence   # MEASURED if the human tagged the card;
                                         # ESTIMATED if auto-tagged from terminal focus
```

This is **the `PoolGauge` / `SourceReading` pattern reused** — confidence-labeled readings fused into one gauge that is honest about its own uncertainty — with one refinement: the **two confidences split**, and both use the *existing* two-value `Confidence` enum (`MEASURED` / `ESTIMATED`) verbatim. Duration is always `MEASURED` (the timer). Attribution is `MEASURED` only when the human *explicitly tagged* the card; an **auto-tag from terminal focus** (last-focused `cwd → project → card`) is honestly recorded as `ESTIMATED` — it is a guess that is wrong exactly when the operator is in a meeting about card X while the terminal last sat on card Y. So the convenience of zero-tap defaulting never masquerades as a human-confirmed fact; a one-tap re-tag upgrades it. **Whether to auto-tag at all, or always require the explicit tap, is left as an open sub-decision** (see DD candidate list).

### Recommended coupling: loose — `macos-flow` *feeds* the kanban, never the reverse

The kanban is fundamentally a **watcher that tails signal sources** (it already tails PTY/hooks/JSONL). So:

> **Keep `macos-flow` standalone** (the operator already runs it). It appends each completed work-session to a **local pomodoro log**. **The kanban tails that log as just another `SignalSource`** — the one that represents *you*.

Why loose coupling is the right call:
- **Honors watcher-not-spawner exactly** — the kanban *reads* your pomodoro log; it never drives your timer. You keep control of your own focus tool. (See [[watcher-not-spawner-quota-constraint]].)
- **Both apps stay independent**; the only shared concept is "active card." DD-002's *local, no-backend, file-based* stance transfers directly — the log is a local append-only file, no IPC server.
- It is literally `todoist-sync` with the writeback target swapped from the Todoist REST API to a local card-id line.

**Tighter alternative (one app):** vendor the engine (`Phase` + `PomodoroState` + `TimerEngine` + `TimeSource`, ~240 LOC, no UI coupling) into the kanban app and surface a Pomodoro in the board's menu bar. On the table once both are AppKit/SwiftUI surfaces — but start loose; it costs nothing and keeps the focus tool yours. **This loose-vs-vendor choice is the one decision to lock as a DD.**

## Honesty guardrails (so it stays a ledger, not a stopwatch)

1. **Only `.work` phases are effort.** Breaks are not — the engine already separates them.
2. **The card tag is optional.** Untagged ⇒ "focused work, unattributed" (counts toward total focus time, not per-card). Default to the active-card heuristic so it is usually automatic.
3. **Un-timed work ⇒ the unknown band, never zero.** The Pomodoro raises the floor of what's known; it never claims the ceiling.
4. **Idempotent per phase event** (straight from US-003) — restart/retry must not double-count.
5. **Effort awareness ≠ effort policing.** Per the taxonomy article, coordination is judged by *effectiveness/flow-cost*, not minutes — and recall the METR gap: self-report is itself biased, which is *why* we blend it with the rung-1 terminal signal rather than trust either alone. Surfacing "2h of tagged focus on this card" is *context*, not a number to minimize.

## Implications for the estimation POC

Concrete threads back into [poc-estimation-framework.md](poc-estimation-framework.md) and the bucket the taxonomy demanded:

- **The Pomodoro log *is* the feed for `CompletedItem.untracked_human_time`** that [work-taxonomy-and-measurement.md](work-taxonomy-and-measurement.md) introduced. Tagged work-sessions on a card sum into that field; `coverage` = observed-terminal + tagged-pomodoro ÷ estimated-total.
- **Add `POMODORO` to `SignalSource`** and an `EffortReading` reducer alongside `cycle_time.to_completed_item` — same pure-reducer shape, no I/O.
- **The human-active axis (taxonomy #3+#4) gains a real signal** instead of a guess: tagged focus time on a card is direct evidence of operator load, feeding `capacity.assess`'s attention axis.
- **Keeps P1 intact** — a Pomodoro is a *measured* duration, not a human *estimate*. No estimate enters the system.

## Open design decisions (capture as DDs)

- [ ] **DD — Coupling:** loose (sibling app writes a local effort log the kanban tails) **[recommended]** vs vendor-the-engine (one app). 
- [ ] **DD — Attribution default:** auto-tag the active card from terminal focus vs always require an explicit tap.
- [ ] **DD — Log location & format:** local append-only file (mirrors `macos-flow` DD-002's no-backend stance); idempotency key = completed-phase event id.

## Risks / open questions

| Risk | Severity | Note / mitigation |
|------|----------|-------------------|
| **Coverage gap** — operator doesn't run the timer | Medium | By design: un-timed ⇒ unknown band, never zero. The floor rises only when used; that's honest. |
| **Attribution drift** — wrong card tagged / forgot to switch | Medium | Default to active-card heuristic; allow after-the-fact re-tag; keep `attribution_confidence` explicit. |
| **Scope creep toward rung 2** (adding OS/window capture "to fill gaps") | High | Hold the line: rung 2 is opt-in, content-blind, local *only* if ever added. The Pomodoro is the sanctioned path; surveillance is not. (See [[ui-poc-helm-critique]] watcher discipline.) |
| **Two-app drift** — `macos-flow` and kanban diverge on the "active card" contract | Low–Med | Keep the contract tiny (a card-id + a log line); revisit vendor-the-engine if drift hurts. |
| **Self-report bias** (METR) | Low | Mitigated by *blending* with rung-1 terminal signal; the Pomodoro adds the invisible portion, it doesn't replace the observed one. |

## References

**Sibling project (the reuse source):**
- Engine — `macos-flow/MacOSFlow/Engine/PomodoroState.swift` (`.work`-only count, `phaseCompletedPublisher`), `.../TimerEngine.swift`, `.../Models/Phase.swift`, `.../Protocols/TimeSource.swift`
- Attribution + writeback blueprint — `macos-flow/docs/tasks/task-02-todoist-sync/` — US-002 (select active task), **US-003 (write work completion: timestamp + duration, idempotent per phase, no write when unselected)**, DD-002 (filter-first, local, no webhooks)

**Companion articles:** [estimation-in-the-ai-era.md](estimation-in-the-ai-era.md) · [poc-estimation-framework.md](poc-estimation-framework.md) · [work-taxonomy-and-measurement.md](work-taxonomy-and-measurement.md)

**Existing primitives reused:** `quota/models.py` (`PoolGauge`, `SourceReading`, `Confidence` — the multi-source-fusion pattern), `detector/events.py` (`SignalSource`), `board/attention.py` (the attention axis the human-effort signal feeds).
