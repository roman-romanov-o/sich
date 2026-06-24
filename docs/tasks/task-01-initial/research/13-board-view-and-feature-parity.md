# Research: Board View (cmux drill-down) + Vibe Kanban Feature Parity

**Date:** 2026-06-15
**Status:** Complete
**Builds on:** `07-orchestrator-landscape.md`, `05-ghostty-integration.md`, `11-saha-relationship.md`, `12-two-flow-scheduling-model.md`

Two user asks drive this report:
1. *"I like cmux for terminal management… cmux uses tabs to manage terminals. But we can go from tabs to some board view, where I can dive into a terminal."* → the **interaction model**.
2. *"Let's have all the features something like vibekanban has."* → a concrete **feature parity checklist**, filtered through the watcher constraint.

---

## Part A — From cmux tabs to a board, with drill-down

### What cmux actually offers (verified, mid-2026)
- **Vertical-tab sidebar** = the persistent workspace list (primary navigation). Within a workspace, terminal **surfaces** split horizontally/vertically; an in-app browser can sit in a split.
- **Sidebar metadata per workspace:** git branch, linked PR status, working directory, listening ports, latest notification text, unread badges.
- **Agent state**, surfaced via a bundled `claude` wrapper that routes Claude Code hooks back into cmux: *running / waiting (Feed) / needs-attention (notification ring)*. Signals: OSC 9/99/777 escape sequences + the `cmux notify` CLI wired into agent hooks.
- **Control surface:** a JSON-RPC 2.0 **Unix-socket API** (`/tmp/cmux.sock`) — `window.*`, `workspace.*`, `pane.*`, `surface.*` incl. `surface.read_text` / `surface.send_text` / `surface.focus`; CLI incl. `cmux identify --json` and `cmux sessions list`.
- **No board / grid / overview.** Organization is *purely* vertical tabs + notification indicators (plus a Feed/Dock for approvals). **No event/push API** — external observation is **polling-only** today (issue #3325 proposes webhooks/SSE; not yet shipped).

### The gap the user spotted (and it is real)
cmux is a **list of tabs**, not an **overview**. With 6–7 parallel sessions, a vertical tab list still forces serial scanning: you read tab 1, then tab 2… The user's instinct — *go from tabs to a board* — is the correct generalization:

> **A tab list answers "what sessions exist." A board answers "what is the state of everything at a glance, and what needs me."** The second is the mission-control job (`project_vision`); the first is what cmux already does.

### Proposed interaction model: board → drill-down (two altitudes)

**Altitude 1 — the board (overview):** each session/task is a **card** placed in a column by state (or swimlane by flow — see `12`). The card shows the cmux-style metadata the user already likes, but *spatially arranged by state* instead of listed: branch · flow (A/B) · agent state (idle/running/waiting/blocked) · iteration/phase (for saha cards) · pool burn. "Who needs me" = the count of cards in the **Waiting/Blocked** column. This is the altitude cmux lacks.

**Altitude 2 — dive into the terminal (drill-down):** clicking a card drops you into the live session. Two viable mechanisms (from `05-ghostty-integration.md`):
- **Focus the real Ghostty tab** via AppleScript (`Ghostty.sdef`: `activate window` / `select tab` / `focus`). The board is a **launcher into Ghostty**, never a replacement — satisfies the "do not replace Ghostty" constraint. This is the primary path.
- **Embedded read-only peek** (optional, later): a read-only PTY scrape / last-N-lines preview inside the card so the user can triage *without* leaving the board. cmux proves the pattern (`surface.read_text`); for a watcher this stays **read-only** (no `send_text`, no spawning).

The drill-down is the "dive into a terminal" the user described — but **from a board card**, not from a tab.

### What to borrow from cmux vs. where to diverge
| Borrow | Diverge |
|---|---|
| Sidebar **metadata schema** (branch/PR/dir/ports/notification) → put it on cards | cmux *replaces* Ghostty (libghostty app); we **coexist** with Ghostty.app via AppleScript focus |
| **State signals** (OSC 9/99/777, hook-routed `notify`) as state inputs | cmux is a **spawner** of workspaces; we are a **watcher** of existing sessions |
| **Read-only socket read** pattern (`surface.read_text`) for embedded peeks | cmux organizes by **tabs**; we organize by **board columns / swimlanes** |
| Its **issue #3325 event taxonomy** as a blueprint for the transitions a watcher needs | cmux has **no quota awareness**; quota + capacity is our core differentiator |

> If the user is open to it, cmux's socket API means the kanban *could* observe cmux sessions as one more source — but the headline integration targets are **native Ghostty + Claude/Codex/Gemini hooks + saha hooks**, which need no cmux.

---

## Part B — Vibe Kanban feature parity (checklist, filtered for a watcher)

**Status note (verified):** Vibe Kanban (BloopAI) announced shutdown **2026-04-10**; it continues **Apache-2.0, community-maintained, local-only** (remote kanban/comments/projects/orgs removed; data export added). As of mid-June 2026 it is a local OSS tool, not a company product. It remains the **feature reference** for "a kanban for AI coding agents."

Legend: **Adopt** (build it) · **Adapt** (build it, but in watcher form) · **Drop** (conflicts with watcher/Ghostty constraints) · **Already-have-via-saha**.

| Vibe Kanban feature | Verdict | Notes for this project |
|---|---|---|
| **Kanban board: columns, cards, priority** | **Adopt** | Core UI. Extend with flow-aware columns/swimlanes (`12`). |
| **Plan → Execute → Review lifecycle** | **Adopt** | Maps to saha's Ready → Autonomous → Review (Flow A) and to interactive Flow B. |
| **Auto status updates** (on agent activity / PR merge) | **Adopt** | Drive from saha hooks + Claude/Codex hooks + git, not from spawned sessions. |
| **Worktree-per-task, branch-per-execution** | **Drop / defer** | This is *spawner* machinery. A watcher observes whatever branch the human/saha already uses. Don't own worktrees. |
| **Diff review (syntax-highlighted, inline comments)** | **Adapt** | High value for the **Review** column (esp. after a saha run). Build as a **read-only** diff viewer over the git diff; inline-comment-to-agent is a v2 maybe (it implies talking back → spawner-adjacent). |
| **PR creation with AI-generated description** | **Adapt (thin)** | A "create PR" button shelling out to `gh` is fine (it's not an agent spawn). AI description generation would spend a pool — make it explicit/optional. |
| **10+ agent support, agent switching** | **Adapt** | We care about **Claude Code / Codex / Gemini** (the subscription CLIs the user runs). "Switching" = recommending which runner/pool for the *next* task, not swapping mid-run. |
| **Parallel execution / background runs** | **Already-have-via-saha + Adopt view** | saha already runs autonomously in the background; our job is to *show* many in parallel — that's the whole product. |
| **Retry / follow-up on a task** | **Adapt** | = `saha resume` for Flow A; for Flow B it's just the human continuing. Surface a "resume" affordance. |
| **MCP server (board drivable by agents) / MCP client** | **Adapt (later)** | Exposing the board as an MCP server (read state, append backlog) is compatible with a watcher and a nice v2. Vibe Kanban precedent. |
| **Dev server / preview, built-in browser w/ devtools** | **Drop** | Out of scope; the user has Ghostty + their own tooling. Don't rebuild an IDE. |
| **Per-task terminal** | **Adapt → drill-down** | We don't *host* terminals; we **focus the real Ghostty tab** (Part A, Altitude 2). |
| **Templates** | **Adopt (cheap)** | A backlog-item template that pre-tags flow type + suggested runner is genuinely useful for the allocator. |
| **Task dependencies / queueing** | **Defer** | Useful for capacity scheduling later; not v1. |
| **— (Vibe Kanban has none) Multi-provider quota + capacity planning** | **Net-new differentiator** | Our reason to exist (`08`, `10`, `12`). Vibe Kanban is quota-blind. |
| **— (none) Coexist-with-existing-terminal watching** | **Net-new differentiator** | Vibe Kanban spawns; we watch native Ghostty sessions. |

**Reading of the table:** the parts of Vibe Kanban worth cloning are the **board + lifecycle + read-only review surface (diff viewer)**. The parts to *not* clone are its **spawner core** (worktree ownership, hosted terminals, dev server, agent launching) — those are exactly what the watcher constraint and "don't replace Ghostty" rule out, and exactly what makes Vibe Kanban a Flow-A-only, quota-blind tool. Our differentiators (multi-pool quota, two-flow capacity allocation, Ghostty coexistence) are precisely the gaps in its feature set.

---

## Synthesis: the product is "Vibe Kanban's board + cmux's metadata, on a watcher core, with a capacity brain"

- **Board & review surface** ← Vibe Kanban (Adopt/Adapt the board, lifecycle, diff viewer).
- **Card metadata & state signals** ← cmux (branch/PR/ports/notification + OSC/hook state), arranged as a **board with drill-down**, not tabs.
- **Drill-down** ← AppleScript focus into the real Ghostty tab (+ optional read-only peek).
- **Engine for Flow A** ← saha (observed via hooks/files/token telemetry; never auto-spawned).
- **The differentiator neither cmux nor Vibe Kanban has** ← two-pool quota awareness + two-flow capacity allocation (`12`).

## Open questions (for `/saha:decide`)

- [ ] **Board topology:** columns-by-state with a flow tag, or **swimlanes-by-flow** (Autonomous vs. Interactive) each with their own columns?
- [ ] **Drill-down depth for v1:** AppleScript-focus-only (simplest, honors "don't replace Ghostty"), or also an embedded read-only peek?
- [ ] **Review surface:** build the diff viewer in v1, or deep-link to the user's existing git tooling and defer?
- [ ] **Observe cmux too?** Only if the user actually runs cmux alongside Ghostty; otherwise skip its socket integration.

## References
- cmux: [cmux.com](https://cmux.com), [repo](https://github.com/manaflow-ai/cmux), [Socket API](https://manaflow-ai-cmux.mintlify.app/automation/socket-api), [events issue #3325](https://github.com/manaflow-ai/cmux/issues/3325).
- Vibe Kanban: [shutdown post (2026-04-10)](https://www.vibekanban.com/blog/shutdown), [repo](https://github.com/BloopAI/vibe-kanban).
- `05-ghostty-integration.md` (AppleScript focus), `07-orchestrator-landscape.md` (cmux/VK profiles), `11-saha-relationship.md`, `12-two-flow-scheduling-model.md`.
