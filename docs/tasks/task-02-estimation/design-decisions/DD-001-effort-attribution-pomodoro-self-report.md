# DD-001: Effort attribution via Pomodoro self-report ("no silent zeros," not ambient surveillance)

**Status:** Accepted
**Date:** 2026-06-20
**Deciders:** Roman Romanov (operator)

## Context

The product is a terminal-watcher: it observes native interactive AI sessions and derives state from their signal stream. The estimation research ([work-taxonomy-and-measurement.md](../research/work-taxonomy-and-measurement.md)) proved the watcher is **structurally blind** to two work-types that are nonetheless real effort on a task — **#4 coordination/communication** (Slack, meetings, spec discussion) and **#5 planning/thinking**. The estimation POC ([poc-estimation-framework.md](../research/poc-estimation-framework.md)) opened a `CompletedItem.untracked_human_time` field that needs a *feed*.

The question — *"can the product be aware of all effort on a task?"* — was answered in [effort-awareness-and-attribution.md](../research/effort-awareness-and-attribution.md): **no**, and total awareness is the wrong target. Effort-awareness is an **attribution** problem, not a capture problem. This decision picks the mechanism for the invisible rung and the honesty principle that governs it.

### Constraints

- **Watcher-not-spawner / calm-cockpit discipline.** The product observes; it does not surveil. A stopwatch/panopticon fights the product identity (see watcher-not-spawner-quota-constraint, ui-poc-helm-critique memories).
- **No-estimates principle (POC P1).** The system must not ingest a human *estimate* of size/effort/time.
- **Solo-dev friction budget is near zero.** Any mechanism that is a pure chore will not be used.
- **Privacy / Goodhart.** Must not scrape Slack/comms *content*; must not create a metric that invites gaming.
- **METR perception gap.** Self-reported effort is biased — so self-report cannot be the *only* signal; it must blend with the observed terminal stream.

### Requirements

- Fill `untracked_human_time` for invisible work-types #4/#5, attributed to a specific **card**.
- Be honest about coverage: observed time is a *lower bound*, never a fabricated zero.
- Preserve P1: whatever enters the system must be a *measured* quantity, not an estimate.

## Options Considered

### Option 1: Pomodoro self-report tagging the active card

**Description:** The operator runs a Pomodoro focus timer (already a habit) and tags which card a work-session is for. Each completed `work` phase becomes one measured, attributed effort record. Invisible work the operator chooses to time (a meeting, a design session) is tagged like any other focus block.

**Pros:**
- **Inverts the surveillance tradeoff:** consensual (you press start), content-blind by construction, **exact** duration (the timer *is* the clock), **human-declared** attribution — the best attribution confidence achievable for invisible work.
- **Near-zero friction:** it's a focus tool run for its own benefit; attribution is a byproduct.
- **Preserves P1:** a timed duration is *measured*, not an estimate.
- **~80% already built** in the sibling `macos-flow` repo (engine + a `todoist-sync` task that is a direct attribution/writeback blueprint).

**Cons:**
- Covers only *timed* sessions → a coverage gap when the operator doesn't run the timer.
- Self-report bias (METR) — mitigated by blending with the observed terminal stream, not replacing it.
- Depends on a habit being maintained.

**Effort:** Low–Medium (reuse, not green-field).

### Option 2: Ambient OS / active-window + calendar capture (the "rung 2" path)

**Description:** Passively read foreground-app/window focus (Slack/Zoom/browser) and calendar-busy blocks; heuristically attribute to the active project/card.

**Pros:**
- High coverage; zero per-session effort; fully automatic.

**Cons:**
- **Surveillance** — passive, implicit consent; fights the calm-cockpit identity and the watcher discipline.
- **Heuristic (wrong) attribution** — the OS doesn't know *which card* your Slack message is about.
- Privacy risk; invites Goodhart; the richest data is also the most sensitive.

**Effort:** Medium–High.

### Option 3: Terminal-only — accept the blind spot (silent zeros)

**Description:** Measure only what the detector sees; treat invisible work as absent.

**Pros:**
- Simplest; nothing to build; no surveillance.

**Cons:**
- **Dishonest:** systematically undercounts human load and over-states flow efficiency, mis-forecasting *exactly* when the operator is most loaded (Slack/meeting-heavy day looks idle). This is the failure mode the taxonomy article named explicitly.

**Effort:** None.

### Option 4: Manual after-the-fact time logging (Toggl/Harvest style)

**Description:** The operator logs durations against cards retrospectively.

**Pros:**
- Flexible; full coverage in theory.

**Cons:**
- A **pure chore** with no intrinsic benefit → won't get used; highest friction; retrospective recall bias.

**Effort:** Medium.

## Decision

**Chosen Option:** **Option 1 — Pomodoro self-report — governed by the "no silent zeros" principle.**

The coverage gap (Option 1's only real weakness) is neutralized not by capturing more, but by **honesty**: observed/tagged time is always presented as the **lower bound** it is, with the gap to true effort shown as a visible *unknown band* — **never a zero**. Option 2 (ambient surveillance) is **explicitly rejected as the primary path**; if any rung-2 signal is ever added it must be opt-in, content-blind, and local. Option 3 is rejected as dishonest; Option 4 as unusable.

### Rationale

The Pomodoro is the only option that is simultaneously *non-surveillant*, *low-friction*, *exactly measured*, *human-attributed*, and *P1-preserving* — and it is mostly already built. Its weakness is coverage, and coverage is precisely the thing "no silent zeros" makes safe to live with: the product never claims to know more than it does.

### Key Factors

1. **Consent + content-blindness** — it is the de-surveilled form of self-report; it fits the watcher identity instead of fighting it.
2. **Measured, not estimated** — keeps the no-estimates principle structurally intact.
3. **Honesty over coverage** — "no silent zeros" turns the one weakness into a stated lower bound.
4. **Reuse** — `macos-flow` already implements the engine and the attribution/writeback pattern.

## Consequences

### Positive

- The invisible work-types (#4/#5) gain a **real, attributable, exactly-measured** feed for `untracked_human_time`.
- Watcher-not-spawner discipline and P1 both stay intact.
- Cheap to deliver (reuse); attribution confidence is the best obtainable for invisible work.

### Negative

- Effort is only captured while the timer runs (accepted; made honest by "no silent zeros").
- Data quality depends on a maintained habit, and on self-report (mitigated by blending with the observed terminal stream).

### Neutral

- Introduces a new `SignalSource.POMODORO` and an `EffortReading` model (the *how* of integration is DD-002).
- The operator's focus-tool habit becomes load-bearing for human-effort data quality.

## Implementation Notes

`EffortReading` mirrors `quota/`'s `SourceReading`/`PoolGauge` confidence-fusion, with the **confidence split** — duration is certain, attribution is human-declared:

```python
class EffortReading(BaseModel):          # frozen, Pydantic V2
    source: SignalSource                 # new member: POMODORO
    card_id: str | None                  # tagged card; None ⇒ unattributed focus
    started_at: datetime
    active_seconds: int                  # exact, from the timer
    duration_confidence:    Confidence   # MEASURED — the timer measured it
    attribution_confidence: Confidence   # MEASURED if the human tagged the card;
                                         # ESTIMATED if auto-tagged from terminal focus
```

> **Reuse note (corrected after review):** this uses the *existing* two-value `Confidence` enum in `quota/models.py` (`MEASURED` / `ESTIMATED`) **verbatim — no new members are added.** Earlier drafts wrote `HIGH`/`UNKNOWN`, which do not exist on that enum; the mapping above is the intended one. When `card_id is None` (unattributed), there is nothing to attribute, so `attribution_confidence` is simply not meaningful for that record.

Rules carried from the research (and from `macos-flow` US-003):
- **Only `work` phases are effort** — breaks are not (the engine already separates them).
- **Idempotent per completed-phase event** — restart/retry must not double-count.
- **Three attribution states, not two** — and the data model records which:
  - *explicit human tag* ⇒ `card_id` set, `attribution_confidence = MEASURED`;
  - *auto-tag from terminal focus* (`cwd → project → card`) ⇒ `card_id` set, `attribution_confidence = ESTIMATED` — it is a *guess*, and a wrong one exactly when the operator is in a meeting about card X while the terminal last sat on card Y, which is the #4/#5 case this mechanism exists to capture. A one-tap re-tag upgrades `ESTIMATED → MEASURED`;
  - *no tag* ⇒ `card_id = None`, "focused work, unattributed" (counts toward total focus time, not per-card).
- **Open sub-decision (not settled here):** whether to auto-tag at all (zero-friction but drift-prone, and only ever `ESTIMATED`) vs always require an explicit tap (`MEASURED` but higher friction). The research left this open; this DD only fixes the *mechanism and the honesty of marking a guess as `ESTIMATED`*. Tracked as a candidate DD in the [design-decisions README](README.md).
- **Feeds `CompletedItem.untracked_human_time`**; `coverage` = observed-terminal + tagged-pomodoro ÷ estimated-total, surfaced honestly.

## Related

- **Task:** [task-02-estimation README](../README.md)
- **Research:** [effort-awareness-and-attribution.md](../research/effort-awareness-and-attribution.md) · [work-taxonomy-and-measurement.md](../research/work-taxonomy-and-measurement.md) · [poc-estimation-framework.md](../research/poc-estimation-framework.md)
- **Related Decisions:** [DD-002](DD-002-pomodoro-integration-coupling.md) decides *how* this integrates (loose coupling vs vendoring the engine).

## References

- Sibling project `macos-flow`: `MacOSFlow/Engine/PomodoroState.swift` (`.work`-only count, `phaseCompletedPublisher`); `docs/tasks/task-02-todoist-sync/` US-002/US-003/DD-002 (attribution + idempotent writeback blueprint).
- Existing primitives reused: `quota/models.py` (`SourceReading`, `PoolGauge`, `Confidence`), `detector/events.py` (`SignalSource`), `board/attention.py` (the attention axis this feeds).
