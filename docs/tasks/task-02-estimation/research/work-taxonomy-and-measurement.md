# Research: A taxonomy of work-types on a task, and how to measure each

**Date:** 2026-06-17
**Status:** Complete
**Researcher:** Two parallel research agents (SPACE/DevEx/DORA; Flow Framework/Lean VSM/Kanban) + synthesis grounded in the `mission_control` watcher model
**Relationship:** Third article in the estimation task. Answers a gap the POC left open — the POC measures *terminal* cycle time, but much of the real work on a task (Slack, meetings, review, thinking) happens off the terminal. This categorizes all work-types and says how (and whether) to measure each.

## Summary

Work on a task is not one thing, and the established literature already decomposes it the same way: **total elapsed time = active/touch time + wait time**, with communication/coordination treated as *real work measured by effectiveness, not volume*. The direct answer to "does a meeting or Slack thread about the task count?" — **yes, it counts** (it is SPACE's "Communication & Collaboration" dimension) — **but you must never measure it by duration or message count** (that is the single most misused productivity metric) and you must track its *dual nature*: it both produces value and destroys flow. For our watcher-not-spawner tool the decisive twist is **observability**: terminal work is auto-observed, but coordination/meetings/thinking are *invisible*. The honest design is to model invisible work as an **explicit untracked bucket — never a silent zero** — optionally fed by lightweight manual tagging, and to compute flow efficiency **per actor** (human attention vs agent compute), because in agent orchestration the human *wants* low personal touch-time per task.

## Research questions

1. What categories of work exist on a software task?
2. How is each measured — and which metrics are traps?
3. Should off-terminal work (Slack, meetings) count, and how?
4. What can a *watcher* (observe-only, never-spawn) tool actually see, and how should it handle the invisible rest?

## The frameworks (grounding, with citations)

| Framework | What it contributes | Key verbatim / source |
|-----------|---------------------|------------------------|
| **SPACE** (Forsgren, Storey, Maddila, Zimmermann, Houck, Butler — *ACM Queue* 2021) | 5 dimensions: **S**atisfaction, **P**erformance, **A**ctivity, **C**ommunication & collaboration, **E**fficiency & flow. The **C** dimension is the meetings/Slack/review question, treated as first-class. | *"it cannot be measured by a single metric or dimension."* Activity is *"the most ubiquitous productivity measure and often the most misused."* https://queue.acm.org/detail.cfm?id=3454124 |
| **DevEx** (Noda, Storey, Forsgren, Greiler — *ACM Queue* 2023) | 3 dimensions: **Feedback loops**, **Cognitive load**, **Flow state**. Meetings/interruptions/context-switching are the *leading barriers to flow*. Measure each dimension 3 ways: perception, workflow, KPI. | *"interruptions themselves are not necessarily negative — it's having too many of them that's a challenge."* https://queue.acm.org/detail.cfm?id=3595878 |
| **DORA** + **Beck & Orosz** | Prefer **outcome/impact** over output/activity; never measure individuals; beware Goodhart/gaming. | DORA: *"Software delivery performance is not an individual measure."* Beck/Orosz: measurement *"changes how developers work, as they try to 'game' the system."* https://dora.dev/guides/dora-metrics-four-keys/ · https://newsletter.pragmaticengineer.com/p/measuring-developer-productivity |
| **Flow Framework** (Kersten, *Project to Product*) | 4 **Flow Items**: Features, Defects, Risks, Debts. **Flow Time** = elapsed incl. active *and* wait; **Flow Efficiency** = % of flow time in active states; plus Velocity, Load, Distribution. | Flow Time *"including both active and wait states."* Flow Efficiency = *"% of cycle time spent in active states."* (Planview *Flow Metrics* ebook) |
| **Lean / Value-Stream Mapping** | **Lead Time = Process/touch time + Wait time.** Activities classify as Value-Add / Necessary-Non-Value-Add / pure-waste NVA. | LEI: value = *"any activity the customer judges of value."* Martin/Osterling worked example: 2-hour lead time, 20 min touch → *"the work sits idle for 1 hour and 40 minutes."* https://www.lean.org/lexicon-terms/value-stream-mapping/ |
| **Kanban** (Kanban Guide / Vacanti / ProKanban) | Cycle time, WIP, throughput, work-item age. **Cycle time is wall-clock and *includes* blocked/waiting time** — it deliberately does not subtract wait. | ProKanban: *"The key word is elapsed… non-working days and blocked time are included."* https://kanbanguides.org/english/ |

**The one identity they all share:**
> **Total elapsed time = Active/Touch time + Wait time**, and **Flow Efficiency = Active ÷ Total = Active ÷ (Active + Wait).**

Vacanti states it as **Touch Time ÷ (Wait Time + Touch Time)**; Lean calls it Process Cycle Efficiency; the Flow Framework calls it Flow Efficiency. Same number, three names.

## The core model: three orthogonal axes

A single work-type table isn't enough — each piece of work sits on **three independent axes**:

- **Axis 1 — Value class (Lean):** `value-add` (touch) · `necessary-NVA` (review, mandated checks) · `wait/waste` (blocked, queued, handoff).
- **Axis 2 — Actor:** `agent` (compute) vs `human` (attention). *This is our orchestration twist* — there are two clocks, and they invert (see "whose flow efficiency" below).
- **Axis 3 — Observability (the watcher twist):** `observed` (the detector sees it) · `inferable` (derivable from dwell/gaps) · `invisible` (off-terminal; the detector is blind).

## The work-type taxonomy (the deliverable)

| # | Work-type | Value class | Actor | Observable? | Right metric | Trap to avoid |
|---|-----------|-------------|-------|-------------|--------------|----------------|
| 1 | **Focused implementation** (agent generating code) | value-add | agent | **observed** (`RUNNING`) | agent active time; throughput | equating agent motion with progress |
| 2 | **Automated verification** (tests / CI) | necessary-NVA | agent/system | **observed** (`RUNNING_TESTS`) | test cycle time; pass rate | treating green tests as "task done" |
| 3 | **Human review & verification** (reading diffs, accepting/rejecting) | value-add (human touch) | human | **inferable** (post-`DONE` dwell, `WAITING_FOR_INPUT`) | review time; **review ratio**; acceptance rate (prior research: <44%) | assuming "agent done" = done; ignoring the verification tax |
| 4 | **Coordination & communication** (Slack, meetings, spec discussion, pairing) | value-add *and* flow-cost (SPACE "C") | human | **invisible** | *effectiveness* (did it unblock/integrate?) + *flow-cost* (fragmentation) | counting minutes or messages |
| 5 | **Planning / thinking / spec** (design, problem framing) | value-add (deep work) | human | **invisible** | none reliable — treat as untracked | pretending it's zero because you can't see it |
| 6 | **Wait — blocked / queued** (awaiting review, CI, a dependency, *your own* availability) | waste | nobody active | **inferable** (`BLOCKED`/`IDLE`/`WAITING_FOR_INPUT`) | wait time; work-item age; flow-efficiency leak | "complicating things by removing it" — Kanban counts it on purpose |
| 7 | **Context-switching / interruption overhead** (DevEx) | waste (cognitive) | human | mostly **invisible** | correlate with WIP / parallel session count | ignoring it — it's the hidden cost of high WIP |

## Direct answer: does a meeting or Slack thread count as work on the task?

**Yes — and the frameworks tell you exactly how to handle it.** It is work-type #4, Communication & Collaboration. SPACE makes this a first-class productivity dimension: *"software development is a collaborative and creative task that relies on extensive and effective communication, coordination, and collaboration."* Writing the design doc, discussing the approach in Slack, reviewing a teammate's PR — all genuine work on the task.

**But measure it by effectiveness, not volume.** SPACE's sharpest warning is that Activity counts (messages sent, meeting-hours) are *"the most ubiquitous… and often the most misused"* metric. A meeting-minute count tells you motion, not value — and under DevEx it *inverts*: more messages/meetings usually means *worse* flow, not more output. So:

- **Its value** is judged by outcome — did the conversation unblock the work, resolve the spec, integrate the change? (Did the card move afterward?)
- **Its cost** is judged by flow impact — did it fragment focus time? DevEx names *"too many meetings"* and *"virtual interruptions (chat)"* as the leading barriers to flow state, with the nuance that *"interruptions themselves are not necessarily negative — it's having too many of them."*

So the defensible stance: **coordination is a real work-type that counts toward the task, measured by effect (outcome + flow-cost), never by duration or message count.**

## The orchestration reframe: *whose* flow efficiency?

The literature assumes one actor doing the work. We have two, and their clocks **invert** — this is the most important original point for our product:

- **Agent clock:** active = `RUNNING`/`RUNNING_TESTS`; wait = idle awaiting human or a dependency. High agent flow-efficiency = agent rarely stalls.
- **Human clock:** active = review + coordination + unblocking; wait = *being free while agents run*.

For a solo dev orchestrating agents, **low *personal* touch-time per task is the goal, not a problem** — it means leverage (the agent works while you don't). Classic flow-efficiency intuition ("low = waste") is *wrong* applied to the human's per-task clock here. What actually binds is **attention contention**: when several agents hit `WAITING_FOR_INPUT`/`BLOCKED` at once, the human becomes the bottleneck. So:

- The signal that matters for *throughput* is **agent wait time** (sessions idling on you).
- The capacity that's *scarce* is **human active time** (review + coordination).

This is exactly the two-axis capacity model from the POC, now grounded: the **attention axis = the "human active" work-types (#3, #4)**, and agent-idle-awaiting-human is the contention metric that should drive the WIP cap.

> ⚠️ **Therefore: compute flow efficiency per actor, and never conflate them.** A single blended "flow efficiency" number across agent + human is meaningless in this model.

## What our watcher can and cannot see (honesty table)

| `SessionState` | Maps to work-type | Observable? |
|----------------|-------------------|-------------|
| `RUNNING` | #1 implementation (agent active) | ✅ observed |
| `RUNNING_TESTS` | #2 automated verification | ✅ observed |
| `WAITING_FOR_INPUT` | #3 review / #6 wait-on-human | 🟡 inferable (dwell) |
| `BLOCKED` | #6 wait (dependency/error) | 🟡 inferable |
| `IDLE` | #6 wait / or off-terminal human work | 🟡 ambiguous |
| `DONE` → next action | #3 review tax (post-generation dwell) | 🟡 inferable |
| *(no state)* | **#4 coordination, #5 planning/thinking** | ❌ **invisible** |

The detector is structurally blind to work-types #4 and #5 — the very ones the user asked about. Pretending they're zero would systematically **undercount human load and over-state flow efficiency**, mis-forecasting exactly when the operator is most loaded (lots of Slack/meetings, few terminal sessions = looks idle, actually slammed).

## Measurement design recommendations

1. **Decompose flow time by value-class from `SessionState` transitions, per actor.** active vs wait is already latent in the state stream; compute it, don't ask for it.
2. **Treat flow efficiency as a *signal*, never a target.** Expect it low. Cite **David J. Anderson's defensible range — "1%–25%, majority toward the bottom end"** (djaa.com) — and *avoid* the widely-repeated "5–15%" figure, which traces to no real study and is often mis-attributed to Forss/Vacanti (neither published a benchmark number). Never rank, never make it a target (Goodhart).
3. **Model coordination (#4) and planning (#5) as an explicit `untracked_human_time` bucket — never a silent zero.** Default to *not* auto-scraping (privacy + Goodhart). Offer **optional, low-friction manual tagging** ("in a meeting about this", "thinking") and/or *consented* cheap signals (calendar-busy) — but the bucket exists and is visible even when empty, so the operator knows the number is a lower bound.
4. **Measure coordination by outcome, not duration.** Did the card unblock / the spec resolve after the conversation? That's the C-dimension's "effectiveness," not minutes.
5. **Pair every system metric with a perception check (DevEx).** A lightweight end-of-session "did that feel productive?" catches the case where the numbers look fine but the experience was fragmented.
6. **Surface coverage honestly.** Observed cycle time is a **lower bound** on true Flow Time (it misses #4/#5). Show the operator how much of a task's time was observed vs untracked.
7. **Anti-patterns (do not ship):** counting messages or meeting-minutes as productivity; a single blended flow-efficiency number; ranking; any metric promoted to a target.

## Implications for the estimation POC

Concrete changes to [poc-estimation-framework.md](poc-estimation-framework.md):

- **`CompletedItem.cycle_time` is "observed active + review time" — a lower bound on true Flow Time.** Add a `coverage` field (observed ÷ estimated-total) and an optional `untracked_human_time: timedelta` so forecasts can be honest about the blind spot.
- **Extend `TaskClass` with a work-type/value-class tag** so per-category distributions can be forecast (review-heavy tasks have a different shape than implementation-heavy ones).
- **The capacity POC's attention axis = work-types #3 + #4** ("human active"); the **agent-idle-awaiting-human** count is the contention metric that should set the WIP cap. Wire `capacity.assess` to that signal, not just to a static bandwidth guess.
- **Compute flow efficiency per actor** in any future flow-efficiency slice; never blend.

## Risks / open questions

| Risk | Severity | Note |
|------|----------|------|
| **Invisible-work undercount** (#4/#5 read as zero) | High | Explicit untracked bucket + optional tagging + visible coverage %. |
| **Surveillance / privacy** if we ingest comms | High | Never auto-scrape Slack *content*; effectiveness not volume; default signals off; consent required. |
| **Goodhart** on any exposed metric | High | No targets, no single metric, no ranking — straight from SPACE/DORA/Beck-Orosz. |
| **Manual-tagging friction** — will a solo dev actually tag meetings? | Medium | Keep it one-tap and optional; degrade gracefully to "untracked." |
| **Flow-efficiency number folklore** | Low–Med | Cite Anderson's 1–25%; flag "5–15%" as unverified; don't attribute to Forss/Vacanti. |

## Open questions

- [ ] Is even minimal manual tagging worth the friction, or is an honest "untracked" bucket enough?
- [ ] Can post-`DONE` dwell reliably proxy review time without an explicit accept signal? (Shared open question with the POC.)
- [ ] Should `IDLE` default to "agent waiting" or "human off doing #4/#5"? (Ambiguous; may need a tie-breaker signal.)

## References

**Primary frameworks:**
- SPACE — https://queue.acm.org/detail.cfm?id=3454124 · https://cacm.acm.org/practice/the-space-of-developer-productivity/
- DevEx — https://queue.acm.org/detail.cfm?id=3595878 · https://cacm.acm.org/practice/devex-what-actually-drives-productivity/
- DORA four keys — https://dora.dev/guides/dora-metrics-four-keys/ · empower teams — https://dora.dev/guides/how-to-empower-software-delivery-teams/
- Beck & Orosz, "Measuring developer productivity? A response to McKinsey" — https://newsletter.pragmaticengineer.com/p/measuring-developer-productivity
- Flow Framework — flowframework.org/faq (per-item defs) · Planview *Flow Metrics* ebook (Flow Time / Flow Efficiency verbatim) · SAFe https://framework.scaledagile.com/accelerating-flow-with-safe
- Lean / VSM — https://www.lean.org/lexicon-terms/value-stream-mapping/ · Martin & Osterling via https://tkmg.com/value-stream-mapping-lead-time/ · software mapping https://medium.com/leadingagile-field-notes/process-cycle-efficiency-metrics-1ec8bf9de622
- Kanban — https://kanbanguides.org/english/ · ProKanban cycle-time spotlight (elapsed incl. blocked) · DevEx flow barriers https://newsletter.getdx.com/p/barriers-to-flow-state

**Flow-efficiency benchmark (use this one, avoid folklore):**
- David J. Anderson, "What We Know About Duration & Workflows" — https://djaa.com (the defensible "1%–25%, majority at bottom end")
- Modig & Åhlström, *This Is Lean* — the 0.2% "Alison" illustration (one example, not a software benchmark)

**Verification flags (carried from the research agents):**
- SPACE's three "myth" *headings* are high-confidence paraphrase (ACM is Cloudflare-blocked to automated fetch); the Activity definition *is* verbatim.
- Flow Framework Risk wording is "security/compliance/privacy" — **not** "governance" (could not verify "governance" verbatim).
- "5–15% flow efficiency" is folklore with no traceable primary study; do **not** attribute a benchmark % to Forss or Vacanti.

**Companion articles:** [estimation-in-the-ai-era.md](estimation-in-the-ai-era.md) · [poc-estimation-framework.md](poc-estimation-framework.md)
