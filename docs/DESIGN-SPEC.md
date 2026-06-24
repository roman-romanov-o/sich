# Design Spec — Agentic Coding Mission Control

**Status:** Draft for prototyping · **Last updated:** 2026-06-16
**Scope:** UI/UX design specification for the v1 macOS app. Prototype-ready.
**Audience:** the `designer` agent (HTML/CSS mockups), the Swift/AppKit implementer, and the user.

> **How to use this doc.** Build the prototype as a clickable **HTML/CSS** mockup first (fast to
> iterate, screenshot-verifiable), then translate to **Swift/AppKit** using the notes in §13. Every
> screen here cites the user story it satisfies and binds to data shapes **already built** in the
> Python sidecar (`src/mission_control/…`), so the prototype uses real structures, not invented ones.

---

## 1. The product in one paragraph

You run **6–7 agentic-coding sessions in parallel** (Claude Code / Codex / Gemini). Two things break
at that scale: you **lose track of which session needs you**, and you have **no view of how much
subscription capacity is left** to start more. This app is the **cockpit**: a single window that
shows every session as a **card placed by state**, surfaces **"who needs me" at a glance**, lets you
**drill into a session's live terminal** without tab-hunting, and turns raw quota into a **capacity
brain** that tells you *what to start next and which pool it should spend*. It is **saha's cockpit**
(the breadth watcher over saha's single-task depth engine), not a competitor to it.

### What it is NOT — read before designing anything

| It is NOT | Because |
|---|---|
| A **cost/usage tracker** | The value is **throughput** (managing 8 parallel projects, not 5), not saving $15–40/mo. Quota is shown to **allocate capacity**, not to count dollars. |
| A **spawner / orchestrator** | It never launches headless agents. It **watches** sessions the human starts and **suggests** what to start next. (See INV-1.) |
| A **single-pool "Claude usage" widget** | There are **two** independent Anthropic pools that don't trade. Showing one number is the bug the whole product exists to fix. (See INV-2.) |
| A **Ghostty replacement that drives sessions for you** | We *do* now own the terminal (DD-001), but only to **host user-launched interactive sessions** — never to type `claude -p` for you. |

---

## 2. Design invariants (these are hard constraints — a design that violates one is wrong)

These are not preferences. They come from accepted decisions and the economics of the quota split;
the prototype and every later screen must hold all six.

- **INV-1 · Watcher, not spawner.** No UI affordance ever runs `claude -p` / Agent SDK, and nothing
  auto-dispatches work. The capacity recommender **names the command and the human runs it**. There is
  **no "Run" / "Auto-start" button** anywhere. (`research/10`, watcher-not-spawner memory.)
- **INV-2 · Two pools, never netted.** Anthropic is always **two distinct gauges** — *interactive*
  (5h rolling window + weekly cap) and *Agent SDK credit* (monthly, hard-stop). Codex and Gemini are
  their own gauges. Never sum or average pools. (US-006 AC#1; `quota/aggregator.py` enforces this.)
- **INV-3 · Honest confidence.** Inferred values are labeled **"estimated"**; a pool with no data
  reads **"unknown / not tracked"**, never an implied 100% free. A session the detector can't classify
  shows **`unknown`/stale**, never a guessed state. (US-004 AC#3, US-006 AC#3.)
- **INV-4 · The board is home; the terminal is summoned.** State-at-a-glance lives on the board.
  The terminal is a **drill-in** (click a card → focus), **not** a permanent half-screen pane. This is
  the one piece of the original mockup we deliberately change. (`research/14` C2.)
- **INV-5 · We own the terminal, in-app (DD-001).** Drill-in opens the app's **own embedded
  libghostty pane** — real, typable, interactive-pool — focused in **< 500 ms**, in-process, **not** an
  AppleScript jump into Ghostty.app. The pool firewall (in code) keeps it interactive-only. (US-001,
  US-002, DD-001.)
- **INV-6 · Flow + pool + state are first-class on every card.** A card with no flow tag, no pool, and
  no state can't do capacity allocation or "who needs me". Every card face carries all three.
  (`research/14` C5.)

> **Reconciliation note (important).** The earlier UI critique (`research/14`, dated *before* DD-001
> landed the same day) warned against a resident typable terminal because it would "replace Ghostty"
> or look like spawning. **DD-001 reverses the "don't replace Ghostty" basis** — we now embed
> libghostty and own the PTY (US-001/US-002). What survives from that critique is **INV-4** (altitude:
> board is home, terminal is drill-in) — *not* the "no in-app terminal" conclusion. The
> spawning concern is now handled structurally by the **in-code pool firewall**, not by avoiding a
> terminal.

---

## 3. Personas & jobs

| Persona | The job they hire this screen for |
|---|---|
| **Operator** (you, mid-session) | "Glance and know: is anything **waiting on me**? Drop into it and clear it. Don't make me scan 7 tabs." |
| **Capacity Planner** (you, between sessions) | "How much can I still spend this cycle, **per pool**, and **what should I start next** — on which command/pool?" |

Same human, two modes. The **board + attention signal** serve the Operator; the **capacity brain**
serves the Planner. Both live on one screen (§5).

---

## 4. Information architecture — three altitudes

The original hand-drawn mockup put the saha planning pipeline as the *top-level* columns and a big
terminal at the bottom. That's the right set of ideas at the **wrong altitudes**. We split them:

```
Altitude 0 — HOME BOARD (always-on)      → mission control: who needs me, what to start
   │  click a card
   ├── Altitude 1 — DRILL-IN DETAIL       → per-card detail; for Flow-A cards this IS the
   │                                         user's saha pipeline strip (Research→…→Agent Loop)
   └── Altitude 2 — EMBEDDED TERMINAL     → the app's own live libghostty pane (typable)
```

- **Altitude 0** is the screen you live in. §5.
- **Altitude 1** is the user's original pipeline mockup, **repurposed as a card's detail view**. §6.
- **Altitude 2** is the live terminal, summoned from a card. §7.

---

## 5. Screen 1 — The Home Board (Altitude 0)

**Satisfies:** US-003 (board by state), US-005 (who-needs-me), US-006 (two-pool quota). The primary
screen; ~95% of time is spent here.

### 5.1 Layout regions

A single window, three stacked regions. The **capacity brain is the headline** (top), the **board**
is the body, the **attention signal** is pinned top-left where the eye lands first.

```
┌────────────────────────────────────────────────────────────────────────────────────────────┐
│  ⚠ 2 WAITING ON YOU      ┌──────────────────── CAPACITY BRAIN ───────────────────────────┐  │  ← region 1
│  ┌──────────────────┐    │ Anthropic·interactive  ▓▓▓▓▓▓▓▓░░ 80% used · resets 1h10m  ~est│  │     (header)
│  │ • feat/y  blocked│    │ Anthropic·API credit   ▓▓▓▓▓░░░░░ 60% free · monthly hard-stop │  │
│  │ • task-03 waiting│    │ Codex                  ▓▓▓░░░░░░░ 30% free   Gemini ▓▓▓▓▓▓▓▓▓ 90%│  │
│  └──────────────────┘    │ ▶ Suggest: start task-07 via  `/saha:execute` (interactive has  │  │
│   click → filter board   │   headroom) · ~3 projects left this cycle · hold task-09 (needs │  │
│                          │   interactive, low)                                             │  │
│                          └─────────────────────────────────────────────────────────────────┘  │
├────────────────────────────────────────────────────────────────────────────────────────────┤
│        Backlog │ Idle │ Running │ Tests │ ⚠ Waiting │ ⚠ Blocked │ Review │ Done              │  ← region 2
│  ┌───────────────────────────────────────────────────────────────────────────────────────┐ │     (board)
│ A│ task-07   │      │ task-03 │      │           │           │ task-05│ task-01           │ │  Flow A
│  │ ✔plan     │      │ it3·QA  │      │           │           │ DoD ✓  │                   │ │  (saha)
│  ├───────────────────────────────────────────────────────────────────────────────────────┤ │
│ B│ task-09   │ scr..│ feat/x  │      │ task-03   │ feat/y    │        │ hotfix            │ │  Flow B
│  │           │      │ running │      │ ⚠ needs y │ ⚠ blocked │        │                   │ │  (interactive)
│  └───────────────────────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 Region 1 — Capacity Brain (the headline)

This is the product's reason to exist. It is **not** "usage stats" — it is an **allocator**. Two parts:

**a) Pool gauges** — one horizontal gauge per pool, rendered from `PoolGauge` (`quota/models.py`).
Always shown, in this order, **never merged**:

| # | Gauge | Source field notes |
|---|---|---|
| 1 | **Anthropic · interactive** | `refill_kind = rolling_window` (5h) + a secondary weekly marker; `confidence = estimated` (window math) → show a `~est` tag. `reset` = window reset time. |
| 2 | **Anthropic · API credit** (Agent SDK) | `refill_kind = monthly_hard_stop`, `fallback = "none"` → render a **hard-stop** icon and "no fallback" affordance when low/exhausted. |
| 3 | **Codex** | best-effort source; may be `state = unknown` → render "not tracked" (INV-3). |
| 4 | **Gemini** | same. |

Gauge anatomy: `provider·pool` label · bar (fill = `remaining_fraction`) · `remaining_amount unit`
if present · `reset` countdown · a **confidence tag** (`~est` when `confidence = estimated`). Color
by health: green (>50% free) → amber (15–50%) → red (<15% / `exhausted`). `state = unknown` →
hollow/dashed bar + "not tracked", **not** a full or empty bar.

**b) Recommender line** — the active output, suggest-only (INV-1). Format:

> ▶ **Suggest:** start `task-07` via `/saha:execute` *(interactive has headroom)* · ~3 projects left
> this cycle · hold `task-09` *(needs interactive, low)*

Rules:
- It **names a backlog item + the exact launch command + which pool it spends**. It is the bridge
  between the Backlog column and the gauges (closes the `research/14` C7 gap).
- It routes by pool headroom: prefer `/saha:execute` (interactive pool) when the window has room; else
  `saha run` (API credit) or a Codex/Gemini runner. (Two-flow/two-pool thesis.)
- It **never executes**. Clicking the suggested command **copies it / reveals it**, it does not run it.
  No exceptions (INV-1).

### 5.3 Region 2 — The board

**Columns = session state** (matches the built `Column` enum in `board/placement.py` and US-003 AC#1).
Left-to-right, ordered as a natural lifecycle with the **attention zone highlighted**:

```
Backlog → Idle → Running → Running-tests → ⚠ Waiting-for-input → ⚠ Blocked → Review → Done
                                            └──────── attention zone ────────┘
```

- The built `Column` enum is: `idle, running, waiting-for-input, running-tests, blocked, done,
  unknown`. **`Backlog`, `Review`** are lifecycle columns the UI adds around the state set (Backlog =
  not-yet-launched intake item with no live session; Review = `done`/DoD-passed awaiting human review).
  Flag for **DD-004** (§11): whether these are real columns or facets.
- **`unknown`/stale** cards do **not** get a prominent column. Render them with a **dashed border +
  "stale" badge** and float them to the right of their state lane, or in a thin collapsed "Unknown"
  rail. Never silently leave them in `running` (US-004 AC#3).
- **Swimlanes = flow.** Row **A** = autonomous (saha), row **B** = interactive. This makes both pillars
  visible at once: *state* (column) and *flow/pool* (lane). **DD-004 open**: swimlanes-by-flow (default
  here, recommended) vs. single grid with a flow tag on each card. Prototype the swimlane version.

**The attention zone** (`⚠ Waiting-for-input` + `⚠ Blocked`) is visually distinct (amber/red column
headers, subtle tinted background). `attention_count` (§5.4) = the number of cards in these two columns
(`board/attention.py`: exactly `WAITING_FOR_INPUT ∪ BLOCKED`).

### 5.4 The attention signal — "who needs me" (US-005)

Pinned **top-left**, the first thing the eye hits. Binds to `attention_count(cards)`.

- **K > 0:** `⚠ 2 WAITING ON YOU`, amber, with the K count large. Clicking it **filters the board to
  the attention cards** (`attention_cards(cards)`, in order) so you clear them top-to-bottom (US-005
  AC#2).
- **K = 0:** quiet/zero state — muted `✓ all clear`, no alarm color (US-005 AC#3 — no false alarms).
- Optional **age badge** on a card waiting past a threshold (oldest blocker obvious) — never an
  auto-response (US-005 edge case). Mark as optional polish, not v1-blocking.
- Also surface K as a **macOS menubar/dock badge** so it's visible when the window is backgrounded
  (ambient count; push notifications are separate opt-in, not v1 correctness). Open: board header vs.
  menubar vs. both — design says **both**, header is primary.

### 5.5 Card anatomy (the core component — INV-6)

A card is dense and scannable. Built model `Card` (`board/card.py`) carries `session_id, project_dir,
agent, flow, state`. The full face below adds metadata fields (branch, iter·phase, pool, age) that are
**planned extensions** to the model — the prototype should show the full intended face and we annotate
which fields are wired today.

```
┌─────────────────────────────────┐
│ [A] task-07            ● running │   ← flow badge · title (project/session) · state dot+label
│ ~/proj/api · claude              │   ← project_dir (built) · agent (built)
│ feat/quota-gauge · PR #42        │   ← branch · PR        (planned ext)
│ it 3 · phase QA · 2/5 stories    │   ← saha iter·phase·progress  (Flow A only; planned ext)
│ spends: interactive ▓▓░          │   ← which pool this burns   (planned ext; INV-6)
└─────────────────────────────────┘
```

| Element | Source | Status |
|---|---|---|
| Flow badge `[A]`/`[B]` | `card.flow` | ✅ built |
| Title | `card.session_id` / derived from `project_dir` | ✅ built |
| State dot + label | `card.state` (color per §8) | ✅ built |
| Project dir, agent | `card.project_dir`, `card.agent` | ✅ built |
| Branch · PR | (new) | ⏳ planned model ext |
| `it N · phase · M/K stories` | saha state (Flow A only) | ⏳ planned (read from saha files) |
| `spends: <pool>` | (new) | ⏳ planned (INV-6) |

State dot colors per §8. Flow-A cards show the saha iter/phase line; Flow-B cards omit it. Clicking
the card → Altitude 1 (detail) or, with a modifier / on the terminal affordance, → Altitude 2.

---

## 6. Screen 2 — Drill-in detail (Altitude 1)

**Satisfies:** the home for the user's original pipeline mockup. Opened by clicking a card.

For a **Flow-A (saha) card**, this is **exactly the user's hand-drawn pipeline**, repurposed one level
down — a horizontal **progress strip** read from the task's planning artifacts + saha execution state:

```
 task-07  ──────────────────────────────────────────────────────────────────────
  Research ✓ → User Stories ✓ → Specs ✓ → Impl Plan ✓ → ▶ Agent Loop (it3·QA) → Done
  ──────────────────────────────────────────────────────────────────────────────
  [ open live terminal ▸ ]   [ view diff ]   [ resume: `saha resume` ]   spends: interactive
```

- Stages mirror the `/saha:*` lifecycle (`Research → User Stories → Specs → Implementation Plan →
  Agent Loop → Done`). Read from the task README planning table + saha `ExecutionState` (saha surfaces
  A/B). **We ingest saha's telemetry, we don't rebuild it** (saha-relationship thesis).
- For a **Flow-B (interactive) card**, the detail is simpler: branch/PR/dir, recent activity, and the
  **open-terminal** affordance — no saha pipeline (it never went through planning).
- Actions are **read-only or suggest-only**: "view diff" (read-only git diff viewer), "resume" reveals
  the command (`saha resume`) but does not run it (INV-1). The diff viewer is the Vibe-Kanban "Review"
  surface, **read-only** (inline-comment-to-agent is explicitly v2+).

---

## 7. Screen 3 — Embedded terminal (Altitude 2)

**Satisfies:** US-001 (embedded libghostty session), US-002 (drill from card → live terminal).

This is the app's **own live terminal pane** (libghostty), not a screenshot, not Ghostty.app.

- **Summoned, not resident (INV-4).** Click a card's terminal affordance → the live terminal for that
  session becomes focused/visible. It is a drawer/overlay/dedicated pane, **not** a permanent
  bottom-half. Returning to the board leaves board state intact (US-002 AC#2).
- **Real and interactive (INV-5/DD-001).** You can type into it; it runs **native interactive
  `claude`** in a PTY the app owns and reads in-process. Focus in **< 500 ms** (in-app, no OS window
  round-trip — US-002 AC#3).
- **Pool firewall is structural.** The pane can only host interactive `claude`; `claude -p`/`--print`
  is refused in code (`PoolFirewall`, already built). There is **no** "run headless" affordance.
- **Switching between 6–7 sessions stays responsive** — only the focused terminal needs foreground
  rendering (US-002 edge case).
- **Ended session:** show final scrollback **read-only** with a clear "session ended" state and a
  **human-initiated** relaunch affordance — never auto-relaunch (US-001/US-002 edge cases). The card
  moves to a terminal/`done`/`blocked` state, not stale.

> **Prototype note.** A real libghostty pane can't render in an HTML mockup. For the HTML prototype,
> **fake** Altitude 2 with a static styled terminal (monospace scrollback + a fake prompt) to prove the
> drill-in *interaction* and *layout*; the live PTY is wired only in the Swift build (the seam already
> exists: `app/Sources/GhostlingCore/PTYSession.swift`).

---

## 8. Visual design language

Distinctive, dense, terminal-adjacent — a developer mission-control tool, **dark-first**. Avoid the
generic SaaS-dashboard look: no rounded pastel cards, no drop-shadow soup. Think *instrument panel*:
flat surfaces, hairline borders, one confident accent, monospace for all data.

### 8.1 Color tokens (dark theme — the default)

| Token | Hex | Use |
|---|---|---|
| `bg/base` | `#0B0E14` | window background |
| `bg/surface` | `#141A23` | board lane, panels |
| `bg/card` | `#1A2230` | cards, gauges |
| `border/hairline` | `#283143` | 1px separators, card borders |
| `text/primary` | `#E6EDF3` | titles, values |
| `text/secondary` | `#8B98A8` | metadata, labels |
| `text/muted` | `#586173` | de-emphasized, units |
| `accent/brand` | `#3DD4D9` (teal-cyan) | active emphasis, focus ring, selected card |

### 8.2 Semantic state colors (used for state dots, column headers, gauges)

| State | Color | Hex | Notes |
|---|---|---|---|
| `idle` | slate | `#586173` | quiet, no emphasis |
| `running` | teal-cyan | `#3DD4D9` | machine actively working |
| `running-tests` | violet | `#A78BFA` | a distinct "test loop" hue |
| `waiting-for-input` | amber | `#F5A623` | **needs you** — attention zone |
| `blocked` | red | `#FF5C5C` | hard stop — attention zone |
| `done` | green | `#3FB950` | complete |
| `unknown`/stale | dashed gray | `#4A5360` | desaturated, dashed border (INV-3) |

Pool-health colors reuse green/amber/red by `remaining_fraction`; `exhausted` = red + hard-stop glyph;
`unknown` pool = hollow dashed bar.

### 8.3 Typography & density

- **Chrome / labels:** system sans — SF Pro on macOS; use **Inter** in the HTML prototype.
- **Data / metadata / terminal / commands:** **monospace** — SF Mono on macOS; `ui-monospace,
  "JetBrains Mono"` in HTML. All card metadata, gauge values, branch names, and the recommender's
  commands are monospace (they're code-ish, and it aids scanning).
- **Density:** compact. Card ≈ 280px wide, ~6 dense lines. Gauges single-line. This is an
  information-dense instrument, not a marketing page.
- **Light theme:** out of scope for the prototype; design tokens are structured so a light map can be
  added later. Don't build it now.

---

## 9. Interaction & motion

| Interaction | Behavior |
|---|---|
| **Click card** | → Altitude 1 detail (or Altitude 2 via the terminal affordance / a modifier). |
| **Click attention signal** | filter board to `attention_cards`, in order. Click again → unfilter. |
| **Click recommender command** | copy/reveal the command. **Never runs it** (INV-1). |
| **State change (live)** | card animates to its new column within **a few seconds, no manual refresh** (US-003 AC#3). Use a smooth move, not a jarring jump; debounce rapid transitions so the **final** state shows (US-004 edge case — no flicker storms). |
| **Drill to terminal** | focus in **< 500 ms** (US-002 AC#3). |
| **Keyboard** | arrow/`j`/`k` to move card selection; `Enter` → detail; `t` → terminal; number keys → jump to the Nth attention card. (Terminal-user muscle memory; keyboard-first.) |

Motion is **functional only** — column moves and the attention pulse. No decorative animation.

---

## 10. States, empty & edge states (design all of these)

| Surface | Empty / edge | Design |
|---|---|---|
| Board | **no sessions** | friendly empty state: "No active sessions. Start one — `/saha:execute task-07`." (suggest-only). |
| Attention | **K = 0** | muted `✓ all clear` (US-005 AC#3). |
| Card | **`unknown`/stale** | dashed border + "stale" badge + last-seen age (US-004 AC#3). |
| Card | **session ended** | read-only final scrollback affordance + human relaunch (US-001/002). |
| Gauge | **pool exhausted** | red, "exhausted", reset/refill time; API-credit shows **hard-stop / no fallback** (US-006 edge). |
| Gauge | **source unavailable** | hollow dashed "unknown / not tracked" — **not** 0%, **not** 100% (US-006 AC#3, INV-3). |
| Gauge | **inferred value** | `~est` confidence tag (interactive window math) (US-006 AC#3). |
| Recommender | **no headroom anywhere** | "All pools low — hold the backlog; interactive resets in 1h10m." Still suggest-only. |

---

## 11. Open design decisions (resolve during prototyping)

These are genuine product calls flagged in research — prototype the **recommended default**, keep the
alternative cheap to swap.

- **DD-004 · Board topology.** *Recommended:* **swimlanes-by-flow × state-columns** (shows both
  pillars). *Alt:* single grid + flow tag per card. Also: are **Backlog / Review** real columns or
  facets over the built state set?
- **Drill-in depth for v1.** *Recommended:* in-app live terminal (US-002, DD-001). Confirm whether a
  **read-only peek** (last-N-lines on the card) is also v1 or a fast-follow.
- **Recommender prominence.** Constraint pins it to **suggest-only**; prominence (passive "here's
  headroom" vs. active "start task-07 now") is a UX dial — default to a **clearly actionable but
  non-executing** line.
- **Attention count placement.** Board header (primary, default) **and** macOS menubar badge.

---

## 12. Data contracts — what the UI binds to (already built)

The prototype should use these exact shapes (mock the values, keep the structure). All in
`src/mission_control/`:

```
Card            (board/card.py)        session_id, project_dir, agent∈{claude,codex,gemini},
                                       flow∈{A,B}, state∈SessionState
SessionState    (detector/events.py)   idle | running | waiting-for-input | running-tests |
                                       blocked | done | unknown
Column / place  (board/placement.py)   place(cards) -> {Column: [Card]}  (every column key present)
attention_*     (board/attention.py)   attention_count(cards) -> int ; attention_cards(cards) -> [Card]
PoolGauge       (quota/models.py)      provider, pool, state∈{active,exhausted,unknown},
                                       confidence∈{measured,estimated}, refill_kind, fallback,
                                       remaining_fraction, remaining_amount, unit, reset
```

The Swift app: renders `place(cards)` as columns, `attention_count(cards)` as the badge, and
`QuotaAggregator.gauges()` as the gauge row (two Anthropic pools never netted). **Planned model
extensions** for the full card face (§5.5): `branch`, `pr`, `saha_iteration/phase/progress`,
`spends_pool`. Add these to `Card` when wiring the real board.

---

## 13. Prototype scope & AppKit translation

### 13.1 Build for the prototype (HTML/CSS, clickable)

1. **Home board** (§5) with both swimlanes, all state columns, the attention signal, and the capacity
   brain — using the sample data in §14.
2. **Card component** (§5.5) full face, all states (§8.2) including stale/unknown.
3. **Capacity brain** (§5.2): 4 gauges (2 Anthropic + Codex + Gemini), all gauge states (§10), and the
   recommender line.
4. **Drill-in detail** (§6) for one Flow-A card (the saha pipeline strip) and one Flow-B card.
5. **Terminal** (§7) **faked** (static styled scrollback) to prove the drill-in interaction only.

### 13.2 Fake vs. real in the prototype

| Fake (static/mock) | Real (use built shapes) |
|---|---|
| Live PTY / libghostty render (Altitude 2) | Card / Column / PoolGauge **structures** (§12) |
| Live state transitions (script a couple for demo) | `place()` column grouping, `attention_count()` |
| Quota numbers | The two-pool **layout** + confidence/unknown rendering |

### 13.3 HTML → AppKit translation notes

| Prototype (HTML/CSS) | AppKit target |
|---|---|
| Board columns / swimlanes | `NSCollectionView` (or stacked `NSStackView` columns) bound to `place(cards)`. |
| Card | `NSView` cell; the built `Card` + extensions drive it. |
| Capacity brain gauges | custom `NSView` bars bound to `PoolGauge`; `~est` tag from `confidence`. |
| Attention badge | board-header label + `NSApp.dockTile` / `NSStatusItem` badge. |
| Terminal pane | **not faked** — the real `PTYSession` + a libghostty-rendering `NSView` (the one Phase-01 sub-step still open per STATUS.md). |
| Drill-in `< 500 ms` | in-app view focus, never `NSWorkspace`/AppleScript activation. |

Keep the color/state tokens (§8) as a single source (CSS variables → an AppKit color asset catalog) so
the prototype's palette ports 1:1.

---

## 14. Sample data for the prototype

Use this fixture so the prototype reads like a real busy day (2 in the attention zone → `⚠ 2`):

```
Flow A (saha):
  task-07  agent=claude  dir=~/proj/api      state=idle/backlog   it=–          (✔ plan, Ready)
  task-03  agent=claude  dir=~/proj/web      state=running-tests  it=3·QA·2/5   spends=interactive
  task-05  agent=claude  dir=~/proj/cli      state=done           DoD ✓ (Review)
  task-01  agent=claude  dir=~/proj/infra    state=done

Flow B (interactive):
  task-09  agent=codex   dir=~/proj/ml       state=idle/backlog
  feat/x   agent=claude  dir=~/proj/api      state=running
  feat/y   agent=claude  dir=~/proj/web      state=blocked        ⚠   branch=feat/y
  task-03b agent=gemini  dir=~/proj/docs     state=waiting-for-input ⚠ branch=docs/api
  hotfix   agent=claude  dir=~/proj/api      state=done

Quota gauges:
  Anthropic·interactive   remaining_fraction=0.20  confidence=estimated  refill=rolling_window  reset=+1h10m
  Anthropic·API credit    remaining_fraction=0.60  confidence=measured   refill=monthly_hard_stop  fallback=none
  Codex                   remaining_fraction=0.30  confidence=measured
  Gemini                  remaining_fraction=0.90  confidence=measured
  (bonus: show one as state=unknown to exercise the "not tracked" rendering)

Recommender:  start task-07 via `/saha:execute` (interactive headroom) · ~3 projects left · hold task-09
attention_count = 2   (feat/y blocked + task-03b waiting)
```

---

## 15. Acceptance-criteria traceability

| Screen / element | User story | Key AC honored |
|---|---|---|
| Board, state columns, swimlanes, card face | US-003 | each session one card, placed by state; cmux metadata; live column move |
| Card state, `unknown`/stale rendering | US-004 | reflects detected state; explicit `unknown`, never a guess |
| Attention signal | US-005 | always-visible K; filter on activate; zero = quiet |
| Capacity brain gauges + recommender | US-006 | two Anthropic pools distinct; Codex/Gemini; `~est`/unknown honesty |
| Embedded terminal pane | US-001 | interactive `claude` in-app; pool firewall; PTY read |
| Drill from card → terminal | US-002 | click → live terminal; `< 500 ms`; ended-session read-only |

---

## 16. References

- Memory: `project_vision`, `watcher-not-spawner-quota-constraint`, `saha-relationship-two-flow-thesis`,
  `dd-001-embed-libghostty-decision`, `phase-01-terminal-foundation-first-slice`.
- Task artifacts: `docs/tasks/task-01-initial/` — `task-description.md`, `user-stories/US-00{1..6}`,
  `design-decisions/DD-001`, `research/14-ui-mockup-critique.md` (Part D reconciliation),
  `research/13-board-view-and-feature-parity.md`, `research/12-two-flow-scheduling-model.md`, `STATUS.md`.
- Built seams: `src/mission_control/{board,detector,quota}/`, `app/` (Swift package, `PTYSession`,
  `PoolFirewall`).
```
