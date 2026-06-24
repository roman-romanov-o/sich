# Research: Estimating tasks & managing capacity when a solo dev runs AI agents

**Date:** 2026-06-17
**Status:** Complete
**Researcher:** Deep-research workflow (5 search angles → 21 sources → 101 claims → 25 adversarially verified, 19 confirmed) + manual synthesis
**Method note:** The workflow's automated synthesis step hit a session limit and was skipped; this report is the manual synthesis over the 19 claims that survived 3-vote adversarial verification, plus established practitioner consensus where flagged.

## Summary

Across the strongest available evidence, AI coding tools do **not** reliably speed experienced developers up — a 2025 RCT measured them **19% slower** on real work while they *felt* ~20% faster. AI does not shift the *mean* of task effort predictably; it inflates the *variance* (cheap boilerplate vs. expensive verification), which is precisely what breaks deterministic point/time estimates. The robust response is to **stop estimating individual items and forecast aggregates probabilistically from your own flow data (Monte Carlo over throughput / cycle-time distributions)**, and to treat **human review-attention — not agent compute or token quota — as the binding capacity constraint**, because AI shifts effort downstream from writing to verifying.

## Research Questions

1. Do AI tools actually speed devs up, and how reliable are time/point estimates in AI-assisted work? (perception-vs-reality gap)
2. Which estimation lens survives high AI-driven variance — time-based, story points, empirical/flow, or capacity/quota?
3. What is the verification/review tax and how should it be accounted for?
4. How do WIP limits & flow efficiency apply to one human supervising many parallel agent sessions?
5. What concrete techniques can a solo dev adopt, and what does this imply for `agentic-coding-kanban`?

## Key Findings

### 1. The perception-vs-reality gap is the central, best-supported finding ⭐ (verified 3-0, 4 independent sources)

**Evidence:** METR 2025 RCT — `https://arxiv.org/abs/2507.09089`, `https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/`; corroborated by `https://www.theregister.com/2025/07/11/ai_code_tools_slow_down/` and `https://newsletter.getdx.com/p/metr-study-on-how-ai-affects-developer-productivity`.

> "Surprisingly, we find that allowing AI actually increases completion time by 19% — AI tooling slowed developers down."

> "Before starting tasks, developers forecast that allowing AI will reduce completion time by 24%. After completing the study, developers estimate that allowing AI reduced completion time by 20%." — i.e. measured −19%, felt +20%.

This was **not a weak study**: 16 experienced devs, 246 real issues, in their own mature repos (avg 22k+ stars, 1M+ LOC). Skilled people on complex code, not novices on toy tasks.

**Implication:** The human supplying an estimate is *confidently, persistently wrong* about their own throughput. Any plan that relies on self-reported speed (or "I feel like this'll take 2 hours") is built on sand. Instrument objective flow data.

---

### 2. AI helps on narrow greenfield tasks — which is exactly why estimates degrade (verified 3-0)

**Evidence:** GitHub Copilot study — `https://github.blog/news-insights/research/research-quantifying-github-copilots-impact-on-developer-productivity-and-happiness/`, `https://arxiv.org/abs/2302.06590`.

> "developers who used GitHub Copilot completed the task significantly faster — 55% faster" (P=.0017, CI [21%, 89%]).

But the task was a **single greenfield "implement an HTTP server in JavaScript from scratch as fast as possible"** — verified as narrow and unrepresentative of maintenance / large-codebase work.

> 🔎 **Verification nuance:** the adversarial verifiers **confirmed** the directional "55% faster" headline but **killed (0-3)** the over-precise restatements ("55.8% faster", "1h11m vs 2h41m"). Trust the direction-on-toy-tasks, distrust the decimals.

**Implication:** Same tool, opposite signs depending on task type. AI changes the *shape* of the effort distribution (bimodal), not its center. This is the mechanism that makes a single point/time estimate meaningless — you can't know up front which bucket a task lands in.

---

### 3. The verification / review tax — effort moves from writing to reviewing (verified 3-0)

**Evidence:** DORA 2025 — `https://dora.dev/dora-report-2025/`, `https://cloud.google.com/blog/products/ai-machine-learning/announcing-the-2025-dora-report`; METR coverage — `https://www.theregister.com/2025/07/11/ai_code_tools_slow_down/`, `https://newsletter.getdx.com/p/metr-study-on-how-ai-affects-developer-productivity`.

> "AI successfully accelerates initial code generation … the time saved in creation is frequently re-allocated to auditing and verification." (DORA)

> "devs accepted less than 44% of generated suggestions and then spent time cleaning up and reviewing." (METR coverage)

> Higher AI adoption raises **both throughput and instability**; without strong automated tests, version control, and fast feedback loops, increased change volume → instability. (DORA)

> 90% use AI, 80%+ feel more productive, yet **30% report little/no trust** in AI-generated code. (DORA)

**Implication:** "Done generating" ≠ "done." Cycle time must run to *verified*. With <44% acceptance observed, budget that a large share of agent output is rework or discard. Time-in-review is the metric to watch; if it grows, you are over-WIP'd.

---

### 4. The bottleneck moved upstream to spec & verification (contested, 2-1)

**Evidence:** `https://www.infoq.com/news/2026/03/agoda-ai-code-bottleneck/`

> "coding was never the real bottleneck … the bottleneck has shifted upstream to specification and verification because these areas require human judgment."

**Implication:** Directionally consistent with DORA, but one verifier dissented — treat as a working hypothesis, not a settled fact. Still: optimizing code-writing speed optimizes a non-bottleneck.

## The four estimation lenses, compared

| Lens | Verdict under heavy AI use | Why |
|------|----------------------------|-----|
| **Time-based** (hours/days) | Weakest; now actively misleading | Can't predict which task lands in "+55% greenfield" vs "−19% gnarly-fix" bucket; the felt duration is provably wrong. Keep only *measured* cycle time as input to flow forecasting. |
| **Relative / story points** | Degrades | AI compresses some N-pointers to 1 and inflates others; *relativity itself* becomes noisy. #NoEstimates (count items, measure throughput) gets stronger here. Keep coarse t-shirt sizes only as a right-sizing/triage signal. |
| **Empirical / flow metrics** | ⭐ **Recommended** | Forecast aggregates with Monte Carlo over your own throughput & cycle-time percentiles (50/85/95). Robust to AI variance *by construction* — doesn't care *why* an item was fast or slow. Requires right-sizing items first. |
| **Capacity / quota** | ⭐ **Binding constraint for this user** | Two scarce resources, smaller binds: (a) token/pool budget across Anthropic ×2 + Codex/Gemini; (b) human review-attention. WIP limit = attention, not compute. |

## The five questions, answered

- **(a) Why estimates degrade:** AI makes the effort distribution bimodal (cheap-boilerplate vs expensive-verification) and the human estimator is systematically, confidently wrong about their own speed.
- **(b) Strongest case for probabilistic forecasting:** It consumes variance instead of fighting it — a Monte Carlo over real cycle-time data yields a *probability* of hitting a date, widening the cone honestly when variance is high, and removes the need to estimate items at all (only count + right-size them).
- **(c) WIP & flow efficiency for a solo agent-supervisor:** The "worker" protected by the WIP limit is the *reviewer (you)*. Too many in-flight sessions → review queue backs up → flow efficiency craters as cards sit "done generating, awaiting human verify." Treat *awaiting-review* as a first-class measured state.
- **(d) Estimating the verification tax:** Don't estimate per-task up front — *measure* it as a lifecycle state. Cycle time runs to verified; watch time-in-review as a share of total cycle time.
- **(e) Concrete techniques:** right-size ruthlessly (split anything that can't finish+review in one sitting); reference-class forecasting per task class (greenfield vs mature-fix vs refactor have different distributions); Monte Carlo aggregate forecasts reported as ranges/probabilities; cap WIP at review bandwidth; quota-aware allocation (route launches to the pool with budget *and* the flow you have attention for); distrust the feeling of speed.

## Validated Assumptions

| Assumption | Status | Evidence |
|------------|--------|----------|
| AI makes experienced devs measurably faster | **Incorrect** (for real work) | METR RCT: −19% on real issues in mature repos (3-0) |
| Devs can self-report whether AI sped them up | **Incorrect** | Felt +20% while measured −19%; predicted +24% (3-0) |
| AI helps on some tasks | **Confirmed but narrow** | Copilot +55% — but only on a greenfield toy HTTP-server task (3-0) |
| Time saved writing is the net gain | **Incorrect** | Time re-allocated to auditing/verification; <44% suggestion acceptance (3-0) |
| Speed gains translate to reliable delivery | **Partial / risky** | AI raises throughput AND instability together without strong controls (3-0) |
| Coding is the delivery bottleneck | **Likely false** | Bottleneck shifted to spec & verification (2-1, contested) |

### Claims that were *refuted* in verification (do not rely on)

- "AI gives individual gains but reduces team throughput" (killed 1-2 — overstated vs 2024 DORA).
- "AI is an amplifier not a multiplier" framing (killed 1-2 — too strong as stated).
- Copilot "55.8% faster" / "1h11m vs 2h41m" precise figures (killed 0-3).
- "21% more tasks / 98% more PRs / 91% longer review" (killed 1-2 — not solidly sourced).

## Risks Identified

### 1. Building velocity features on self-reported estimates (Severity: High)
**Description:** Any UI field asking the user to estimate effort inherits the proven perception bias.
**Mitigation:** No estimate fields. Derive everything from measured cycle time / throughput.

### 2. Treating "agent done" as "task done" (Severity: High)
**Description:** Ignoring the verification tax under-counts real cycle time and hides the true constraint.
**Mitigation:** First-class `awaiting-verify` / `in-review` board state; cycle time runs to verified.

### 3. Capacity modeled on quota alone (Severity: Medium)
**Description:** Token/pool budget is only one axis; human review-attention is the other and usually binds first.
**Mitigation:** Two-axis capacity model; WIP limit driven by attention.

### 4. Over-trusting this report's flow-metrics specifics (Severity: Low–Medium)
**Description:** The run's adversarial verification budget concentrated on AI-productivity claims; the Monte-Carlo / #NoEstimates / Vacanti sources were fetched but their specific claims were **not** individually re-verified.
**Mitigation:** Treat flow-metric specifics as practitioner consensus; re-verify before encoding precise numbers.

## Recommendations

### Proceed With
- **Empirical/flow forecasting** as the estimation model (Monte Carlo over throughput + cycle-time percentiles).
- **Two-axis capacity model**: quota/pool budget × human review-attention; bind on the smaller.
- **Verification as a first-class board state**; cycle time to verified; track time-in-review ratio.
- **Per-task-class cycle-time distributions** (greenfield / mature-fix / refactor).
- **An attention signal that surfaces objective throughput** to counter the felt-speed illusion.

### Avoid
- Asking the user for time or point estimates.
- Single-date ETAs / false precision.
- Equating agent wall-clock with task completion.
- Modeling capacity on tokens alone.

### Consider
- Coarse t-shirt sizing kept only as a right-sizing trigger (flag oversized cards), not a forecast input.
- Routing the two-flow allocator by (pool budget × current free attention), not pool budget alone.

## Implications for the product (`agentic-coding-kanban`)

1. **Never ask the user to estimate; forecast from observed flow.** No point/hour fields. The board logs cycle time per card and runs Monte Carlo over history. Biggest, most evidence-backed design stance.
2. **Capacity is two-dimensional.** Extend the capacity brain (quota across pools) with a second axis — human review-bandwidth — and make the WIP limit a function of attention, not token budget.
3. **Make the verification tax a first-class board state.** An explicit `awaiting-verify` / `in-review` column between agent-done and done; cycle time counts to verified; time-in-review ratio is the over-WIP early warning.
4. **Per-task-class distributions, not one velocity number.**
5. **The attention signal fights the perception gap.** Because the operator *feels* fast while possibly being slow, prominently surface the objective throughput/cycle-time number — a genuine differentiator: a cockpit that tells you the truth about your own velocity.
6. **Two-flow allocation = route by (pool budget × free attention).**

## Open Questions

- [ ] What's the right default WIP cap (sessions per human) before review quality degrades? Needs empirical calibration from real usage.
- [ ] How to classify a card's task-class automatically (greenfield vs mature-fix vs refactor) to pick the right reference distribution?
- [ ] Does the 2-1 "bottleneck moved upstream" claim hold for solo agent-orchestration specifically?
- [ ] Re-run the workflow's automated synthesis step (cached) after the session limit resets, to compare against this manual synthesis.

## References

**Primary / empirical (weighted highest):**
- METR 2025 RCT — https://arxiv.org/abs/2507.09089 · https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/
- DORA 2025 — https://dora.dev/dora-report-2025/ · https://cloud.google.com/blog/products/ai-machine-learning/announcing-the-2025-dora-report
- GitHub Copilot productivity study — https://github.blog/news-insights/research/research-quantifying-github-copilots-impact-on-developer-productivity-and-happiness/ · https://arxiv.org/abs/2302.06590

**Secondary coverage:**
- https://www.theregister.com/2025/07/11/ai_code_tools_slow_down/
- https://newsletter.getdx.com/p/metr-study-on-how-ai-affects-developer-productivity
- https://www.infoq.com/news/2026/03/agoda-ai-code-bottleneck/

**Flow-metrics / forecasting practitioner consensus (fetched, not individually re-verified this run):**
- ProKanban (trusting Monte Carlo) — https://www.prokanban.org/blog/trustingmcs
- Daniel Vacanti / Agile for Humans — https://agileforhumans.com/agile-metrics-for-predictability-daniel-vacanti/
- #NoEstimates probabilistic forecasting — https://noestimates.wordpress.com/probabilistic-forecasting/
- Businessmap (Kanban forecasting) — https://businessmap.io/blog/kanban-forecasting
- 55 Degrees (Monte Carlo + flow metrics) — https://www.55degrees.se/post/agile-forecasting-monte-carlo-simulations-and-flow-metrics
- Teamhood (Kanban flow metrics) — https://teamhood.com/kanban-resources/kanban-flow-metrics/

**Related (this repo):**
- `MEMORY.md` → project vision, saha relationship + two-flow thesis, watcher-not-spawner quota constraint
