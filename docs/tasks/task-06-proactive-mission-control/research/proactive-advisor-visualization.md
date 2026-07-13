# Research: Visualizing the Proactive Mission-Control Advisor

**Status:** Review
**Date:** 2026-07-05
**Audience:** product designer building low-fidelity and clickable prototypes
**Scope:** information architecture and interaction schematics only; no visual
style, colors, typography, or implementation specification

## 1. Design problem

The interface must answer five questions in this order:

1. **What should I do now?**
2. **Why is that better than the obvious alternative?**
3. **When will an agent need me again?**
4. **What should I prepare for later?**
5. **What constraint prevents other work?**

The current board and quota design answers “what is running?” and “what capacity
is left?” The proactive policy changes the center of gravity: the primary
object is now a bounded recommendation to the user. The board, timeline,
attention queue, and capacity data explain and support that recommendation.

The interface must also correct a misleading simplification: interactive Claude
work does not consume human attention continuously. A turn alternates:

```text
YOU compose → CLAUDE works → YOU review → YOU decide → CLAUDE works …
```

When Claude works for 2–60 minutes, the user's attention may be available. The
UI must show both conversational ownership and actual attention occupancy.

## 2. Concept: “Now + Runway + Fleet”

Use one home screen with three reading depths:

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│  1. NOW                                                                      │
│  one recommendation · duration · reason · expiry · controls                  │
├──────────────────────────────────────────────────────────────────────────────┤
│  2. RUNWAY                                                                   │
│  aligned YOU and AGENTS time tracks · meetings · returns · unattended window │
├──────────────────────────────────────────────────────────────────────────────┤
│  3. FLEET                                                                    │
│  Agent Owns Turn │ Completion Queue │ Ready Next                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

- **Now** is the command surface.
- **Runway** makes time and overlapping human/machine work understandable.
- **Fleet** preserves mission-control awareness without competing with the
  recommendation.

Quota/provider detail is not a fourth permanent region. It appears as compact
route evidence on a recommendation and as a drawer/inspector when needed.

### Canonical terminology and behavior

The home surface uses only:

```text
NOW
ATTENTION DELIVERY: ELIGIBLE · DELIVERED · QUEUED
RUNWAY: YOU + selected agent + aggregate other agents
FLEET: AGENT OWNS TURN · COMPLETION QUEUE · READY NEXT
SOURCE STATUS / UNCERTAIN
```

Rules:

- only `DELIVERED` attention participates in primary-action recomputation;
- delivery never automatically wins—recomputation chooses one Now action;
- entity staleness is passive; decisive-source expiry withdraws/recomputes Now;
- an unknown session is not counted as working and has no return estimate;
- raw backlog is not Ready Next.

## 3. Home screen schematic

```text
┌ GHOSTLING ─────────────────────────────────────────────── 14:07 ─────────────┐
│ NOW                                                                           │
│ ┌───────────────────────────────────────────────────────────────────────────┐ │
│ │ Continue  task-18 / API auth                              18 min           │ │
│ │ Keep the current context; the slice fits before the meeting buffer.       │ │
│ │ UNTIL 14:25  ·  THEN 12 min break → Design sync 14:45                    │ │
│ │ Fits known calendar · duration is rough · no override used                │ │
│ │ [Acknowledge slice] [Why] [Not now] [Choose]                              │ │
│ │ Effect: Ghostling plan only → state becomes ACK; no timer/agent starts    │ │
│ └───────────────────────────────────────────────────────────────────────────┘ │
│                                                                               │
│ DELIVERY passive · delivered interrupt: none                                │
│ ATTENTION queued: Codex C until 14:25 · critical muted: none                 │
│ YOU     protected on task-18 until 14:25 · next: meeting buffer              │
│ RUNWAY  14:00 [LIVE task-18] ▲14:07 ┆PROPOSED to 14:25┆                     │
│         14:25 ┆OPTION break┆ 14:40 ├FIRM CALENDAR meeting──┤                │
│         16:00 ├TENTATIVE review A┄┄┄┤                                        │
│ SELECTED      ├ Claude A turn: AGENT · expected ready 2–6m                   │
│               new-task gap: NONE · continuing task-18 remains valid          │
│ OTHER AGENTS  1 working · 1 response ready · [show lanes]                    │
│                         ▲ now          ◆ next boundary                        │
│                                                                               │
│ FLEET                                                                         │
│ ┌ AGENT OWNS TURN 2 ──────┐ ┌ COMPLETION QUEUE 1 ───┐ ┌ READY NEXT 1 ────┐ │
│ │ Claude A · ready ~2–6m  │ │ task-07 · review 35m   │ │ task-22          │ │
│ │ new-task gap: NONE      │ │ reserved tomorrow     │ │ plan Saha · 45m  │ │
│ │ +1 working      [All 2] │ │              [All 1]  │ │ admitted [All 1] │ │
│ └─────────────────────────┘ └────────────────────────┘ └───────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Reading order

1. Recommendation verb and task.
2. Duration and stopping point.
3. One-sentence binding reason.
4. Runway collision/fit.
5. Agent attention status.
6. Supporting evidence and alternatives.

The interface should be understandable from the first two lines without reading
the board or quota.

### Primary-action arbitration

There is exactly one Now action. Recompute candidates in this order:

1. hard boundary or evidence-supported safety/recovery action;
2. unresolved accepted-commitment conflict;
3. delivered attention request by SLA risk;
4. protected acknowledged slice;
5. open feasible candidates.

A delivery event is new evidence, not an automatic winner. If a schedule
conflict remains primary, a delivered permission request appears as
`visible · deferred by higher hard constraint`; if the request wins
recomputation, Now changes to Respond and the conflict becomes queued context.

## 4. The Now card

### 4.1 Collapsed state

```text
┌ NOW ──────────────────────────────────────────────────────────────────────┐
│ Plan task-22 with Saha                                          45 min    │
│ This turns tonight's 7h unattended window into useful agent work.         │
│ Until 17:10 · then prepare workspace / preflight                           │
│ [Open task] [Why] [Not now] [Choose another]                               │
│ Effect: Navigation only · proposal remains · no agent starts                │
└────────────────────────────────────────────────────────────────────────────┘
```

Required fields:

- imperative action;
- card/task name;
- bounded human duration;
- binding reason;
- stop/expiry condition;
- one contingent next step;
- controls appropriate to the action.

Do not lead with a score, quota percentage, model name, confidence label, or
generic “AI recommendation” heading.

### 4.2 Expanded “Why this?” state

```text
┌ WHY THIS? ─────────────────────────────────────────────────────────────────┐
│ Chosen because                                                              │
│  1  Current context is protected until 14:25.                               │
│  2  18 minutes fit before the meeting buffer.                               │
│  3  Codex C can wait until the boundary; its request is not urgent.         │
│                                                                             │
│ Summary      Fits known calendar · duration is rough · no override used     │
│ Evidence     measured calendar · static duration · recovery unknown          │
│ Downgrade    Duration history is sparse; another feasible option may rank    │
│              higher after more evidence. No safety gate is uncertain.        │
│ [Technical evidence ▸]                                                       │
│                                                                             │
│ Other feasible choices                                                      │
│  Review task-07       loses current context; better at 16:00                │
│  Answer Codex C       would win if its request becomes urgent               │
│                                                                             │
│ [Keep recommendation] [Choose alternative] [Why not another task…]          │
└─────────────────────────────────────────────────────────────────────────────┘
```

The explanation is progressive disclosure. The collapsed card shows one reason;
the sheet exposes the trace in human language. Alternatives are counterfactual:
state what would need to change for them to win.

Collapsed confidence uses consequences, not internal product stages:

```text
Fits known calendar · duration is rough · no override used
Safe to fit · another feasible option may rank higher
Unavailable · decisive calendar evidence expired
```

Why first exposes human-language downgrade causes. A tertiary
`Technical evidence` disclosure contains evidence quality, feasibility risk,
ranking confidence, search completeness, capability phase, accepted-risk
override, and exact source versions. “Chosen” becomes “best found” when search
is limited.

### 4.3 Action-specific controls

| Recommendation | Primary controls |
|---|---|
| Continue/focus | `Acknowledge slice`, `Not now`, `Choose another` |
| Rest | `I’ll take this break`, `I already rested`, `Skip once` |
| Respond/review | `Open session`, `At boundary`, `Not now` |
| Plan Saha | `Open task`, `Defer`, `Choose another` |
| Suggest launch | `Copy command`, `Inspect bundle`, `Reject bundle` |
| Shut down | `Done for today`, `Extend workday`, `Dismiss` |

Persistent control copy reads:
`Advisory only — no timer or agent is started.` Agent launch remains
copy/reveal only. After copying, the state is `Awaiting observed launch` until a
matching session is detected.

### 4.4 Control-effect contract

| Now state | Control | Mutation | Result | Reversible / confirmation |
|---|---|---|---|---|
| Proposed human slice | `Acknowledge slice` | firms only this human reservation | `ACK`, then `LIVE` if observed | stop is reversible |
| Any ordinary proposal | `Not now` | rejects this attempt/fingerprint | recompute or passive | reversible via alternatives |
| Rest proposal | `I’ll take this break` | records intent, starts no timer | `ACK break` | reversible |
| Response | `Open session` | navigates only | request remains until resolved | reversible |
| Saha planning | `Open task` | navigates only | proposal remains | reversible |
| Launch bundle | `Copy command` | clipboard write only | awaiting observed launch | confirmation copy; no execution |
| Conflict | `Move / shorten / cancel` | none until preview confirmed | scoped plan mutation | explicit preview + confirmation |
| Shutdown | `Done for today` | sets user-owned day state | work proposals suppressed | reversible by extend workday |

`Space` is enabled only when focus is on an actionable proposed human slice.
It is disabled for conflicts, missing-input cards, launch bundles, text inputs,
and the terminal. Other states require their labeled control.

Every Now schematic places an `Effect:` line directly beneath its primary
controls and shows the resulting state token in the same location after action.
It may say only one of: `Ghostling plan only`, `Navigation only`,
`Clipboard only — no launch`, or the explicit user-owned setting mutation.

## 5. The two-track runway

### 5.1 Purpose

The runway explains why a recommendation fits. It is not a full calendar.

- **YOU track:** focus slices, breaks, reviews, meetings, buffers, off-hours.
- **AGENTS track:** each active turn/run, expected return range, response-ready
  point, unattended execution, and review obligation created.

Both tracks share the same horizontal clock so users can see parallelism.

The default home runway shows one selected/urgent agent lane plus aggregates.
Expanding `show lanes` reveals all agents. This prevents 6–8 sessions from
turning the home screen into a dense Gantt chart.

### 5.2 Commitment and certainty grammar

```text
proposed Now slice        ┆ PROPOSED ┆  expires if unacknowledged
acknowledged reservation  ├ ACK ┄┄┄┄┤
observed / in progress    ├ LIVE ━━━━┤
firm human commitment     ├ FIRM CALENDAR ━┤
observed agent execution  ├ LIVE AGENT ────┤
tentative reservation     ├ TENTATIVE ┄┄┄┄┤
conditional option        ┆ OPTION ░░░░░░░┆  NOT SCHEDULED
estimated return          ├ LIVE AGENT ─░░ range ┤
unknown completion        ├ LIVE AGENT ─────→ ?
response ready            ↑
attention boundary        ◆
manual launch latest      │
```

Use ranges for agent return predictions. Never show a precise ETA when only a
broad p80 bound exists.

Every segment carries its text token; stroke/color is redundant. The detailed
three-hour runway is time-proportional with labeled 30-minute ticks and optional
15-minute minor ticks. It horizontally scrolls. Coarse “today/tomorrow” tails
use separate summary bands and never share the detailed scale.

At `now`, split observation from proposal:

```text
13:55 ├ LIVE task-18 ━━━▲ now ┆ PROPOSED continuation to 14:25 ┆
```

Staleness has two visual consequences:

- stale entity metadata stays muted on its card;
- stale **decisive** evidence immediately expires the recommendation.

Example:

```text
NOW withdrawn
Calendar evidence expired at 14:10; the previous 14:25 fit is no longer valid.
[Set free-until…] [Refresh calendar] [Use short-task mode]
```

Why shows source age and `valid until`; the runway removes the invalid proposed
segment rather than leaving it as a low-priority warning.

An unlaunched task is always a conditional option labeled
`MANUAL LAUNCH REQUIRED · NOT SCHEDULED`. It becomes a solid observed run only
after matching execution evidence. Future review remains tentative and
conditional on an output requiring review.

Before `Acknowledge slice`, the Now interval is only a proposed outline ending
at recommendation expiry. Acknowledgement firms its human reservation; observed
activity changes it to in-progress. A proposed break or following task never
looks like a firm calendar block.

### 5.3 Claude turn states

```text
YOU WRITING       turn owner: YOU    · new-task gap: NONE
CLAUDE WORKING    turn owner: AGENT  · new-task gap: NONE  · return ~2–6m
SAFE SHORT GAP    turn owner: AGENT  · new-task gap: BRIEF 8m
LONG RUN          turn owner: AGENT  · new-task gap: FOCUS 30m
RESPONSE READY    turn owner: YOU    · queued for boundary 14:25
STATUS UNKNOWN    no turn owner or gap · last seen 13:42 · Source Status
```

`TURN OWNER` and `NEW-TASK GAP` are separate. Agent ownership never implies
reusable attention. The new-task gap is policy-admitted from
return uncertainty, switching cost, buffers, and minimum useful slice.

The global operator line separately states the protected/acknowledged human
slice, for example `YOU: protected on task-18 until 14:25`. Thus a new-task gap
of `NONE` does not contradict continuing the current protected task.

An interactive session remains one card while its turn owner changes. Do not
move it between Saha/interactive lanes merely because Claude is working.

### 5.4 Wait-window recommendations

The Now card and runway work together:

```text
Claude return ~2–5m
NOW: Take a microbreak; keep task-18 context.

Claude return ~8–18m
NOW: Review task-07 in the same repository; stop when Claude returns or at 14:25.

Claude return ~35–60m
NOW: Checkpoint task-18, then plan task-22 with Saha for 30m.
```

If a response arrives early, it appears in the attention-delivery strip and on
the runway. It does not automatically replace a protected Now recommendation.
Only a `DELIVERED` request enters recomputation, and it replaces Now only if it
wins primary-action arbitration. Otherwise it is explicitly queued for a named
boundary.

## 6. Fleet schematic

Attention delivery is above Fleet:

```text
ELIGIBLE   none
DELIVERED  none
QUEUED     Codex C · SLA safe · review at 14:25
```

Severity and delivery are separate:

```text
INTERRUPT ELIGIBLE   request passes urgency/evidence policy
INTERRUPT DELIVERED  user mode + quiet hours + mute + notification cap allow it
```

Only `INTERRUPT DELIVERED` enters primary-action recomputation; the arbitration
rule decides whether it replaces Now. An eligible request that delivery suppresses reads
`Critical · delivery muted · queued until 14:25`. There is never a simultaneous
conflicting focus recommendation.

Replace the eight-column lifecycle board on the everyday advisor screen with
three operational zones:

```text
┌ AGENT OWNS TURN ──────────┬ COMPLETION QUEUE ──────────┬ READY NEXT ─────────┐
│ Claude / Saha working     │ review accepted output     │ admitted Saha plan  │
│ tests / tool call         │ integration / verify       │ current preflight   │
│ observed live runs only   │ non-urgent repair          │ feasible next action│
└───────────────────────────┴────────────────────────────┴─────────────────────┘
```

The detailed state-column × flow-swimlane board remains available as a secondary
“All sessions” view. The home Fleet is an operational projection optimized for
what the user can act on now.

Placement precedence is deterministic: interrupt/queued delivery strip first,
then `AGENT OWNS TURN → COMPLETION QUEUE → READY NEXT`. A primary card appears
once; cross-cutting conditions use badges. Failed or blocked output becomes an
interrupt or queued item when it needs a decision; otherwise it remains a
non-urgent completion obligation.

`READY NEXT` contains only currently admitted, feasible next actions. Raw
backlog lives in All Sessions and appears as
`CANDIDATE — NOT YET ADMITTED · missing: <first gate>`.

Each zone shows only its highest-precedence cards and an `All N` affordance.
Within a delivery/zone class, visible order is: delivery class, SLA risk,
earliest boundary, then stable card ID. Overflow summarizes
`N queued · next due HH:MM`.

Unknown/stale sessions appear only in `SOURCE STATUS / UNCERTAIN`:

```text
STATUS UNKNOWN · task-31 · last seen 13:42 · watcher source unavailable
```

They contribute to neither working counts nor return ranges.

### 6.1 Card anatomy

```text
┌────────────────────────────────────┐
│ task-18                    CLAUDE   │
│ working · return ~2–6m             │
│ turn owner: AGENT                   │
│ new-task gap: NONE                  │
│ interactive · Anthropic window     │
│ next: review response              │
└────────────────────────────────────┘
```

Card priority:

1. task;
2. current attention owner/state;
3. return/age;
4. flow;
5. provider route;
6. next obligation.

Do not show branch, token count, quota bar, Saha iteration, or repository path
unless the user expands the card.

## 7. Scenario schematics

### 7.1 Meeting soon: do not start deep work

```text
NOW
┌ Take a 12-minute break ────────────────────────────────────────────────────┐
│ The meeting starts in 24m; only 12 useful minutes remain after buffers.    │
│ Then: Design sync 14:45 → continue task-18 at 15:30                        │
│ [I’ll take this break] [I already rested] [Choose a small task]            │
│ Effect: Ghostling plan only → ACK break; no timer starts                    │
└─────────────────────────────────────────────────────────────────────────────┘

YOU     ┆ PROPOSED break 12m ┆ ├ FIRM CALENDAR meeting incl. buffer ━━━━━━━┤
AGENTS  ├ LIVE AGENT Claude A ─░ return range ↑ queued to boundary
```

### 7.2 Prepare one overnight task

```text
NOW
┌ Plan task-22 with Saha · 45m ──────────────────────────────────────────────┐
│ A verified plan could use tonight's unattended window.                    │
│ Conditional: plan → verify → workspace → preflight → copy launch command  │
│ [Open task] [Inspect possible plan] [Not now]                              │
│ Effect: Navigation only · no agent is launched                             │
└─────────────────────────────────────────────────────────────────────────────┘

YOU     16:20 ┆ PROPOSED plan 45m ┆ leave 18:00
GATES         ┆ OPTION PLAN_VERIFY → workspace → PREFLIGHT ┆
RUN OPTION                                             ┆ OPTION run ░░░░░░┆
                                                          MANUAL LAUNCH REQUIRED
TAIL       if observed run produces output:
           ┆ TENTATIVE REVIEW 45m ┆ → ┆ TENTATIVE INTEGRATE 15m ┆
           → ┆ TENTATIVE VERIFY 15m ┆
           reserved window: tomorrow 09:00–10:15 · tentative until output

Invalidation:
PLAN_VERIFY fails ──→ release preflight, run, review, integrate, verify options

Status: downstream steps are conditional until planning/verification pass.
```

### 7.3 Claude is working for an hour

```text
NOW
┌ Checkpoint task-18, then review task-07 · 30m ─────────────────────────────┐
│ Claude is in a long run (~35–60m); your attention is available.            │
│ Return to task-18 when this slice ends, not immediately on response.       │
│ [Acknowledge slice] [Why] [Not now]                                         │
│ Effect: Ghostling plan only → ACK review slice                              │
└─────────────────────────────────────────────────────────────────────────────┘

YOU     ┆ PROPOSED checkpoint + review task-07 ┆ return boundary ◆
AGENTS  ├ LIVE AGENT Claude task-18 ─░░ estimated return range ┤
```

### 7.4 Response arrives during protected focus

```text
14:12  Claude A response ready

NOW remains: Continue task-18 until 14:25
Queued for boundary: Claude A · ready · SLA safe · boundary in 13m
Runway:    ↑ response ready ───────────────◆ review boundary

Boundary notification:
“Claude A is ready. Review now, or continue task-18 for another slice?”
```

### 7.5 Boundary bundle with concurrent returns

```text
14:25 · FOCUS BOUNDARY
┌ 2 current responses · 1 resolved item removed ─────────────────────────────┐
│ FIRST  Claude A · permission request · SLA at risk                         │
│ NEXT   Codex C · response ready · SLA safe                                 │
│                                                                            │
│ NOW updates to: Respond to Claude A · ~3m                                  │
│ [Open Claude A] [At next boundary] [Continue focus]                         │
│ Effect of Open Claude A: Navigation only · request stays open until resolved│
└─────────────────────────────────────────────────────────────────────────────┘
```

Before delivery, the bundle:

1. deduplicates by request/session generation;
2. drops resolved, invalidated, and expired items;
3. orders by delivered severity, SLA risk, boundary, then stable ID;
4. recommends the first response and shows the deferred count.

If an item escalates while delivery is muted, the strip shows
`Critical · muted`; it does not bypass quiet hours, immediate mute, or the
hourly cap. The next permitted bundle contains the current—not historical—set.

### 7.6 No trustworthy recommendation

```text
NOW
┌ Set your available-until time ──────────────────────────────────────────────┐
│ Calendar access is unavailable, so Ghostling cannot safely fit deep work.   │
│ [Free until…] [Use short-task mode] [Stay passive]                          │
│ Effect: stores a scoped user assertion or mode; no work starts              │
└─────────────────────────────────────────────────────────────────────────────┘
```

The UI asks for the smallest missing input instead of manufacturing certainty.

### 7.7 Eight-session stress state

```text
ATTENTION DELIVERY · delivered: 1 critical → wins NOW
                     queued: 2 · next due 14:25                  [All 3]
YOU        responding to task-03 until 14:12
SELECTED   Claude task-03 · turn owner YOU
OTHERS     3 observed working · 1 status unknown · 1 completion · 2 ready

FLEET
┌ AGENT OWNS TURN ──────┐ ┌ COMPLETION QUEUE ───┐ ┌ READY NEXT ───────────┐
│ Saha B · running      │ │ task-07 · review 35m │ │ task-22 · plan 45m    │
│ Claude A · ~8–18m     │ │ +0              All 1│ │ +1 admitted      All 2│
│ +1 observed      All 3│ └──────────────────────┘ └────────────────────────┘
└───────────────────────┘

SOURCE STATUS / UNCERTAIN
task-31 · STATUS UNKNOWN · last seen 13:42 · excluded from working/ETA counts
```

The default view never expands all eight lanes or cards at once.

### 7.8 Overload and conflict

```text
NOW
┌ Resolve schedule conflict ─────────────────────────────────────────────────┐
│ Two accepted review commitments need the same 45-minute window.            │
│ No new background launch can be admitted until this is resolved.           │
│ [Move task-07] [Shorten if safe] [Cancel one…] [Inspect conflict]           │
│ Effect: opens scoped preview; no accepted commitment changes until confirm  │
└─────────────────────────────────────────────────────────────────────────────┘

ATTENTION DELIVERY
delivered: permission request · visible, deferred by accepted-conflict priority
queued:    Claude A response · review at next boundary 14:25

COMPLETION QUEUE  REVIEW DEBT AT CAP · 90m / 90m
```

Accepted intent is not silently discarded. The user chooses a scoped
move/shorten/cancel/override resolution. If recomputation promotes the
permission request above the conflict, Now changes to Respond and the conflict
is shown as queued context instead; both never claim Now simultaneously.

### 7.9 Empty and source-health variants

```text
EMPTY / CURRENT
No active sessions · sources current at 14:07
[Open admitted next action] [All sessions]

LOADING
Reading session and calendar sources… · no recommendation yet

SOURCE UNAVAILABLE
Session watcher unavailable since 13:42
Active-session count and return estimates hidden
[Reconnect] [Open source details] [Stay passive]

PERMISSION DENIED
Calendar permission denied
Deep-work fit unavailable
[Open system settings] [Set free-until…]

UNCERTAIN SESSION
STATUS UNKNOWN · task-31 · last seen 13:42
Not counted as working · no return estimate
[Inspect terminal] [Archive stale card]
```

Zero active sessions is shown only when the source is current. Loading,
permission denial, unavailable sources, and stale last observations are
different states with different recovery controls.

## 8. Secondary surfaces

### 8.1 All sessions

Retain the current state-column × flow-swimlane board for browsing and
diagnostics. It is reached from Fleet via `All sessions`.

### 8.2 Task detail

```text
Task title / priority / flow
Current state and attention owner
Saha pipeline or interactive turn history
Conditional commitment bundle
Review/integration obligations
Provider routes and exclusions
Recommendation history / why-not query
Terminal affordance
```

### 8.3 Capacity inspector

Show separate provider constraints and reservations. It answers “why can I not
route this task?” It is not the home-screen headline.

## 9. Interaction model

- Selecting a Fleet card highlights its agent lane on the runway.
- Selecting a runway segment highlights the matching Fleet card.
- `Why` expands the current decision trace without leaving home.
- `Choose another` shows at most two feasible alternatives first; search remains
  available.
- `Why not task…` accepts a task selection and shows its first rejected gate.
- Pin/defer/provider exclusion controls live in task detail, not on every card.
- Batch launch acceptance is per-task commitment bundle, never arbitrary child
  nodes.
- A returned response enters attention delivery as eligible/queued/delivered;
  only delivered evidence enters primary-action recomputation.

## 10. Information hierarchy and density

### Always visible

- Now action, duration, reason, stop/expiry;
- next calendar boundary;
- protected human slice and selected-agent turn owner;
- delivered/queued attention counts and next queue boundary;
- immediate agent return range;
- conditional/manual status of a proposed launch.

### One disclosure away

- alternatives and counterfactuals;
- provider/quota constraint;
- confidence dimensions and missing evidence;
- full day runway;
- full session board;
- complete commitment bundle.

### Never use as the primary signal

- composite recommendation score;
- token totals;
- number of running agents;
- provider utilization;
- “productivity” percentage;
- red alarm treatment for low-confidence inferred attention.

## 11. Keyboard and ambient behavior

```text
Space     acknowledge the human slice
W         open Why
A         choose alternative
N         jump to next delivered/queued attention item
R         open runway range
B         open All sessions board
Esc       close disclosure; never intercepted inside terminal
```

All single-key shortcuts are disabled whenever focus is inside a text input,
editor, or terminal. Those surfaces retain every keystroke.

Default notifications:

- board/runway updates: passive;
- response ready during focus: queued to boundary;
- fresh critical request: eligible, but delivered only when proactive mode,
  quiet hours, mute, snooze, and notification cap permit;
- meeting/recovery boundary: one bundled boundary notification;
- stale entity metadata: passive; decisive-source expiry withdraws Now;
- severity escalation breaks a snooze only when the higher class is enabled;
- delivery bundles current requests and drops invalidated generations.

## 12. Desktop and accessibility contract

- Reference viewport: `1440 × 900`; minimum supported: `1100 × 700`.
- Above the fold at minimum: complete Now card, attention-delivery strip,
  global operator line, selected agent lane, and Fleet zone counts.
- Now and attention delivery remain sticky while Fleet scrolls vertically.
- The detailed runway scrolls horizontally inside its own region; Fleet never
  moves sideways with it.
- Expanded Why and bundle inspection are modal sheets/drawers that preserve the
  underlying Now/runway state and return keyboard focus to the invoking control.
- Card titles truncate to one line with full text in accessibility name and
  hover/focus disclosure; state, boundary, and action never truncate.
- Keyboard focus order: Now action → Now controls → attention delivery →
  selected runway lane → Fleet zone headers/cards → secondary navigation.
- All line styles and semantic colors have text tokens (`LIVE`, `PROPOSED`,
  `QUEUED`, `UNKNOWN`) and screen-reader equivalents.
- Return ranges announce “estimated between X and Y,” never a single time.
- Motion is optional; reduced-motion mode uses immediate state replacement and
  preserves focus.

## 13. Designer handoff

Required deliverables:

| Surface | Required state/fixture | Required transition | Clickable |
|---|---|---|---|
| Home | protected focus + one selected live Claude turn | proposed → ACK → LIVE | yes |
| Home | meeting-soon break | acknowledge break / already rested | yes |
| Home | long Claude wait + focus-capable new-task gap | acknowledge secondary slice → early return queued | yes |
| Attention | two concurrent returns + one pre-boundary resolution | dedupe → boundary bundle → open first | yes |
| Attention | critical request muted by passive/quiet/cap | escalation remains queued until delivery allowed | yes |
| Home | conditional Saha overnight preparation | plan → verify → invalidation releases tail | yes |
| Bundle sheet | manual launch with completion reservations | copy → awaiting observed launch | yes |
| Why sheet | two counterfactual alternatives | choose alternative → return home | yes |
| Home | decisive calendar evidence expires | withdraw advice → manual free-until | yes |
| Home | accepted conflict + review debt cap | preview resolution → confirm | yes |
| Home/Fleet | eight sessions and zone overflow | lane ↔ card highlight → All N | yes |
| Source status | empty/current, loading, unavailable, denied, stale | recover/reconnect/manual fallback; paired loading frames | yes where a recovery control exists |
| Failed result | decision required after observed failure | inspect/reconcile → repair/discard/defer | yes |
| Home | no feasible candidate / quota-blocked route | provide input / inspect route | yes |
| All sessions | state-column × flow board | card → task detail | yes |
| Task detail | turn-owner history and uncertain session | task ↔ terminal / why-not | yes |

Every time segment uses `LIVE`, `PROPOSED`, `ACK`, `FIRM CALENDAR`,
`TENTATIVE`, or `OPTION`. Three-hour runways are time-proportional with labeled
ticks.

The prototype succeeds when a user can answer, within five seconds:

- what should I do now;
- for how long;
- why;
- what will need me next;
- whether anything will happen automatically.

## 14. Component/state contract

| Component/state | Source | Presentation | Placement | Allowed control | Transition |
|---|---|---|---|---|---|
| Interrupt-eligible request | fresh explicit/user-marked evidence; SLA at risk | `ELIGIBLE`, SLA state | attention strip | none until delivered | delivery decision / resolution |
| Interrupt delivered | eligible + proactive mode + not quiet/muted/capped | `DELIVERED` | enters Now recomputation | Open session | resolved, deferred, invalidated |
| Queued request | fresh but SLA-safe or protected focus | `QUEUED UNTIL <boundary>` | attention strip | Open now / at boundary | boundary, SLA escalation, resolved |
| Inferred waiting | estimated detector | muted `estimated` | queued only; never interrupt | Inspect | explicit evidence or expiry |
| Agent turn, no new-task gap | observed run + uncertain return | owner AGENT, gap NONE | Agent Owns Turn | Inspect | gap admitted / response |
| Agent turn, safe new-task gap | observed run + admitted window | `BRIEF 8m` / `FOCUS 30m` | Agent Owns Turn | Acknowledge secondary slice | response / boundary |
| Response ready during focus | fresh event | connector to named boundary | queued strip | Open now / boundary | reviewed |
| Proposed Now | policy output, unaccepted | `PROPOSED` outline + expiry | Now/runway | Acknowledge / reject | accepted or expired |
| Acknowledged Now | explicit acceptance | `ACK` human reservation | Now/runway | Stop / complete | observed or cancelled |
| Observed human slice | activity/confirmation | solid in-progress block | Now/runway | Complete | checkpoint/outcome |
| Conditional Saha run | plan-derived, not launched | dashed option, NOT SCHEDULED | Ready Next | Open plan / copy only after gates | observed run or invalidated |
| Observed autonomous run | live evidence | solid run bar | Agent Owns Turn | Inspect | output / failed / stalled |
| Completion obligation | observed output + reservation | bounded debt duration | Completion Queue | Review / integrate / verify | disposition |
| Failed result | observed failure | reason + repair requirement | interrupt or queued if decision needed | Inspect / reconcile | repair, discard, defer |
| Unschedulable conflict | accepted commitments exceed capacity | binding window + conflict set | high-priority Now candidate; blocks new launches | Move / shorten / cancel / scoped override | feasible plan restored |
| Review debt at cap | completion upper load reaches cap | `DEBT AT CAP` with minutes | Completion header | Open completion queue | debt reduced |
| Entity metadata stale | expired non-decisive evidence | dashed, last seen, `?` | lowest within applicable zone | Inspect | refreshed or archived |
| Decisive source stale | recommendation input exceeds validity | withdraw Now + source expiry | Now/runway | refresh / manual input / safe fallback | recompute |
| Empty/current | current sources + zero sessions | `No active sessions` + source time | Source Status | open admitted next | first session |
| Loading | initial reads unresolved | loading, no count/recommendation | Source Status | none | loaded/error |
| Source unavailable | failed watcher/source | unavailable since time; hide count/ETA | Source Status | reconnect/details | recovered |
| Permission denied | explicit source denial | named missing capability | Source Status | settings/manual fallback | permission/manual assertion |
| Uncertain session | last observation stale | `STATUS UNKNOWN`, last seen | Uncertain subsection | inspect/archive | refreshed/archived |
| No feasible candidate | rejected gates | missing-input card | Now | supply smallest input | recompute |
| Quota-blocked route | measured/unknown constraint | route unavailable + why | task/capacity detail | choose route / wait | source change |

Prototype fixtures must cover:

- 0, 1, and 8 active sessions;
- two responses returning concurrently;
- stale and unknown evidence;
- no feasible recommendation;
- failed output requiring a decision;
- conditional plan invalidated after verification;
- quota-blocked routing;
- one interrupting plus one queued request;
- passive/quiet/muted/capped eligible interrupt;
- pre-boundary request resolution and severity escalation;
- unschedulable accepted commitments;
- review debt at cap;
- zone overflow with `All N`.

## 15. Explicit non-goals for the designer

- Do not design a chat assistant persona.
- Do not design automatic scheduling or agent-launch controls.
- Do not turn the runway into a full calendar editor.
- Do not expose optimizer internals by default.
- Do not use all provider gauges as the dominant header.
- Do not imply a precise return time from an estimated range.
- Do not treat “Claude working” as “user busy.”
