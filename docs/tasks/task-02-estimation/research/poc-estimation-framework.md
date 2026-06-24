# Research: POC — a flow-based estimation & capacity framework

**Date:** 2026-06-17
**Status:** Proposal (POC design, not yet built)
**Researcher:** Synthesis over [estimation-in-the-ai-era.md](estimation-in-the-ai-era.md) + the existing `mission_control` Python core
**Relationship:** This is the *applied* companion to the evidence report. The evidence report says **what** to do; this proposes **how** to prove it works in a thin, testable slice.

## Goal

Prove, in a thin Python slice over the data we already collect, that we can replace task estimation with **forecasting from observed flow** and model capacity as **two axes that bind on the smaller one** — without ever asking the operator for an estimate, and without spending quota.

The POC succeeds if, replaying a recorded multi-session day, it produces:
1. a **probabilistic delivery forecast** ("85% chance the next N items finish within D days") derived only from observed cycle times / throughput;
2. a **two-axis capacity verdict** (attention bandwidth × quota headroom → binding constraint + recommended WIP);
3. a **verification-tax signal** (time-in-review as a share of cycle time) that rises when the operator is over-WIP'd.

## Design principles (inherited from the evidence report)

| # | Principle | Source finding |
|---|-----------|----------------|
| P1 | **No estimate inputs.** Forecast from measured flow only. | Devs felt +20% while measured −19% — self-reports are confidently wrong. |
| P2 | **Forecast aggregates probabilistically (Monte Carlo).** Never single-date ETAs. | Consumes AI-driven variance instead of fighting it. |
| P3 | **Capacity is two-dimensional; the smaller axis binds.** | Quota *and* human review-attention are both scarce. |
| P4 | **Verification is a first-class, measured state.** Cycle time runs to *verified*. | <44% suggestion acceptance; effort re-allocated to auditing. |
| P5 | **Per-task-class distributions.** | Greenfield (+55%) vs mature-fix (−19%) have different shapes. |
| P6 | **Surface objective throughput** to counter the felt-speed illusion. | The perception gap persists even after the fact. |

## What we already have (the POC reuses, doesn't reinvent)

| Existing primitive | Location | Role in the framework |
|--------------------|----------|----------------------|
| `SignalEvent{kind, source, session_id, timestamp, raw}` | `detector/events.py` | **Raw material.** Timestamped lifecycle stream → cycle time & time-in-review are *reductions* of it. |
| `SessionState` (idle/running/waiting-for-input/running-tests/blocked/done/unknown) | `detector/events.py` | Phase boundaries for cycle-time accounting. |
| `Card{session_id, project_dir, agent, flow, state}` | `board/card.py` | The item being forecast; `flow` (A/B) already splits the two-flow allocator. |
| `attention_count(cards)` | `board/attention.py` | **The attention axis already exists** — count of sessions needing the operator (waiting/blocked). |
| `PoolGauge{remaining_fraction, refill_kind, state, …}` | `quota/models.py` | **The quota axis** — headroom per pool, never netted across pools. |

> Key realization: the framework is mostly **derivation over an existing event stream**, not new data capture. The detector already timestamps everything.

## Proposed module layout

A new pure package `src/mission_control/estimation/`, no I/O, all Pydantic V2 — same shape as `quota/` and `board/`:

```
estimation/
  __init__.py
  samples.py      # CompletedItem, TaskClass, ThroughputDay  (the measured ground truth)
  cycle_time.py   # reduce a SignalEvent stream → CompletedItem  (pure reducer)
  forecast.py     # Monte Carlo over history → ForecastResult (percentiles)
  capacity.py     # two-axis capacity → CapacityVerdict (binding constraint + WIP)
```

Each file is one responsibility (per the repo's ≲50-line / single-responsibility rule).

### `samples.py` — the measured ground truth

```python
from datetime import datetime, timedelta
from enum import StrEnum
from pydantic import BaseModel, ConfigDict

class TaskClass(StrEnum):
    """Effort distributions differ by class (P5); start manual, infer later."""
    GREENFIELD = "greenfield"
    MATURE_FIX = "mature-fix"
    REFACTOR = "refactor"
    UNKNOWN = "unknown"          # never guessed — honest like SessionState.UNKNOWN

class CompletedItem(BaseModel):
    """One finished card, measured — the unit Monte Carlo resamples."""
    model_config = ConfigDict(frozen=True)
    session_id: str
    task_class: TaskClass
    finished_at: datetime
    cycle_time: timedelta          # session-start → verified
    review_time: timedelta         # time spent in waiting/verify (the tax)

    @property
    def review_ratio(self) -> float:
        total = self.cycle_time.total_seconds()
        return self.review_time.total_seconds() / total if total else 0.0
```

### `cycle_time.py` — reduce the signal stream (P1, P4)

A pure reducer: given the ordered `SignalEvent`s for one session, emit a `CompletedItem`. No estimates enter — every number is a timestamp difference.

```python
def to_completed_item(events: list[SignalEvent], task_class: TaskClass) -> CompletedItem | None:
    """SESSION_START → (STOP/DONE) defines cycle time; time in waiting/blocked is the tax.
    Returns None for an unfinished session (no terminal signal yet)."""
    ...
```

- **cycle_time** = `terminal.timestamp − session_start.timestamp`.
- **review_time** = summed dwell in `WAITING_FOR_INPUT` + `BLOCKED` (the operator-blocking states `attention.py` already singles out).
- Unfinished sessions return `None` (no fabricated end).

### `forecast.py` — Monte Carlo (P2)

The canonical throughput-based forecast (Vacanti / ProKanban style): resample observed history, never multiply an estimate.

```python
from random import Random
from pydantic import BaseModel

class ForecastResult(BaseModel):
    p50_days: float
    p85_days: float
    p95_days: float
    samples: int

def forecast_days(history: list[CompletedItem], remaining: int,
                  *, trials: int = 10_000, seed: int = 0) -> ForecastResult:
    """How many days to finish `remaining` items, as a distribution.
    Resamples per-item cycle times with replacement — variance is honored,
    not averaged away. Seeded RNG → deterministic, testable (no Math.random)."""
    rng = Random(seed)
    durations = [c.cycle_time.total_seconds() / 86_400 for c in history]
    outcomes = sorted(
        sum(rng.choice(durations) for _ in range(remaining))
        for _ in range(trials)
    )
    pick = lambda p: outcomes[int(p * trials)]
    return ForecastResult(p50_days=pick(0.50), p85_days=pick(0.85),
                          p95_days=pick(0.95), samples=len(history))
```

- Output is a **range with probabilities**, never a single date (P2).
- Filter `history` by `TaskClass` for per-class forecasts (P5).
- Seeded RNG keeps it deterministic — required because the workflow/runtime forbids unseeded randomness and because tests must be stable.

### `capacity.py` — two axes, smaller binds (P3)

```python
from enum import StrEnum
from pydantic import BaseModel

class BindingAxis(StrEnum):
    ATTENTION = "attention"
    QUOTA = "quota"
    NONE = "none"

class CapacityVerdict(BaseModel):
    attention_slots_free: int      # bandwidth − sessions needing me now
    quota_supported_launches: int  # from PoolGauge headroom, per pool
    recommended_wip: int           # min(...) — the binding constraint
    binding_axis: BindingAxis

def assess(cards, gauges, *, attention_bandwidth: int) -> CapacityVerdict:
    """recommended_wip = min(attention headroom, quota headroom).
    Reuses attention_count(cards) and PoolGauge.remaining_fraction."""
    ...
```

- `attention_bandwidth` is a config knob (how many sessions this human can supervise; default low, e.g. 2–3 — calibrate from data).
- `quota_supported_launches` derives from `PoolGauge` headroom — and because pools never net against each other, this is computed **per pool**, matching the existing rule.
- WIP cap = `min` of the two; `binding_axis` names which one is the bottleneck so the UI can say *why*.

## The hard part: observing the verification tax in a watcher model

We **observe** native interactive sessions; we never spawn (`claude -p` is firewalled). So "verified" is not directly emitted by the agent. Three observable proxies, cheapest first:

1. **Operator-blocking dwell** (free, already modeled) — time in `WAITING_FOR_INPUT` + `BLOCKED`. Captures the "I'm stuck reviewing this" portion. Use for the POC.
2. **Post-`DONE` dwell** — gap between the agent's terminal signal and the operator's *next* action elsewhere (session close / new launch). Approximates review-after-generation.
3. **Explicit accept signal (later)** — a one-tap "merged/accepted" the operator already does in git; richest, but needs UI. Out of POC scope.

The POC uses **(1)+(2)** and reports `review_ratio` per item and aggregated. This is the **riskiest measurement** — flagged in Risks.

## POC slices (each is a green test before the next)

| Slice | Deliverable | Test level (matches repo markers) |
|-------|-------------|-----------------------------------|
| **S0** | `cycle_time.to_completed_item` over a replayed `SignalEvent` log | `unit` — fixed event list → known cycle/review times |
| **S1** | `forecast.forecast_days` from a history of `CompletedItem` | `unit` — seeded RNG; assert P50 ≤ P85 ≤ P95 and determinism |
| **S2** | `capacity.assess` combining `attention_count` + `PoolGauge` | `integration` — assert binding axis flips as quota/attention vary |
| **S3** | End-to-end: replay a fake multi-session day → forecast + capacity + review-ratio | `e2e` — extend `tests/fixtures/fake_agent.py`; **spends zero quota** |

No testcontainers needed — this layer is pure logic over an event stream, so unit/integration/e2e with the existing fake-agent fixture and a seeded RNG fully cover it (the testcontainers guidance applies to real DBs/brokers, which this slice doesn't touch).

## Validation: is the forecast actually any good?

Forecasting is only useful if **calibrated**. The POC includes a calibration check, not just "it runs":

- Replay history, forecast forward, compare to actuals: over many windows, do ~85% of real completions land within the P85 bound? If the 85% line catches only 60%, the model is overconfident.
- **Cold-start honesty:** with little history the cone must be *wide*, and the UI must say "low confidence (n=4 items)" rather than fake precision. `ForecastResult.samples` carries the count for exactly this.

## What the POC deliberately excludes

- Swift/AppKit UI (this is the headless logic core; the cockpit consumes it later).
- Real provider quota adapters beyond the existing `quota/sources/stub.py`.
- **Automatic** `TaskClass` detection — manual tag first; a classifier is a follow-up (it can reuse `detector/classifier.py` patterns).
- Persistence — in-memory / replay first; durable history store is a later concern.

## Acceptance criteria (testable, no estimates anywhere)

- [ ] **AC1** No public function accepts a human effort/size/time estimate as input (grep the signatures — P1 enforced structurally).
- [ ] **AC2** `forecast_days` is deterministic for a fixed seed and returns monotonic percentiles (P50 ≤ P85 ≤ P95).
- [ ] **AC3** `capacity.assess` returns `recommended_wip == min(attention, quota)` and names the correct `binding_axis` across cases where each axis is the smaller.
- [ ] **AC4** `CompletedItem.review_ratio` is computed only from observed dwell times; unfinished sessions never produce a `CompletedItem`.
- [ ] **AC5** The S3 e2e replay produces all three outputs and asserts **zero quota spent** (honors the watcher-not-spawner pool firewall).
- [ ] **AC6** A calibration test demonstrates the P85 bound covers ≥ ~85% of replayed actuals on the synthetic dataset (within tolerance).

## Open questions / risks

| Risk | Severity | Note / mitigation |
|------|----------|-------------------|
| **Verification tax is hard to observe** without an explicit accept signal | High | POC uses dwell-time proxies (1)+(2); validate against a small hand-labeled set before trusting the ratio. |
| **Cold start** — too little history → meaningless forecast | Medium | Surface `samples` count + widen cone; never show a confident date below a minimum n. |
| `TaskClass` **auto-detection** unsolved | Medium | Manual tag in POC; pooling all classes early is acceptable but blurs P5. |
| **Attention bandwidth is a guess** | Medium | Start as config; later infer from the review-ratio inflection (the over-WIP signal). |
| Over-trusting the **flow-metric specifics** from the evidence report | Low–Med | Those sources weren't individually re-verified; calibration check is the safety net. |

## Recommended next steps

1. `/saha:task` → turn this into a task description scoped to slices **S0–S3**.
2. `/saha:decide` → record the load-bearing stances as DDs: **no-estimate inputs**, **Monte-Carlo-only forecasting**, **two-axis capacity (smaller binds)**, **verify-as-a-measured-state**.
3. `/saha:test-specs` → S0–S3 acceptance criteria above become the coverage matrix.
4. Build S0 first (pure reducer) — it's the foundation everything else resamples.

## References

- Companion evidence: [estimation-in-the-ai-era.md](estimation-in-the-ai-era.md)
- Existing primitives: `src/mission_control/detector/events.py`, `board/card.py`, `board/attention.py`, `quota/models.py`
- Monte Carlo / flow forecasting practice: ProKanban (https://www.prokanban.org/blog/trustingmcs), Daniel Vacanti (https://agileforhumans.com/agile-metrics-for-predictability-daniel-vacanti/), #NoEstimates (https://noestimates.wordpress.com/probabilistic-forecasting/)
