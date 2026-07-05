# Agentic Coding Mission Control — Product Requirements

> Derived from the project's own decision record (design decisions, task-01 spec, and delivery state). This is a synthesis of choices already made, not a new proposal.

## What we're building

A single-window macOS app that is **its own terminal emulator** (embeds libghostty, per DD-001), giving one board-level view of every parallel agentic-coding session the developer runs, plus a quota-aware "capacity brain" that suggests what to start next and on which billing pool.

**One line:** a kanban cockpit for someone running 6–8 Claude Code / Codex / Gemini sessions at once, that knows how much of each subscription pool is left and routes new work to the pool with headroom.

## The need we're covering

The core pain is **losing situational awareness across parallel sessions** — not cost. A developer running 6–7 agentic sessions in terminal tabs can't see at a glance which are *running*, *waiting on me*, *blocked*, or *idle*, so balls get dropped and expensive human attention is wasted context-switching.

The ROI is **throughput** — running 8 projects without dropping balls instead of 5 — measured in the developer's own output, not subscription dollars saved. (Research killed the cost-savings angle: only $15–40/mo is recoverable, not worth building for.)

The secondary, differentiating need: **subscription quota is now split into non-fungible pools** (interactive 5h-rolling + weekly window vs. the separate capped `claude -p` / Agent-SDK credit pool, since 2026-06-15). Existing multi-agent orchestrators are quota-blind spawners. So the developer has no tool that answers: *"which project should I start next, will it fit the quota I have left, and in which pool?"*

## Core capabilities (the pillars)

1. **Mission-control board** — every active session as a card with live state (idle / running / waiting-for-me / blocked) and a "who needs me now" attention signal. Board altitude is organized by *two flows*: autonomous (saha) vs. interactive.
2. **Drill-in terminal** — click a card to get the real live terminal for that task *inside the app* (we own the PTY). Run `claude` in it directly.
3. **Two-pool / multi-provider quota panel** — four distinct, **never-summed** gauges: the two Anthropic pools (interactive + Agent-SDK credit) plus Codex / Gemini. Reads Claude's real `/api/oauth/usage`.
4. **Backlog → capacity allocator (the differentiator)** — given remaining quota per pool and historical burn, *suggest* which backlog item to start next and which launch command to use (`/saha:execute` → interactive pool when the window has headroom, else `saha run` / Codex / Gemini). Suggest-only, never auto-dispatch.

## Hard constraints (non-negotiable invariants)

- **Watcher, not spawner** — the app itself never invokes `claude -p` / Agent SDK. An in-code pool firewall is mandatory (owning the PTY makes dispatch-creep easy).
- **Never net the two Anthropic pools** — grouped visually but never summed; they don't fungibly trade.
- **Launch is suggest-only** — auto-dispatch = spawner = wrong pool.
- **saha integration = ingest its telemetry**, don't rebuild its loop. A saha task is a first-class card type.
- **Faithful evidence for visual ACs** — pixel-level claims get human sign-off, not synthetic screenshots.

## Explicitly out of scope

- Cost-savings / spend tracking as the value prop
- Pay-as-you-go API spend
- Browser chat (ChatGPT / Claude.ai)
- Auto-launching sessions
- ~~Replacing the terminal~~ — this was the *old* constraint; **DD-001 reversed it**. We now *are* the terminal.

## Current delivery state

- **task-01** (all six stories US-001..006) — complete and human-signed-off: embedded terminal, drill-in, board, attention signal, state detection, two-pool quota.
- **task-04** (live detection) — complete.
- The assembled app (`swift run ghostling`) folds board + quota + live terminal into one window and polls live data.
- Roadmap continues with **task-02** (estimation) and **task-03** (native core).

## References

- `docs/tasks/task-01-initial/` — original stories, design decisions (DD-001 embed libghostty), task description
- Decision record: watcher-not-spawner quota constraint · two-flow / two-pool allocator thesis · saha as the depth engine this cockpit sits atop
