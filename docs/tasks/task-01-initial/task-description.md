# Task Description: Initial POC — Agentic Coding Mission Control

**Task ID:** task-01
**Status:** Draft (revised after first research pass)
**Last Updated:** 2026-04-27

## Problem Statement

Agentic coding tools (Claude Code, Codex CLI, Gemini CLI) fundamentally change how a single developer works. Pre-AI, you focused on **one task at a time** (Pomodoro-style: focus → switch → focus). With agents, you can have **6–7 projects running in parallel** — each in its own terminal tab (Ghostty), each with an agent autonomously coding, testing, or waiting on input.

This creates two new problems that no existing tool solves together:

### Problem 1: Loss of situational awareness across parallel sessions

With 6–7 Ghostty tabs open, each running an agent on a different project:
- It's easy to **lose track** of what each session is doing.
- It's easy to **forget a project entirely** — you started it, the agent is waiting, and you've moved on.
- Tab switching is shallow: you see the tab, but not the **state** (running / waiting for input / test loop / done).
- Context-switching cost is high because state recovery takes seconds per project.

### Problem 2: No capacity planning across subscription quotas

The user pays for multiple subscriptions (Claude Code Pro $100/mo, Codex CLI, Gemini CLI, etc.). Each has a quota. Today:
- The user has no view of **how much capacity remains across all subscriptions** for the current cycle.
- The user can't **predict** how many more projects can be tackled this cycle ("based on my burn rate, I have budget for ~4 more projects").
- A backlog of projects sits separately from the live capacity signal — there's no system that says "you have spare quota; pull project X from the backlog and start it."

## Desired Solution

**One product** that combines:

### A. Mission-control dashboard ~~(does NOT replace Ghostty)~~ *(embeds the terminal — superseded 2026-06-15 by DD-001)*

A view of every active agentic-coding session across all terminals/projects:
- Per-project state: which agent is running, what phase (idle / running / waiting for human / running tests / blocked).
- Click/keystroke to **drill into that session's embedded terminal** (in-app focus). *(Originally "jump straight to that Ghostty tab/window, system-level focus, not relaunch"; superseded by DD-001 — the app now owns the terminal, so US-002 drill-in focuses the in-app `TerminalSurface`, not an external Ghostty tab.)*
- Visible "you have N projects waiting on you" indicator.

### B. Quota tracking + capacity prediction

Aggregate token consumption across all subscriptions (Claude Code, Codex, Gemini CLI, etc.) for the current billing cycle:
- Show remaining quota per provider.
- Estimate **"projects remaining this cycle"** based on historical per-project burn.
- Surface this as input to backlog management.

### C. Backlog-aware project intake

A backlog of projects the user wants to do. The system suggests:
- "You have spare capacity → pick up project X."
- "You're nearly out of Claude quota → push project Y to next cycle, or run it on Codex instead."

## Why this is potentially novel

The first research pass found:
- Token usage trackers exist (saturated niche, but **API-spend focused**, not subscription).
- A few Claude Code subscription trackers exist (`ccusage` etc.) but each tracks **one provider** in isolation.
- Multi-agent orchestrators exist (Vibe Kanban etc.) but are **quota-blind**.
- **Nobody combines parallel-session mission control + multi-provider quota + backlog capacity planning** into one tool.

The original POC framing was "save money on unused quota" — which the research correctly shredded ($15–40/mo savings doesn't justify build cost). The **real** value proposition is different and likely larger:

> **Reduce the cognitive overhead of running 6+ parallel agentic sessions, and make capacity planning explicit instead of implicit.**

That's a productivity/throughput play, not a savings play. If it lets the user manage 8 parallel projects instead of 5 without dropping balls, the ROI is the developer's own throughput — much bigger than $40/mo.

## Research Question (revised — second pass)

Before building, validate the expanded scope:

1. **Mission-control / parallel session tracking layer**
   - Does anything OSS already track multiple parallel Claude Code / Codex / Gemini CLI sessions across terminal tabs?
   - Specifically: Vibe Kanban, claude-squad, claude-code-router, sketch.dev, opencode, anything similar — what do they actually do? Are they web dashboards, TUIs, IDE extensions? Do they run *alongside* Ghostty or *replace* the terminal?
   - Ghostty integration: does Ghostty expose an API / IPC socket / window-focus mechanism that a dashboard could use to "jump to that tab"? (Ghostty has a config-driven approach and recently added some scripting — what's actually possible as of 2026-04?)

2. **Agent session state detection**
   - How can a separate process know what state a Claude Code session is in (idle, awaiting input, running, blocked)? Hooks? JSONL tail? Status line JSON? PID introspection? PTY scraping?
   - Same question for Codex CLI and Gemini CLI.
   - This is the critical feasibility question — the dashboard is useless if state detection is unreliable.

3. **Multi-agent kanban / project orchestrators (revisit)**
   - The first pass mentioned Vibe Kanban as quota-blind. Look deeper: what **does** it do well? Is it the closest existing solution?
   - claude-squad, conductor, crystal, sketch.dev — what's the landscape of "manage many agentic sessions" tools? Web-based vs. native vs. TUI?

4. **Backlog → capacity matchmaker**
   - Anything that pairs a project backlog with available AI capacity and suggests what to start next? (Likely empty space — confirm.)

5. **Build vs. extend decision**
   - Given the expanded scope, is the right move to:
     - (a) Build a new product from scratch.
     - (b) Build a quota layer on top of an existing orchestrator (e.g., contribute to Vibe Kanban).
     - (c) Build a thin Ghostty-integrated dashboard that consumes existing trackers (`ccusage` etc.) as data sources.

## Success Criteria (this POC research stage — revised)

1. [ ] Map of OSS tools in the **mission-control / parallel-session** category (not just quota trackers).
2. [ ] Concrete answer on Ghostty IPC / window-focus integration feasibility.
3. [ ] Concrete answer on per-session state detection feasibility for Claude Code / Codex / Gemini.
4. [ ] Updated gap analysis with the expanded scope.
5. [ ] Build/extend/abandon recommendation that accounts for the **throughput** value prop, not just the savings prop.

## Scope

### In Scope (POC research)

- OSS landscape for parallel agentic-session orchestration.
- Ghostty integration mechanics.
- Agent state-detection mechanics.
- Updated viability assessment.

### Out of Scope (POC research)

- Implementation.
- Mobile / phone integration.
- Team/multi-user features.
- ~~Replacing Ghostty.~~ *(Superseded 2026-06-15 by `design-decisions/DD-001` — the product now embeds `libghostty` and becomes the terminal for managed sessions.)*

## Constraints

| Type | Constraint | Reason |
|------|------------|--------|
| Terminal | **App embeds `libghostty` and becomes the terminal for managed sessions** (cmux model) — see `design-decisions/DD-001`. *(Originally "work alongside Ghostty, not replace it"; reversed 2026-06-15.)* | DD-001: the integrated board + live-terminal UX requires owning the terminal; AppleScript cannot render a live in-app terminal for a native Ghostty tab |
| Providers | Subscription-based agents (Claude Code, Codex, Gemini CLI), not just web chat subscriptions | This is where parallel work happens |
| Architecture | **Watcher, not spawner — pool discipline.** The tool must never invoke `claude -p` / Agent SDK as part of its own operation; sessions run *native interactive* `claude`. *(Still holds under DD-001: even though the app now owns the terminal, it only hosts user-launched interactive sessions → interactive pool. Owning a read/write PTY makes dispatch-creep easier, so an in-code pool firewall is mandatory.)* | As of 2026-06-15, `claude -p` draws from a separate capped Agent SDK credit pool (hard-stops, no fallback) distinct from interactive limits. A spawner burns the wrong pool and makes the quota model incoherent. See `research/10-claude-p-quota-change.md` |
| Quota | Track **both** Anthropic pools — interactive (5h window + weekly cap) and the separate Agent SDK credit | The two-pool split is now load-bearing for the quota pillar; users want to see which tools drain which pool |
| Backlog→capacity | Suggest, never auto-dispatch. Human launches the interactive session | Auto-dispatch via `claude -p` would reintroduce the spawner / wrong-pool problem |
| Effort | POC stage — keep it minimal and decision-oriented | Validate before building |

## Open Questions (carried into research pass 2)

- Does Ghostty have a stable IPC or scripting interface in April 2026?
- Can Claude Code state be inferred reliably from JSONL tail + statusline JSON + hooks?
- Is there a Vibe-Kanban-shaped tool that already does 70% of this and just needs a quota layer?
- Native macOS app vs. web dashboard vs. TUI — what fits the user's workflow (heavy terminal user, Ghostty-centric)?
