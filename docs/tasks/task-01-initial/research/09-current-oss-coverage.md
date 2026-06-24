# Research: Current OSS Coverage — Does This Product Still Need To Exist?

**Date:** 2026-04-27
**Status:** Complete
**Researcher:** Codex

## Summary

As of **2026-04-27**, there is still **no single open-source tool** that covers the full product thesis for this task: parallel active-session mission control, reliable state visibility, **Ghostty-first** session jumping, **multi-provider quota visibility**, and backlog/capacity matching in one workflow.

What changed versus the earlier research is not the conclusion, but the shape of the alternative set. The OSS ecosystem is stronger now: there are **good point solutions** in each slice. `cmux` is the strongest active-session terminal control product, `Agent Sessions` is the strongest session-browser/HUD, `CodexBar` is the strongest quota tracker for a **non-OpenCode** workflow, and `Vibe Kanban` remains the clearest backlog/orchestration precedent. But they do **not** compose into one coherent Ghostty-native product without custom glue.

The practical implication is:

- If the goal is **"avoid building anything"**, the closest current path is a **tool stack**, not one product.
- If the goal is **"one Ghostty-first product"**, then yes, the product still needs to exist — but it should exist as a **thin integration/watcher layer**, not as a brand-new terminal, browser, or orchestrator.

## Research Questions

1. Does any current OSS project already cover all required pillars?
2. If not, which OSS project or stack gets closest?
3. Given the current landscape, should we build, adopt, or narrow the problem?

## Required Pillars

For this task, "covers our needs" means all of the following:

1. **Parallel session mission control** across active coding-agent sessions.
2. **State visibility** (running, waiting, blocked, done, attention-needed).
3. **Works alongside Ghostty** and ideally jumps to the correct Ghostty tab/window.
4. **Multi-provider quota visibility** across at least Claude Code, Codex, and Gemini CLI.
5. **Backlog/capacity matching** or at least a credible path to it.
6. Reasonable OSS health for adoption or extension.

## Key Findings

### 1. No single OSS tool covers all required pillars

The ecosystem now has several serious candidates, but each one stops short in a different place:

- `cmux` is strong on terminal-side mission control, notifications, and scriptability, but it is its **own** Ghostty-based terminal app and has no quota layer.
- `Agent Sessions` is strong on session browsing and active-session HUDs, but its live cockpit is tied to **iTerm2**, not Ghostty, and it is not a backlog/capacity product.
- `CodexBar` is the strongest current cross-provider quota tracker for a workflow built around Claude/Codex/Gemini directly, but it is a **menu-bar quota app**, not session mission control.
- `Vibe Kanban` is strong on backlog/orchestration, but it is sunsetting and still does not solve quota or Ghostty-native session visibility.

### 2. The best current alternatives are split across three categories

#### Category A: Session mission control / terminal awareness

**Best current candidate:** `cmux`

Evidence:

- `cmux` is "Ghostty compatible" and uses `libghostty`, but it is explicitly a **native macOS app** rather than an overlay on top of Ghostty itself.
- It exposes a **CLI and socket API** to create workspaces, split panes, send keystrokes, and automate the browser.
- Its sidebar shows **working directory, branch, ports, and latest notification text**, and waiting agents light up with a visual indicator.

Source:

- <https://github.com/manaflow-ai/cmux>

Implication:

- `cmux` is the closest thing to "mission control for parallel coding sessions".
- It only helps if the user is willing to treat **"Ghostty-compatible replacement"** as acceptable. If "must keep using Ghostty.app" is non-negotiable, `cmux` does **not** satisfy the requirement.

#### Category B: Session browser / history / live HUD

**Best current candidate:** `Agent Sessions`

Evidence:

- It is a unified macOS app for **Codex CLI, Claude Code, Cursor CLI, Gemini CLI, GitHub Copilot CLI, OpenCode, and OpenClaw**.
- Its beta **Agent Cockpit** is a live command center for active sessions with shared active/waiting summaries and live Claude usage tracking.
- It can **click to jump straight to a session**, but the live cockpit currently targets **iTerm2**, not Ghostty.
- Latest release in the repo is **AgentSessions 3.6.3 on April 24, 2026**.

Source:

- <https://github.com/jazzyalex/agent-sessions>

Implication:

- This is the strongest "do we really need to build our own session browser?" challenge to the product thesis.
- It still misses the core Ghostty requirement and does not provide a multi-provider quota/capacity planner.

#### Category C: Quota / usage visibility

**Strongest current candidate for your workflow:** `CodexBar`

Evidence:

- Its README describes support for `Codex`, `Claude`, and `Gemini`, with local CLI/OAuth/cookie-based sources rather than requiring OpenCode as the core runtime.
- It exposes session and weekly meters, reset countdowns, and a bundled CLI.
- It is explicitly a macOS status-bar style quota utility, not a terminal/session coordinator.

Source:

- <https://github.com/steipete/codexbar>

Implication:

- If the pain is primarily **"I want to know remaining quota across providers"**, a meaningful piece of the problem is already solved today.
- It does not solve the mission-control or backlog halves.

**OpenCode Bar** remains relevant only for people already using OpenCode heavily.

Evidence:

- The README says it "automatically detects and monitors all AI providers registered in your OpenCode configuration."
- Its install/usage section says to "Make sure you have OpenCode installed and authenticated with your providers."
- It can auto-detect some standalone sources like `~/.codex/auth.json`, but the product is still centered on the OpenCode ecosystem.

Source:

- <https://github.com/opgginc/opencode-bar>

Implication:

- For **your** workflow, `OpenCode Bar` should not be the default recommendation.

**Secondary candidate:** `Codeburn`

Evidence:

- It supports multiple providers from local data sources, including Claude Code, Claude Desktop, Codex, Cursor, OpenCode, Pi, OMP, and GitHub Copilot.
- It provides a TUI and lets the user toggle between providers when multiple session data sources are present.
- Its positioning is token/cost observability, not backlog-aware capacity or session routing.

Source:

- <https://github.com/getagentseal/codeburn>

Implication:

- `Codeburn` is useful as an analytics source, but it is not the product we are evaluating.

### 3. Backlog/orchestration exists, but not with quota or Ghostty-native session control

**Closest precedent:** `Vibe Kanban`

Evidence:

- It plans work as **kanban issues** and runs coding agents in workspaces with review and preview flows.
- The repo README now explicitly says **"Vibe Kanban is sunsetting."**

Source:

- <https://github.com/BloopAI/vibe-kanban>

Implication:

- It remains valuable as a product-shape reference for backlog/orchestration UX.
- It is not a safe adoption target, and it still does not answer our quota + Ghostty problem.

### 4. Newer multi-provider dashboards exist, but they still miss the combined requirement

Examples worth noting:

- `Entropic`: unified dashboard for Claude/Codex/Gemini session and git monitoring, but no meaningful quota/capacity layer.
- `CloudCLI UI`: multi-agent web/mobile UI for Claude Code, Cursor CLI, Codex, and Gemini CLI, but it is a remote web shell/manager rather than a Ghostty-side companion.
- `Claude Code Agent Monitor`: strong real-time Claude-only observability via hooks; useful as an implementation reference, but single-provider and not Ghostty-centric.
- `Claude Code History Viewer`: strong cross-provider history/search/analytics, but not a live mission-control or quota planner.

Sources:

- <https://github.com/Dimension-AI-Technologies/Entropic>
- <https://github.com/siteboon/claudecodeui>
- <https://github.com/hoangsonww/Claude-Code-Agent-Monitor>
- <https://github.com/jhlee0409/claude-code-history-viewer>

Implication:

- The market is clearly filling in around the edges.
- The gap is no longer "nobody is doing anything here"; the gap is specifically **"nobody is combining the right pieces in a Ghostty-first way."**

## Coverage Matrix

| Tool | Parallel Sessions | State Visibility | Works Alongside Ghostty | Multi-Provider Quota | Backlog/Capacity | Verdict |
|---|---|---|---|---|---|---|
| `cmux` | Strong | Strong | **No** (Ghostty-based replacement) | No | No | Best terminal mission-control candidate if Ghostty replacement is acceptable |
| `Agent Sessions` | Medium | Medium | **No** for live mode (iTerm2-based cockpit) | Partial | No | Best session browser / HUD, but not Ghostty-native |
| `CodexBar` | No | No | Yes | **Strong** | No | Best quota tracker for a direct Claude/Codex/Gemini workflow, not mission control |
| `OpenCode Bar` | No | No | Yes | Medium | No | Good if you already live in OpenCode; weaker fit otherwise |
| `Codeburn` | No | No | Yes | Medium | No | Good analytics source, not a product substitute |
| `Vibe Kanban` | Strong | Strong inside its app | No | No | Partial | Good precedent, weak adoption target, sunsetting |
| `Entropic` | Medium | Medium | Partial | No | No | Interesting dashboard, not enough fit |
| `CloudCLI UI` | Medium | Medium | No | No | No | Remote UI, not Ghostty-side companion |

## Build vs Adopt Answer

### Option A: "Do not build a product"

This is only defensible if we accept a **stack of tools** instead of a single cohesive product.

The strongest no-build stack today is:

1. `CodexBar` for cross-provider quota visibility.
2. `Agent Sessions` for session search/history/HUD, **or** `cmux` if replacing Ghostty is acceptable.
3. A lightweight backlog tool (`markdown`, `JSON`, or kanban app) managed separately.

What this stack still lacks:

- Ghostty-native jump-to-session while staying in Ghostty.app.
- A unified state model across providers.
- Capacity-aware backlog suggestions.

Verdict:

- Good enough for a **personal workflow workaround**.
- Not good enough if the thesis is **"one coherent Ghostty-first mission control product."**

### Option B: "Build the original product from scratch"

The current OSS landscape makes a full from-scratch product less attractive than before.

Reason:

- The hard parts already have precedents.
- Rebuilding terminal UX, quota parsing, and session browsing wholesale is unnecessary duplication.

Verdict:

- **Do not** build a new terminal, new orchestrator, or new quota parser stack from zero unless forced to.

### Option C: "Build a thin integration layer"

This is now the most defensible path.

Build only the missing glue:

1. **Ghostty-side watcher/jump layer**.
2. **Normalized session-state model** across Claude Code / Codex / Gemini CLI.
3. **Quota ingestion adapters** from existing tools or provider surfaces.
4. Optional lightweight backlog matcher on top.

Verdict:

- This is the narrowest product that still has a reason to exist.

## Recommendation

### Short answer

**Yes, the product still has a reason to exist** if the requirement set remains strict:

- stay with **Ghostty.app**
- see **parallel session state**
- aggregate **multi-provider quota**
- eventually connect that to **what to start next**

No current OSS tool covers all of that.

### Narrowed recommendation

Do **not** build:

- a terminal emulator
- a browser-based coding workspace
- a full kanban/orchestration suite
- a fresh quota tracker for every provider

Do build only:

- a **Ghostty-native mission-control/watcher layer**
- with adapters into existing quota/session ecosystems where practical

### Immediate practical next step

Before committing to code, run a short real-world adoption test:

1. Try `CodexBar` for quota visibility.
2. Try either `Agent Sessions` or `cmux` for active-session awareness.
3. Measure which pain remains after 3-7 days.

If the remaining pain is specifically:

- "I still cannot stay in Ghostty and jump to the right session quickly"
- "I still cannot see a unified active/waiting view across providers"
- "I still cannot relate quota to what I should pick up next"

then the product still deserves to exist.

## Validated Assumptions

| Assumption | Status | Evidence |
|---|---|---|
| No single OSS tool covers all pillars | Confirmed | Cross-check of `cmux`, `Agent Sessions`, `OpenCode Bar`, `Codeburn`, `Vibe Kanban`, `Entropic`, `CloudCLI UI` |
| There are now credible substitutes for parts of the product | Confirmed | `cmux` for mission control, `OpenCode Bar` for quota, `Agent Sessions` for session HUD/history |
| Ghostty-first is the key differentiator | Confirmed | Strongest mission-control tools either replace Ghostty or target another terminal |
| A thin integration layer is more justified than a full greenfield product | Confirmed | Most subsystem primitives already exist upstream |

## Open Questions

- [ ] Is `cmux` acceptable if it is "Ghostty-compatible" but not literally Ghostty.app?
- [ ] Is a 2-3 tool stack acceptable for personal use, even if it is not a product?
- [ ] Do we actually need backlog/capacity matching in v1, or is quota + active-session state enough?
- [ ] Which current tool feels least compromising in a real one-week trial: `cmux`, `Agent Sessions`, or `OpenCode Bar`?

## References

- `cmux`: <https://github.com/manaflow-ai/cmux>
- `Agent Sessions`: <https://github.com/jazzyalex/agent-sessions>
- `CodexBar`: <https://github.com/steipete/codexbar>
- `OpenCode Bar`: <https://github.com/opgginc/opencode-bar>
- `Codeburn`: <https://github.com/getagentseal/codeburn>
- `Vibe Kanban`: <https://github.com/BloopAI/vibe-kanban>
- `Entropic`: <https://github.com/Dimension-AI-Technologies/Entropic>
- `CloudCLI UI`: <https://github.com/siteboon/claudecodeui>
- `Claude Code Agent Monitor`: <https://github.com/hoangsonww/Claude-Code-Agent-Monitor>
- `Claude Code History Viewer`: <https://github.com/jhlee0409/claude-code-history-viewer>
