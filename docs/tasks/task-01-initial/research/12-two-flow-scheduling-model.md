# Research: The Two-Flow Scheduling Model — Why the Kanban Is a Capacity Allocator, Not Just a Board

**Date:** 2026-06-15
**Status:** Complete
**Builds on:** `11-saha-relationship.md`, `10-claude-p-quota-change.md`, `08-revised-viability.md`, [[project_vision]]

## The user's framing, restated precisely

> "I wanna use my time the best, because it's like optimization of schedule, where for tasks you have two types of flow."

The user named two task flows:

- **Flow A — Autonomous (saha):** *long planning → task is ready → run autonomously → review results.* Deep up-front planning, then fire-and-forget execution, then batch review. Human attention is **bursty** (front and back), machine attention is **sustained**.
- **Flow B — Interactive (vibekanban-style):** hands-on, ad-hoc coding in a live Ghostty session. Human attention is **continuous**, the agent is a collaborator, not a contractor.

The insight worth formalizing: **the kanban's real job is not "draw a board" — it is to allocate two scarce resources (the user's attention, and quota) across these two flows.** The board is the UI; the allocator is the product.

---

## 1. Each flow is bounded by a *different* quota pool

This is what makes it a genuine optimization problem rather than a to-do list. From `11-saha-relationship.md` (verified from saha source) and `10-claude-p-quota-change.md`:

| | **Flow A — Autonomous** | **Flow B — Interactive** |
|---|---|---|
| Where it runs | **`saha run`** (headless subprocess) **or** **`/saha:execute`** inside an interactive Claude Code session (v0.9.0+) | Native `claude` in a Ghostty PTY |
| Claude pool drained | **Pool-flexible, by launch command:** `saha run` → **Agent SDK credit pool** (capped, hard-stop); `/saha:execute` → **interactive pool** | **Interactive pool** — 5h rolling window + weekly cap |
| Alt providers | Codex / Gemini runner pools | Interactive Codex / Gemini |
| Human attention | Bursts (plan, then review) | Continuous |
| Failure mode if over-allocated | `saha run` **dies** (credit exhausted); `/saha:execute` hits **interactive lockout** | interactive **lockout** until window resets |
| Recoverability | `/saha:resume` or `saha resume`; or re-route to the pool with headroom | Wait out the window |

The two pools **do not fungibly trade.** Burning interactive quota does not free Agent SDK credit, and vice-versa. So "do I have capacity?" has **two independent answers** — and because **Flow A is pool-flexible** (you pick its pool by launch command), the kanban's move is to *route work to whichever pool has headroom*:

- Interactive fresh, Agent-SDK low → run Flow A via **`/saha:execute`** (spends interactive); or just do Flow B.
- Agent-SDK fresh, interactive low → run Flow A via **`saha run`** (spends API credit), freeing your interactive window for Flow B hands-on work.
- Both Claude pools low → run Flow A on **Codex/Gemini** runners, or defer to next cycle.

**Pool-flexibility is the lever:** the *same autonomous task* can be aimed at whichever pool is cheap right now — that is precisely the routing decision the kanban exists to make.

**No existing tool models this.** Per `07-orchestrator-landscape.md` and `09-current-oss-coverage.md`, orchestrators are quota-blind and trackers are single-pool. A *two-pool, two-flow* allocator is white space.

---

## 2. The scheduling problem, stated plainly

Inputs the kanban already can get:
- **Backlog**, each item tagged by suitability: *autonomous-ready* (saha-plannable, well-specified) vs. *needs-interactive* (exploratory, ambiguous, design-heavy).
- **Live state** of every running session/task (from saha hooks + Ghostty/Claude state detection — `06-agent-state-detection.md`).
- **Remaining capacity per pool** (interactive window/weekly; Agent SDK credit; Codex; Gemini) — and **historical burn per task** (saha's `PhaseTokenUsage` gives this for Flow A directly; Flow B from ccusage-style sources).

Output the kanban should produce:
- **"Who needs me right now"** — the cross-session attention signal (N sessions blocked/waiting). This is the *immediate* scheduler.
- **"What to start next"** — given pool headroom + backlog tags, recommend the next task *and the exact launch command*. This is the *capacity* scheduler. Example: *"Interactive window 80% spent, resets in 1h10m; Agent-SDK credit 60% free → take task-07 (autonomous-ready) and launch it with `saha run` (spends API credit, not your window); hold task-09 (needs-interactive) until the window resets."* Inverted: *"interactive window fresh, API credit nearly gone → run task-07 via `/saha:execute` (subscription-billed)."*
- **"Projects remaining this cycle"** — the burn-rate projection from `task-description.md` §B, now computed **per pool**.

This is deliberately a **decision-support** tool, not an auto-scheduler: it **suggests, never dispatches** (constraint from `10-claude-p-quota-change.md` — auto-dispatch = spawner = wrong pool). The human stays the launcher; the kanban is the advisor.

---

## 3. Why "two flows" changes the board's column semantics

A naive agent-kanban (Vibe Kanban) has one lifecycle: *Plan → Execute → Review*. The two-flow model means a card's columns differ by flow:

- **Flow A card (saha):** `Backlog → Planning(/saha:*) → Ready → Autonomous(/saha:execute or saha run) → Review → Done`. State is machine-readable (saha artifacts + hooks for `saha run`; the live Claude Code session's hooks/JSONL for `/saha:execute`). Mostly self-advancing; the human enters at Ready (launch) and Review.
- **Flow B card (interactive):** `Backlog → Active(live Ghostty session) → Waiting-on-me / Running / Blocked → Done`. State is *observed* (PTY/hook signals). The human is in the loop continuously; "Waiting-on-me" is the key attention column.

Design implication: the board needs a notion of **flow per card** (or two swimlanes), because the columns, the state sources, and the capacity each consumes are different. A single uniform column set would misrepresent one flow or the other. (This is a `/saha:decide` decision, flagged below.)

---

## 4. The "optimize my time" promise, concretely

The throughput thesis from `08-revised-viability.md` (manage 8 parallel projects instead of 5 without dropping balls) sharpens under two flows:

- **Attention is saved** by Flow B's "who needs me" signal (don't tab-hunt 7 sessions).
- **Capacity is saved** by routing autonomous-ready work into Flow A on whichever pool has headroom — turning otherwise-idle Agent-SDK credit / Codex / Gemini quota into completed tasks while the user does Flow B hands-on, or sleeps.
- The two compound **when Flow A is routed to a different pool**: do high-value interactive work in the foreground (Flow B, interactive pool) **while** saha grinds autonomous-ready tasks in the background via **`saha run`** (API credit) or Codex/Gemini — a genuinely parallel second pool. (Caveat: if Flow A is launched via `/saha:execute`, it *shares* your interactive window and competes with Flow B — so when you're actively doing Flow B, the kanban should route background grind to `saha run`/Codex, not `/saha:execute`.) The kanban is the only surface that shows both pools and keeps them from colliding.

That is the "schedule optimization" the user described: **parallelize across the two pools, and spend human attention only where a flow actually needs it.**

---

## 5. Risks / honest caveats

1. **Backlog tagging is the hard input.** "Autonomous-ready vs. needs-interactive" is a judgment call; mis-tagging sends ambiguous work into a fire-and-forget run that wastes a pool. Mitigation: a task is autonomous-ready *only* when its saha planning + `/saha:verify` is green — make Ready a gated state, not a guess.
2. **Two-pool accounting is only as good as the data.** Interactive-pool remaining is partly inferred (window math), not a clean API (`02-provider-data-availability.md`). Recommendation projections should show confidence, not false precision.
3. **Scope creep risk.** The allocator is seductive to over-build (LP solvers, predictions). v1 should be a **legible heuristic** ("pool X has headroom, here are eligible backlog items"), not an optimizer. Validate that the user trusts/uses the suggestion before adding intelligence.
4. **The flows can starve each other on shared providers.** Running saha on Codex *and* doing interactive Codex both drain the Codex pool. The allocator must net live runs against headroom, not just bill history.

## 6. Open questions (for `/saha:task` and `/saha:decide`)

- [ ] **Swimlanes-by-flow vs. flow-tag-per-card** for the board model?
- [ ] **Is backlog tagging manual, or does the board infer readiness** from saha artifact completeness?
- [ ] **How aggressive is the recommender** — passive ("here's headroom") vs. active ("start task-07 now")? Constraint pins it to suggest-only, but the *prominence* is a UX choice.
- [ ] **Does "review results" live in the board** (embedded diff, vibekanban-style — see `13`) or just deep-link to the Ghostty tab / git diff?

## 7. Recommendation

Fold this framing into `task-description.md`: the kanban is a **two-flow, two-pool capacity allocator** whose UI is a board. Make **"flow type" and "which pool it spends" first-class** on every card. Because **Flow A is pool-flexible** (`/saha:execute` = interactive, `saha run` = API credit, runner=Codex/Gemini = their pools), the allocator's core action is **routing the launch command to the pool with headroom** — not merely reporting balances. Keep it a **suggest-only heuristic** in v1. This is the differentiating thesis — what no orchestrator (spawner) and no tracker (single-pool) does, and the concrete form of the user's "optimize my schedule" goal.
