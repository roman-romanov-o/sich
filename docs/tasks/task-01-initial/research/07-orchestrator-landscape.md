# Research: Multi-Agent Orchestrator OSS Landscape (Mission-Control Category, April 2026)

**Date:** 2026-04-27
**Status:** Complete
**Researcher:** Sahaidachny Research Agent

## Summary

The "manage many parallel agentic-coding sessions" category exploded between mid-2025 and mid-2026 — at least 30 named projects exist, sorted into web orchestrators, native macOS apps, TUIs, and protocol/router proxies. **None of the well-known projects combines: parallel-session view + per-session state visibility + multi-provider quota awareness + terminal-emulator integration.** The two closest products are **cmux** (libghostty-based native macOS app — has socket API, state visibility, terminal integration; no quota tracking) and **Conductor** (Mac app with parallel agents in worktrees — has parallel view, partial state visibility; no quota tracking, no Ghostty integration). **Vibe Kanban**, the project repeatedly cited as the OSS leader, is *sunsetting* (announced early 2026; project continues as community-maintained OSS) and was always a worktree-and-kanban-first product, not a session-watcher. The user's "watch existing Ghostty sessions + show state + show quota" combination is genuinely uncovered.

## Methodology Note

This survey is built from public READMEs, project sites, and the [awesome-agent-orchestrators list](https://github.com/andyrewlee/awesome-agent-orchestrators) (which catalogs 30+ projects in this niche as of April 2026). Star counts and minor feature claims are not reproduced unless a primary source confirmed them. **Several of the projects in the awesome list are too new or too niche to verify in this pass; flagged inline.**

## The Two Architectural Shapes

The category has split into two clear shapes:

### Shape A: "Spawner" orchestrators
The orchestrator **spawns and owns** the agent processes. It controls the worktree, the branch, often the terminal session, and frequently the lifecycle. Examples: Vibe Kanban, Conductor, Crystal/Nimbalyst, Claude Squad, container-use, sketch.dev, mux (Coder), constellagent.

These tools tend to have rich UIs (web, native, or TUI) and want to be the user's primary interface. They typically replace or wrap the terminal, not coexist with it.

### Shape B: "Watcher" / coordination layers
The orchestrator **observes** existing agent sessions running elsewhere and provides cross-cutting views or coordination. Examples: hcom, swarm-protocol (MCP-based), gnap (git-native protocol), agent-deck (TUI session manager), recon (tmux dashboard).

These tools tend to be smaller, more protocol-shaped, and coexist with whatever shell or IDE you're already using.

**The user's "mission control alongside Ghostty" vision is fundamentally Shape B**, and Shape B is the smaller and less-developed half of the ecosystem.

## Detailed Profiles

### Vibe Kanban

- **URL:** [vibekanban.com](https://vibekanban.com/), [github.com/BloopAI/vibe-kanban](https://github.com/BloopAI/vibe-kanban)
- **Status:** **Sunsetting.** Repository announces the project will continue as community-maintained OSS but BloopAI is no longer driving it.
- **What it is:** Web app (local) launched via `npx vibe-kanban`. Rust + TypeScript stack. Kanban issues -> spawn agent in isolated git worktree -> agent gets branch + terminal + dev server -> diff review + PR creation.
- **Spawner.** Watches its own spawned sessions, not your existing terminal.
- Supports 10+ agents: Claude Code, Codex, Gemini CLI, Copilot, Amp, Cursor, OpenCode, Droid, CCR, Qwen.
- **MCP integration both directions:** consumes MCP servers and exposes itself as one (other agents can manipulate the board via MCP).
- **Terminal integration:** none documented. Each workspace gets its own browser-embedded terminal.
- **Quota awareness:** none.
- **State visibility:** per-task UI; observed via the agents it spawns.
- **Sources:** [GitHub README](https://github.com/BloopAI/vibe-kanban), [VirtusLab review](https://virtuslab.com/blog/ai/vibe-kanban), [BrightCoding review](https://www.blog.brightcoding.dev/2026/04/19/vibe-kanban-10x-your-ai-coding-agent-output).

### Conductor

- **URL:** [conductor.build](https://www.conductor.build/), [docs.conductor.build](https://docs.conductor.build/)
- **What it is:** Native Mac app for orchestrating teams of coding agents (Claude Code + Codex). Each agent gets isolated git worktree. Dashboard shows all agents and their progress; review and merge changes from one UI.
- **Spawner.**
- Reuses your existing Claude Code/Codex auth (Pro/Max plan or API key).
- **State visibility:** dashboard shows what each agent is working on; depth not fully documented.
- **Terminal integration:** does not coexist with Ghostty; the agent runs inside Conductor's UI.
- **Quota awareness:** none documented.
- **Closed-source** (commercial Mac app).
- **Sources:** [Conductor docs](https://docs.conductor.build/), [Conductor changelog](https://www.conductor.build/changelog), [The New Stack review](https://thenewstack.io/a-hands-on-review-of-conductor-an-ai-parallel-runner-app/).

### Crystal / Nimbalyst (formerly Crystal)

- **URL:** [github.com/stravu/crystal](https://github.com/stravu/crystal); successor: [nimbalyst.com](https://nimbalyst.com/blog/crystal-supercharge-your-development-with-multi-session-claude-code-management)
- **Status:** Crystal is **deprecated as of February 2026**, replaced by Nimbalyst (still under stravu's umbrella). Crystal still works but no active updates.
- **What it is:** Electron desktop app. Run multiple Claude Code + Codex sessions in parallel git worktrees. MIT-licensed.
- **Spawner.**
- **Terminal integration:** sessions run inside the Electron UI, not in your existing Ghostty.
- **Quota awareness:** none.
- **Sources:** [github.com/stravu/crystal](https://github.com/stravu/crystal), [Nimbalyst migration page](https://nimbalyst.com/blog/crystal-supercharge-your-development-with-multi-session-claude-code-management).

### Claude Squad

- **URL:** [github.com/smtg-ai/claude-squad](https://github.com/smtg-ai/claude-squad), [smtg-ai.github.io/claude-squad](https://smtg-ai.github.io/claude-squad/)
- **What it is:** Go-based **TUI** (89% Go in repo). Manages multiple Claude Code, Codex, Gemini CLI, OpenCode, Aider sessions. Uses **tmux** for isolation, git worktrees for codebase separation.
- **Spawner.**
- Profiles for switching configurations.
- Background tasks + auto-accept mode.
- **Terminal integration:** runs as a TUI inside one terminal; replaces the multiplexer role. Not designed to integrate with Ghostty externally.
- **No API**, no quota tracking.
- **Sources:** [GitHub README](https://github.com/smtg-ai/claude-squad).

### cmux (manaflow-ai)

- **URL:** [cmux.com](https://cmux.com/), [github.com/manaflow-ai/cmux](https://github.com/manaflow-ai/cmux)
- **License:** GPL-3.0-or-later (commercial license available).
- **What it is:** **Native macOS app built on libghostty.** Same renderer as Ghostty, different shell. Vertical + horizontal tabs with sidebar metadata: git branch, PR status, working directory, listening ports. Notification rings light up when an agent needs attention.
- **Both shapes:** spawns workspaces *and* exposes a socket API for external automation.
- **Reads existing Ghostty config** (themes, fonts, colors).
- **Socket API + CLI + scriptable hooks** specifically designed for Claude Code integration.
- Supports Claude Code teammate mode, Codex sessions.
- **Strategically:** this is the closest existing product to the user's vision, with the caveat that it's a Ghostty *alternative* (same engine, different app), not a sibling that focuses Ghostty.app tabs.
- **Quota awareness:** none documented.
- **Sources:** [cmux.com](https://cmux.com/), [github.com/manaflow-ai/cmux](https://github.com/manaflow-ai/cmux).

### sketch.dev

- **URL:** [sketch.dev](https://sketch.dev/), [github.com/boldsoftware/sketch](https://github.com/boldsoftware/sketch)
- **What it is:** "Autonomous software apprentice." Agentic coding tool that runs in terminal + has a web UI. Spawns Docker containers per session; output lands on a branch in your host repo.
- **Spawner with sandboxing.** Designed for parallel sessions because each is containerized.
- **Terminal integration:** runs in *its own* terminal/web UI, not in your existing Ghostty.
- **Quota awareness:** none documented.
- **State visibility:** per-session via web UI.

### opencode

- **URL:** [opencode.ai](https://opencode.ai/docs/tui/), [github.com/opencode-ai/opencode](https://github.com/opencode-ai/opencode), also fork at [github.com/anomalyco/opencode](https://github.com/anomalyco/opencode)
- **What it is:** Open-source TUI coding agent. Multi-provider (Anthropic, OpenAI, Google, Bedrock, Groq, Azure, OpenRouter, etc.). Two built-in modes (build / plan), client/server architecture (TUI is one of multiple possible clients — including a remote mobile client).
- **This is itself a coding agent**, not an orchestrator of other agents. Closer to a competitor of Claude Code than to Vibe Kanban.
- Notable that opencode "supports modern terminal emulators like Ghostty" — but as a *terminal app it runs inside*, not as a Ghostty sibling.
- **Quota awareness:** none for cross-subscription view.

### container-use (Dagger)

- **URL:** [github.com/dagger/container-use](https://github.com/dagger/container-use)
- **What it is:** MCP server. Each agent gets an isolated Docker container + git worktree. Agents request environments via MCP; works with Claude Code, Cursor, any MCP-compatible agent.
- **Spawner-of-environments**, not a UI orchestrator.
- Provides "real-time visibility" via command history logs and "drop into any agent's terminal" intervention.
- **Terminal integration:** the dropped-into terminal is whatever the user shells into; doesn't integrate with Ghostty specifically.
- **Quota awareness:** none. Outside its remit.
- **Sources:** [GitHub README](https://github.com/dagger/container-use/blob/main/README.md), [Dagger blog](https://dagger.io/blog/agent-container-use/), [InfoQ writeup](https://www.infoq.com/news/2025/08/container-use/).

### claude-code-router (musistudio)

- **URL:** [github.com/musistudio/claude-code-router](https://github.com/musistudio/claude-code-router)
- **What it is:** Local proxy on `127.0.0.1:3456`. Intercepts Claude Code requests and routes them to any model provider (OpenRouter, DeepSeek, Gemini, Volcengine, SiliconFlow, Ollama, etc.). Supports request/response transformation.
- **Not an orchestrator.** It's a model routing proxy. Relevant to the user's idea **only as a quota-shifting mechanism** — "you're out of Claude quota; cc-router can transparently swap to a cheaper provider." Could plausibly be a backend the dashboard talks to, but it doesn't expose quota state itself.
- **Sources:** [GitHub README](https://github.com/musistudio/claude-code-router), [TokenMix configuration guide](https://tokenmix.ai/blog/claude-code-router-guide-2026).

### The Tail of the Awesome List (less-investigated)

The [awesome-agent-orchestrators list](https://github.com/andyrewlee/awesome-agent-orchestrators) catalogs 30+ projects. Beyond the deeply-investigated ones above, notable mentions in the "parallel agent runner" bucket:

| Project | Type | One-liner | Verified depth |
|---|---|---|---|
| agent-deck | TUI | Terminal session manager for Claude/Gemini/OpenCode/Codex | Surface-level only |
| agent-kanban | Web | Agent-first kanban with leader-worker model | Surface-level only |
| agent-of-empires | TUI | Terminal session manager (Linux/macOS) | Surface-level only |
| amux | TUI | Parallel coding agents | Surface-level only |
| Aperant | Native | Autonomous multi-session AI coding | Surface-level only |
| ariana | Native | "IDE of the future" | Surface-level only |
| automaker | Native | Autonomous AI dev studio | Surface-level only |
| bernstein | CLI | Deterministic orchestrator (Claude/Codex/Gemini) with test verification | Surface-level only |
| CodexMonitor | Native | Codex-specific multi-workspace orchestrator | Surface-level only |
| constellagent | Native | macOS app with isolated terminals + editors + worktrees | Surface-level only |
| dmux | TUI | Parallel agents with tmux + worktrees | Surface-level only |
| dorothy | Native | Desktop app with kanban + automations + MCP | Surface-level only |
| emdash | Web | Multiple coding agents in parallel | Surface-level only |
| ghast | TUI | "Multitask with multiple terminals" | Surface-level only |
| jean | Native+Web | Orchestrate Claude/Codex/OpenCode | Surface-level only |
| mux (Coder) | Native | Desktop app for isolated parallel agentic dev | Surface-level only |
| openkanban | TUI | TUI kanban for orchestrating agents | Surface-level only |
| parallel-code | Native | Desktop app for parallel agents in worktrees | Surface-level only |
| sortie | CLI | Issue-tracker tickets -> autonomous agent sessions; single Go binary, SQLite | Surface-level only |
| supacode | Native | macOS native orchestrator | Surface-level only |
| superset | TUI | "Terminal built for coding agents" | Surface-level only |
| symphony | CLI (OpenAI) | Project work -> isolated implementation runs | Surface-level only |
| t3code | Web | Minimal web GUI for coding agents | Surface-level only |
| tutti | CLI | Multi-agent CLI with config-driven workflows | Surface-level only |
| vibe-tree | CLI | Vibe code with Claude in parallel git worktrees | Surface-level only |
| vibecraft | Native | "RTS-style" workspace for AI agents | Surface-level only |
| recon | TUI (tmux) | tmux-native dashboard for Claude Code agents | Surface-level only |
| codeman | Web | xterm.js + tmux + per-session token/cost tracking | Surface-level only |
| Codeburn | TUI | Token observability dashboard for Claude/Codex/Cursor | Surface-level only — relevant to quota half |

**Caveat:** none of these were inspected line-by-line. Star counts not reproduced. Treat as a catalog to triage further if a serious build-vs-buy decision is needed.

### Quota-tracking-adjacent projects worth flagging

- **codeman** ([github.com/Ark0N/Codeman](https://github.com/Ark0N/Codeman)) — Web UI managing Claude Code + OpenCode in tmux sessions; **per-session token + cost tracking**. Closest existing project to "session view + token cost" but tmux-only and OpenCode-only on the agent side, no Ghostty integration, no multi-provider quota aggregation.
- **Codeburn** ([github.com/getagentseal/codeburn](https://github.com/getagentseal/codeburn)) — TUI dashboard explicitly for "Claude Code, Codex, and Cursor cost observability." Closest to the quota half of the user's vision; not inspected for state-detection or session-orchestration coverage.

These two are the projects most likely to leapfrog the user's quota half if they expand scope.

## Comparison Matrix

Coverage of the user's four feature pillars. Legend: Yes / Partial / No / Unknown.

| Project | Parallel session view | Per-session state visibility | Multi-provider quota awareness | Terminal-emulator integration (coexists with Ghostty) |
|---|---|---|---|---|
| Vibe Kanban (sunsetting) | Yes (kanban) | Partial (per-task UI) | No | No |
| Conductor (closed Mac) | Yes (dashboard) | Partial | No | No |
| Crystal/Nimbalyst | Yes (Electron) | Partial | No | No |
| Claude Squad | Yes (TUI) | Partial | No | Replaces (tmux-based) |
| cmux | Yes (sidebar) | Yes (sidebar metadata + notification rings) | No | **Replaces Ghostty.app with libghostty-based app** |
| sketch.dev | Yes (web UI) | Partial | No | No (own terminal/web UI) |
| opencode | N/A (single agent) | N/A | No | Runs *inside* Ghostty as a TUI |
| container-use | Yes (MCP) | Partial (logs) | No | No |
| claude-code-router | N/A | N/A | No (routes; doesn't track) | N/A |
| codeman | Yes (web/tmux) | Partial | **Partial (per-session token cost)** | No (replaces with tmux) |
| Codeburn | N/A | Partial | **Partial (cost observability)** | No |
| sortie | Yes (sessions from issues) | Partial | No | No |
| recon | Yes (tmux dashboard) | Partial | No | tmux-based |
| **What user wants** | Yes | Yes (rich) | Yes (multi-provider) | **Yes (sibling to Ghostty.app)** |

**No row matches all four columns.** The cmux row is the closest if you accept "use libghostty-based cmux instead of Ghostty.app" as still satisfying the "Ghostty" requirement (same renderer, same config). The Codeburn + Codeman rows are the closest on the quota axis but have nothing in the terminal-coexistence column.

## Verdict on Q3: closest existing tool

**No single tool covers all four pillars.** The build/extend/wrap decision becomes:

- **Closest to "watch existing Ghostty sessions + state":** cmux — but it requires switching from Ghostty.app to cmux.app.
- **Closest to "kanban + multi-agent spawn":** Vibe Kanban (sunsetting) or Conductor (closed-source Mac).
- **Closest to "multi-provider quota awareness":** Codeburn — but only on the cost-observability axis; not multi-provider subscription quota.
- **Closest to "backlog -> spawn agent on capacity":** essentially nothing public covers this.

### Build vs. extend vs. wrap

A more honest framing than "build new" vs. "extend":

- **Extend Vibe Kanban** with quota awareness and Ghostty AppleScript integration.
  - Pro: most popular OSS in the niche; large feature surface to build on.
  - Con: it's *sunsetting* and has been largely abandoned by the original maintainers. Community fork. The Vibe Kanban model is "spawn agent in worktree", which doesn't match the user's "watch existing Ghostty sessions" model. Significant impedance mismatch.
- **Extend cmux** with quota awareness.
  - Pro: cmux already has the socket API, libghostty rendering, sidebar metadata, scriptable hooks, Claude Code integration.
  - Con: GPL-3.0 (acceptable, but contagious). Closest to the user's vision *but* requires switching off Ghostty.app to cmux.app. The user explicitly said "do NOT replace Ghostty" — this might or might not count as "replacement" depending on user intent.
- **Wrap existing tools as data sources behind a thin custom dashboard.**
  - Use Claude Code HTTP hooks, Codex JSON-RPC, Gemini CLI hook wrappers, AppleScript for Ghostty, ccusage / Codeburn-style libraries for token costs. Build the smallest possible orchestrator that ties these together.
  - Pro: matches the user's "watch + dashboard alongside Ghostty" model exactly. Minimal lock-in. Can incrementally absorb features from any project as needed.
  - Con: it is genuinely a new thing; the user has to build it. Maintenance treadmill across 3 agent CLIs and 2–3 quota sources.

Detailed steel-manning is in `08-revised-viability.md`.

## Validated Assumptions

| Assumption | Status | Evidence |
|---|---|---|
| Vibe Kanban is the OSS leader in this niche | Partial → Obsolete | Was; sunsetting per repo announcement |
| No existing tool covers state + quota + Ghostty + parallel view | Confirmed | Comparison matrix above shows no row matching all four |
| The category is ~3-5 tools | Incorrect | 30+ named projects per awesome-agent-orchestrators (April 2026) |
| Closest tool is Vibe Kanban | Incorrect | cmux is the closest to the user's vision; Codeburn is closest on the quota axis |
| Most tools coexist with terminal emulators | Incorrect | The dominant pattern is to spawn the agent inside the orchestrator's own UI/web/TUI, not to integrate with the user's existing terminal |

## Risks Identified

### 1. Category is moving fast (Severity: Medium)
30+ projects in 18 months, several already deprecated/sunsetting. Whatever the user builds will be in a churning landscape; differentiation must be defensible (multi-provider quota + Ghostty AppleScript is a plausible defensible combo).

### 2. Anthropic / OpenAI / Google could ship native parallel-session UIs (Severity: Medium)
Codex's app-server already supports multi-surface session sync. Anthropic could ship a "Claude Code Manager" any quarter. The differentiator must include **non-provider** features (cross-provider quota, Ghostty integration, backlog-aware capacity) that no single provider would ship.

### 3. Many of the "30 projects" are abandoned (Severity: Low)
Whitelisting based on awesome lists overestimates the active competition. A serious build-vs-buy survey would inspect commit recency and maintainer activity for each — out of scope for this pass.

### 4. cmux trajectory matters (Severity: Medium)
If cmux continues to grow and adds quota tracking, the user's project gets squeezed. If cmux stalls, the user has more space. Watch [cmux GitHub activity](https://github.com/manaflow-ai/cmux) over the next 3 months.

### 5. The "extend an existing project" path is rocky (Severity: Medium)
Vibe Kanban: maintainer-abandoned. Conductor: closed-source. Crystal: deprecated. Most named projects either don't accept large external contributions or are too narrow to host the user's vision well. This is a real argument for "build new" over "extend".

## Open Questions

- [ ] Does cmux's socket API expose enough for an external dashboard to hook into without forking cmux? (Read the API docs.)
- [ ] Are there any **MCP-protocol-based** orchestrators that already define a standard "session state" schema across agents? (swarm-protocol, container-use, hcom — worth a follow-up dive.)
- [ ] What's the actual user adoption of the 30 projects? GitHub star counts and last-commit dates would triage the "real" competition from the "weekend project" tail. Out of scope this pass.
- [ ] Would the user accept cmux as "Ghostty enough" given libghostty rendering and config compatibility? (User-product question, not research.)

## Recommendations

1. **Don't extend Vibe Kanban.** It's sunsetting, model mismatch (spawner vs. watcher), and the codebase is large.
2. **Take cmux seriously as a "buy not build" option** for the parallel-session-view + state-visibility halves. Even if the user keeps Ghostty.app, cmux's existence sets a high bar — the dashboard must offer something cmux doesn't.
3. **Build new for the quota + capacity-planning + Ghostty-AppleScript combination.** No existing project covers it; it's a small, focused, defensible scope.
4. **Treat Codeburn and Codeman as collaborators or libraries, not competitors.** They cover sub-pieces of the quota half.
5. **Architect as Shape B (watcher) not Shape A (spawner).** The user's vision is "alongside Ghostty", not "instead of Ghostty". Shape B is the smaller, less-developed half of the ecosystem — that's good (less competition) but means fewer reusable building blocks (so be honest about scope).

## References

- [awesome-agent-orchestrators (catalog)](https://github.com/andyrewlee/awesome-agent-orchestrators)
- [Choosing an AI Agent Orchestrator in 2026 (DEV Community)](https://dev.to/battyterm/choosing-an-ai-agent-orchestrator-in-2026-a-practical-comparison-i0k)
- [From Conductor to Orchestrator (htdocs.dev)](https://htdocs.dev/posts/from-conductor-to-orchestrator-a-practical-guide-to-multi-agent-coding-in-2026/)
- [Conductors to Orchestrators (O'Reilly)](https://www.oreilly.com/radar/conductors-to-orchestrators-the-future-of-agentic-coding/)
- [Vibe Kanban site](https://vibekanban.com/) and [GitHub](https://github.com/BloopAI/vibe-kanban)
- [Conductor docs](https://docs.conductor.build/)
- [Crystal -> Nimbalyst announcement](https://nimbalyst.com/blog/crystal-supercharge-your-development-with-multi-session-claude-code-management)
- [Claude Squad](https://github.com/smtg-ai/claude-squad)
- [cmux](https://cmux.com/), [github.com/manaflow-ai/cmux](https://github.com/manaflow-ai/cmux)
- [sketch.dev](https://sketch.dev/), [github.com/boldsoftware/sketch](https://github.com/boldsoftware/sketch)
- [opencode.ai](https://opencode.ai/docs/tui/)
- [container-use](https://github.com/dagger/container-use), [Dagger blog](https://dagger.io/blog/agent-container-use/)
- [claude-code-router](https://github.com/musistudio/claude-code-router)
- [codeman](https://github.com/Ark0N/Codeman)
- [Codeburn](https://github.com/getagentseal/codeburn)
- [recon (tmux dashboard)](https://github.com/gavraz/recon)
