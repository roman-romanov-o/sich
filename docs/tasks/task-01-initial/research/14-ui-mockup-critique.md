# Research: UI Mockup Critique — Pipeline-Columns vs. the Two-Flow Mission-Control Board

**Date:** 2026-06-15 · **Updated:** 2026-06-17 (HTML POC critique — see [§ Update](#update--2026-06-17-the-html-poc-helm--part-d-built) at end)
**Status:** Complete. The Part-D recommendation has since been **realized** by `UI_POC.html` (the "HELM" prototype) — critiqued in the 2026-06-17 update below. Note: C2/C3 and the "don't replace Ghostty" constraint row are **superseded by [[dd-001-embed-libghostty-decision]]**.
**Builds on:** `11-saha-relationship.md`, `12-two-flow-scheduling-model.md`, `13-board-view-and-feature-parity.md`, `05-ghostty-integration.md`, `10-claude-p-quota-change.md`, [[project_vision]]
**Trigger:** User-supplied hand-drawn mockup — *"research the UI I had in mind, you are free to critique it."*

## What the mockup shows (so this report stands alone)

A single screen, four regions:

1. **Top — a 7-column Kanban board:** `Todo · Research · User Stories · Specs · Implementation Plan · Agent Loop · Done`. Cards labelled "Task". One card in *Research* has an arrow drawn down into the terminal pane.
2. **Bottom-left/center — a large "Terminal for the Task"** pane (`> ....`), filling most of the lower half.
3. **Top-right — a tall panel: "Usage stats on Claude tokens and quota."**
4. **Bottom-right — "Recent Tabs"** (Task 1, Task 2), a small quick-switch list.

## Headline finding

The mockup is a **well-composed single-task saha *pipeline visualizer*** — but it is **not yet the portfolio-level, two-flow, two-pool capacity allocator** the prior research converged on (`12`, `13`). Its columns are the `/saha:*` *planning sub-stages*, which silently commits the board to **Flow A only** and drops the product's #1 pillar — situational awareness across many parallel *interactive* sessions (`task-description.md` Problem 1). The instinct (board + drill-down + visible quota) is right; the *altitude* is wrong. This is fixable and the two ideas reconcile cleanly (Part D).

---

## Part A — What the mockup gets right

| Right call | Why it matches the research |
|---|---|
| **Board-first, not tab-first** | `13` Part A: "a tab list answers *what sessions exist*; a board answers *what is the state at a glance, and what needs me*." The board is the correct generalization of cmux's tabs. |
| **Drill-down from a card** (the arrow → terminal) | `13` Altitude 2: clicking a card should drop you into the live session. The *concept* is exactly right. |
| **Quota gets first-class real estate** | The quota/capacity pillar is the differentiator (`10`, `12`); giving it a permanent panel — not a hidden tab — is correct. |
| **A quick-switch list exists** (Recent Tabs) | A reasonable secondary affordance, as long as it stays secondary (see Part C). |

The bones are good. The critique below is about *which board this is*.

---

## Part B — The core tension: the columns model saha's pipeline, not the product's job

The mockup's columns map **one-to-one onto the `/saha:*` lifecycle**:

```
Todo      Research        User Stories   Specs              Implementation Plan   Agent Loop          Done
(backlog) /saha:research  /saha:stories  /saha:test-specs   /saha:plan            saha run /          (DoD passed)
                                         + /saha:contracts                        /saha:execute
```

That is a **planning-progress** axis for **one species of card (Flow A / saha)**. But the research defined the board's axis differently, twice:

- **`12` §3** — columns should differ *by flow*, because the two flows have different lifecycles, different state sources, and spend different pools:
  - **Flow A (saha):** `Backlog → Planning → Ready → Autonomous → Review → Done`
  - **Flow B (interactive Ghostty):** `Backlog → Active → Waiting-on-me / Running / Blocked → Done`
- **`13` Altitude 1** — cards placed in a column **by state** (or swimlane by flow), surfacing *"who needs me" = the count of cards in Waiting/Blocked.*

Three consequences of the mockup's choice:

1. **Flow B has no home.** The ad-hoc interactive Ghostty sessions — the 6–7 parallel tabs that *are* Problem 1 in `task-description.md` — don't flow through Research → Stories → Specs. They never touch saha. The mockup's board literally cannot hold them. The product's founding problem is unrepresented.
2. **"Who needs me" cannot be expressed.** Planning-stage columns track *progress*, not *attention*. A task blocked on human input inside the Agent Loop looks identical to one happily iterating. Yet the **immediate scheduler** — "N sessions are waiting/blocked on you" (`12` §2) — is the single most valuable real-time output. There is no Waiting/Blocked column to receive it.
3. **It answers an open question by accident.** `11` §7 explicitly flagged: *"Does the user want the kanban to also show planning progress (the `/saha:*` lifecycle), or only execution runs? Showing both makes the board the front door to saha."* The mockup answers **"yes, show planning as the board."** That is a *legitimate* product choice — but it should be made *deliberately*, knowing it trades away the mission-control altitude unless reconciled (Part D).

> Restated: the mockup draws **saha's cockpit for one task moving through planning**. The product is meant to be **the cockpit for your whole portfolio of parallel sessions**. Those are two different boards at two different altitudes.

---

## Part C — Point-by-point critique

| # | Element | Issue | Evidence / fix |
|---|---|---|---|
| C1 | **5 columns for planning, 1 for execution** | Priority is inverted. Planning is mostly self-advancing and needs *bursty* attention; **execution is where blocking, waiting, and review concentrate**. Spending 4 columns on Research/Stories/Specs/Plan and collapsing the whole agentic loop into one "Agent Loop" box hides the richest, most attention-hungry state. | `13` Altitude 1: an Autonomous card should show `iteration N · phase QA · 2/5 stories · pool burn` (`11` §5). That detail deserves *more* room than the planning stages, not one box. |
| C2 | **Single embedded "Terminal for the Task"** | The product manages **6–7 sessions in parallel**; one terminal pane = one task at a time = back to the serial tab-hunting that is **Problem 1**. The always-on bottom-half terminal re-creates the problem the board is supposed to kill. | Drill-down should be the *exception* (click → peek/jump), not the permanent half-screen. State-at-a-glance lives on the board; the terminal is summoned, not resident. |
| C3 | **The terminal pane risks the load-bearing constraint** | A big terminal you can type into is either (a) **rebuilding the terminal** → *replaces Ghostty*, explicitly out of scope (`task-description.md` Constraints), or (b) injecting via AppleScript `input text` → coarse, and starts to look like **driving/spawning**. Either way it edges toward the thing the **watcher-not-spawner** rule (`10`, [[watcher-not-spawner-quota-constraint]]) forbids. | `13` Altitude 2 + `05`: drill-down = **`activate window` + `select tab` to focus the *real* Ghostty tab** (primary), plus an **optional strictly read-only last-N-lines peek**. No input box. Label the pane "▸ Jump to Ghostty tab" / "read-only peek", never a prompt. |
| C4 | **"Usage stats on Claude tokens and quota" — wrong noun, wrong altitude** | (a) **"Claude tokens" (singular pool)** misrepresents reality: there are **two Anthropic pools** — interactive (5h + weekly) and the capped **Agent SDK credit** — plus Codex and Gemini (`10`, `task-description.md` Constraints). (b) **"Usage stats" is passive.** The product is **NOT a cost tracker** ([[project_vision]]); it's a **capacity allocator** (`12`). A gauge that only *reports* spend is the single biggest missed opportunity. | The panel's headline should be the **recommender output**: *"Interactive 80% spent, resets 1h10m; API credit 60% free → start task-07 via `saha run` (spends API credit, not your window); hold task-09 (needs-interactive)."* Plus **"projects remaining this cycle, per pool."** Gauges are the supporting cast, not the act. |
| C5 | **Cards are blank ("Task")** | `12` §7 / `13`: **flow-type** and **which-pool-it-spends** must be *first-class on every card*, alongside cmux-style metadata (branch · PR · agent state · iteration/phase). A board whose cards lack flow + pool + state can't do capacity allocation or "who needs me". | Card face: `[A/B] · branch · state(idle/running/waiting/blocked) · iter·phase (saha) · pool burn`. |
| C6 | **"Recent Tabs" as a fixed panel** | Fine as a *secondary* quick-switch. But if it becomes the real navigation, the board has failed its one job (state at a glance). It's a convenience, not a pillar — give it correspondingly little weight. | Keep it small/collapsible; the **Waiting/Blocked count** should be the thing your eye lands on, not a tab list. |
| C7 | **No backlog→capacity intake surface** | Pillar C of `task-description.md` ("you have spare quota → pull project X") has nowhere to live. The backlog (`Todo`) and the capacity signal (quota panel) are in opposite corners with no matchmaker between them. | The capacity recommender (C4) *is* this surface — it should name eligible backlog items + the exact launch command + pool. Wire `Todo` ↔ quota panel. |

---

## Part D — Reconciliation: keep the user's pipeline, but as the *drill-in*, not the top board

The user's pipeline idea and the research's mission-control board are **two altitudes**, not competitors. Propose:

**Altitude 0 — the home board (mission control):** columns by **state**, swimlanes by **flow**. This is the always-on screen; it answers "who needs me" and "what to start next".

```
                         ┌──────────────────────────── CAPACITY BRAIN (was "usage stats") ─────────────────────────────┐
                         │ Interactive ▓▓▓▓▓▓▓▓░░ 80% · resets 1h10m   API credit ▓▓▓▓▓░░░░░ 60%   Codex 30%  Gemini 90% │
   ⚠ 2 sessions          │ ▶ Suggest: start task-07 (autonomous-ready) via `saha run`  ·  ~3 projects left this cycle    │
     waiting on you      └──────────────────────────────────────────────────────────────────────────────────────────────┘
 ┌─────────┬──────────────┬───────────────┬──────────────────┬───────────────┬──────────┐
 │ Backlog │ Ready        │ Running        │ ⚠ Waiting / Blocked │ Review        │ Done     │
A│ [card]  │ task-07 ✔plan│ task-03 it3·QA │                  │ task-05 DoD✓  │ task-01  │  ← Flow A (saha)
─┼─────────┼──────────────┼────────────────┼─────────────────┼───────────────┼──────────┤
B│ [card]  │              │ feat/x running │ ⚠ feat/y needs y│               │ hotfix   │  ← Flow B (interactive Ghostty)
 └─────────┴──────────────┴────────────────┴─────────────────┴───────────────┴──────────┘
        click any card ─▶ drill-in
```

**Altitude 1 — the saha drill-in (THE USER'S MOCKUP, repurposed):** click a Flow-A card and *this* is where the `Research → User Stories → Specs → Implementation Plan → Agent Loop` pipeline lives — as a **per-task progress strip** read from the task README's planning table + saha state (`11` Surfaces A/B). The user's columns are *exactly right here*; they were just one level too high.

**Altitude 2 — the terminal:** a button to **focus the real Ghostty tab** (AppleScript) + an optional **read-only peek** drawer — summoned from a card, not a permanent half-screen, and never an input surface (C3).

Net: nothing the user drew is wasted. The pipeline columns move from the top board down into the saha card's detail view; the top board becomes the two-flow mission control the product exists to be; the quota panel grows from a gauge into the capacity brain.

---

## Constraint check

| Constraint | Mockup as-drawn | After reconciliation |
|---|---|---|
| **Watcher, not spawner** (`10`) | ⚠ At risk — a typable embedded terminal trends toward driving/spawning | ✅ Focus-real-tab + read-only peek; board only *suggests* launches |
| **Don't replace Ghostty** (`task-description.md`) | ⚠ A resident full terminal is a step toward becoming the terminal | ✅ Coexist via AppleScript focus |
| **Track both Anthropic pools** (`10`) | 🔴 "Claude tokens" = one pool | ✅ Two pools + Codex + Gemini |
| **Suggest, never auto-dispatch** (`12`) | n/a (not shown) | ✅ Recommender names the command; human launches it |
| **Flow + pool first-class on cards** (`12`) | 🔴 Cards blank | ✅ Card face carries flow/state/pool |

---

## Open questions (the real decision this surfaces — for `/saha:decide`)

- [ ] **Board topology (the crux):** top-level board by **state + flow swimlanes** with the saha pipeline as a *drill-in* (recommended — preserves the user's columns *and* the mission-control altitude), **or** the mockup's saha-pipeline-as-the-board (simpler, but Flow-A-only and no "who needs me")? *This is the user's product call; it reframes everything downstream.*
- [ ] **Drill-down depth for v1:** AppleScript-focus-only (simplest, honors "don't replace Ghostty"), or also the read-only peek? (carried from `13`)
- [ ] **Does the terminal peek exist at all in v1**, or do we ship board + quota brain first and add any embedded view later?
- [ ] **How prominent is the recommender** — passive ("here's headroom") vs. active ("start task-07 now")? Constraint pins it to suggest-only; prominence is a UX choice (carried from `12`).

## Recommendation

### Proceed with
- The user's three good instincts: **board-first**, **drill-down from a card**, **quota always visible**.
- **Promote the quota panel into the capacity brain** (C4): two pools + Codex/Gemini gauges *and* the "what to start next + which command" recommender. This is the product's reason to exist; draw it as the headline, not a sidebar.
- **Add flow swimlanes + state columns + a Waiting/Blocked attention count** at the top altitude (Part D).

### Avoid
- A **resident, typable terminal** in the layout — it quietly violates watcher-not-spawner and "don't replace Ghostty" (C2/C3). Make it summon-on-click, focus-the-real-tab, read-only.
- **"Claude tokens" framing** — it erases the two-pool model that is the whole differentiator (C4).
- Treating the **saha planning sub-stages as the top-level columns** — that demotes the board to a single-flow pipeline view and drops Problem 1.

### Consider
- Shipping **board + capacity brain first**, with the saha pipeline drill-in and the terminal peek as fast-follows — that order front-loads the differentiator and the hardest-to-fake pillar (cross-pool capacity) while deferring the constraint-risky terminal embedding.

## References
- `11-saha-relationship.md` (flow lifecycle, saha state surfaces), `12-two-flow-scheduling-model.md` (two-flow/two-pool allocator thesis, column semantics), `13-board-view-and-feature-parity.md` (board + drill-down, Vibe Kanban parity), `05-ghostty-integration.md` (AppleScript focus, no resident terminal needed), `10-claude-p-quota-change.md` (two-pool model, watcher constraint).
- `task-description.md` (Problem 1 = parallel-session awareness; Constraints table).
- Memory: [[project_vision]], [[watcher-not-spawner-quota-constraint]], [[saha-relationship-two-flow-thesis]].

---

## Update — 2026-06-17: the HTML POC ("HELM") — Part D, built

**Trigger:** User added `UI_POC.html` — a bundled JS prototype, app name **"HELM · mission control"** — and asked to critique it ("get the best from this design POC, remove unneeded parts"). Rendered + screenshot-explored with the design-critic agent; shots saved in [`ui-poc-shots/`](ui-poc-shots/) (referenced inline below).

**Headline:** The POC **is the Part-D recommendation realized.** It ships **Altitude 0** — the two-flow, state-column mission-control board + the capacity brain — with the saha pipeline correctly demoted into the **Altitude-1 drill-in**. The central call of this whole report ("promote the board to two-flow/state; push the `/saha:*` pipeline into the card detail") was *taken*. So this is no longer "fix the altitude." It's: **keep the strong calls, cut the noise, and settle the one constraint the POC reopens.**

### What it is (shot `01-overview-1440.png`)
- **Chrome:** "HELM · mission control" + filter tabs `all · A·saha · B·interactive`; top-right `cycle resets 6d 14h` and a red **`⚠ 2 waiting on you`** badge.
- **Capacity Brain** (top-left ~40%): one directive — `→ Start task-07`, the literal command `$ saha run task-07` + **copy** button, rationale (*"autonomous-ready · spends Agent SDK credit (60% free) — not your interactive window"*) and a **hold** line (*"hold task-09 · needs the interactive window, only 1h09m left"*).
- **Four pool gauges** (top ~60%): `INTERACTIVE 81%` (resets 1h09m · wk 64%) · `SDK CREDIT 40%` (60% free · sep. pool) · `CODEX 30%` · `GEMINI 10%`. (Animate to fake live burn.)
- **Board:** 6 state columns `backlog · ready · running · ⚠ waiting·blocked · review · done`, **two flow swimlanes** (A/saha, B/interactive). Cards carry flow badge, branch, title, agent, pool, and (A only) `it{N} · phase · done/total`.
- **Drill-in** (slides from right on card click): header `FLOW A/B`, `SPENDS · {POOL}` natural-language block, **SAHA PIPELINE** stepper (A only — shot `19` shows a B card has *no* pipeline, correctly), blocked-decision prompt box, and **TERMINAL FOR THE TASK · embedded · libghostty** with read-only peek lines + the firewall disclaimer.

### Keep — the POC's strong calls
| Element | Why it's right | Evidence |
|---|---|---|
| **Capacity Brain as a recommender, not a gauge** | Exactly the "allocator, not cost tracker" thesis ([[project_vision]], `12`): a directive + the exact command + one-line rationale + a conflicting **hold**. The `copy` affordance is production-ready. | shot `01` |
| **Four separate pool gauges** | Refuses the "Claude tokens" single-pool error this report's C4 called out. Two Anthropic pools (interactive window vs. capped SDK credit) + Codex + Gemini, each with free-remaining + reset. | shot `01` |
| **`waiting·blocked` column + `2 waiting on you` badge** | The board-level **"who needs me"** the report demanded — orange column header with a count (spatially next to the cards) *and* a global red interrupt badge. Card-level `⊘ blocked — needs a decision` / `waiting on you` text. | shots `01`, `04` |
| **Two flow swimlanes** | Both flows finally have a home (Part B fix): A/saha and B/interactive rows, filterable. | shots `01`, `04` |
| **Card metadata density** | Carries the full required payload incl. pool label right-aligned and (A) `it·phase·stories`. Answers C5. | shot `01` |
| **Pipeline lives in the drill-in, not the board** | The Altitude-0/1 split this report proposed, implemented. | shot `14` |
| **Blocked-decision prompt box** | Surfaces the literal decision the agent is waiting on (*"flat flow+pool fields vs nested capacity{}"*). | shot `14` |
| **Firewall copy** | *"Helm hosts the session you launched — it bills your {pool}. It never runs a command or `claude -p` on your behalf."* — the surviving constraint, encoded as visible UI copy. **Load-bearing; keep verbatim.** | shot `19` |

### Cut — unneeded / off-altitude
| Cut | Why |
|---|---|
| **"~3 projects left this cycle"** | Decorative forecast with no estimation model behind it — false precision. Drop until a real model exists. |
| **Swimlane-B sub-label "Ghostty · window"** | Mislabels a *pool* on a *flow* row — B cards also spend Codex/Gemini (see `b-spike`=Gemini, `b-oauth`=Codex). Make it describe the flow: "interactive · human-launched". |
| **Flat start-vs-hold typography** | "hold" is an action directive but renders in the same weight/color as rationale prose — give it a distinct row + muted-warning accent. |
| **(POC bug) card-click sometimes flips the filter** instead of opening the drill-in | Interaction glitch, not a design choice — would confuse a demo. |

### The terminal question — settled against DD-001 (this supersedes C2/C3)
The critic flagged the embedded typeable terminal as a 🔴 *watcher-not-spawner* blocker. **That verdict is based on this report's own now-obsolete framing.** C2/C3 and the constraint-table "don't replace Ghostty" row predate **[[dd-001-embed-libghostty-decision]]**, which **reversed** "don't replace Ghostty": HELM now *is* the terminal (cmux model; Phase 01 already built the in-app libghostty PTY surface). So:

- The **`TERMINAL FOR THE TASK · embedded · libghostty`** panel with a typeable input is the **intended architecture, not a violation.** ✅
- The constraint that **survives** DD-001 is the **pool firewall — never auto-`claude -p`** — and the POC states it verbatim in the firewall copy. Keep it.

The genuine defect the POC reopens is an **internal contradiction**, not a constraint breach. The blocked drill-in (shot `14`) says, in the same panel, both *"↓ the agent is waiting — type your answer below"* (the embedded terminal) **and** *"(answer in the real Ghostty tab)"*. Under DD-001 **there is no separate external Ghostty tab** — HELM hosts the session. The "answer in the real Ghostty tab" string is pre-DD-001 residue.
→ **Fix: commit to the embedded model. The embedded terminal *is* the answer surface; delete the "real Ghostty tab" deflection,** and promote the firewall copy from 9px fine-print to a primary label of the section.

### Constraint re-check (updated for DD-001)
| Constraint | POC status |
|---|---|
| **Never auto-`claude -p` / pool firewall** (the surviving discipline, `10`) | ✅ Encoded as visible copy; `saha run` is *suggested* + copy-to-clipboard, never auto-run |
| **Embed libghostty / be the terminal** ([[dd-001-embed-libghostty-decision]], supersedes "don't replace Ghostty") | ✅ Embedded terminal is on-architecture (fix only the contradictory "real Ghostty tab" copy) |
| **Two Anthropic pools + Codex/Gemini** (`10`) | ✅ Four gauges; minor: group the two Anthropic bars under an "Anthropic" header |
| **Allocator, not cost tracker** ([[project_vision]]) | ✅ Brain routes by pool; no $/token framing (cut "~3 projects" forecast) |
| **Both flows have a home** (`12`) | ✅ A/B swimlanes + filters |
| **Flow + pool first-class on cards** (`12`) | ✅ On the card face |

### Open questions — status after the POC
- [x] **Board topology** — *resolved by the POC:* Altitude-0 two-flow/state board with the saha pipeline as a drill-in. ✔
- [x] **Terminal model** — *resolved by DD-001:* embedded libghostty (HELM is the terminal), not focus-an-external-tab. POC aligns; just remove the contradictory copy.
- [ ] **Start-vs-hold visual hierarchy** in the Brain — make "hold" a distinct, scannable directive.
- [ ] **Group the two Anthropic gauges** under an "Anthropic" label so the routing logic is legible.
- [ ] **`2 waiting on you` click target** — should jump to / filter the waiting column (in the POC it currently flips the swimlane filter); "waiting on you" spans both flows, so filtering to B is wrong.
- [ ] **The `~3 projects left` forecast** — cut, or back it with a real estimation model.

### Net
The POC is a strong, faithful realization of Part D. **Keep:** capacity-brain recommender, four-pool gauges, two-flow swimlanes, the dual "who needs me" signal, the drill-in pipeline, the firewall copy. **Cut:** the "~3 projects" forecast. **Fix:** the swimlane-B pool mislabel, the start/hold hierarchy, the Anthropic-grouping of gauges, and — most importantly — the embedded-vs-real-Ghostty-tab contradiction (resolve toward embedded, per DD-001). With those, this is the product's home screen.
