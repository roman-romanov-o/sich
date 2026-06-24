# User Stories

User stories define features from the user's perspective. Personas collapse to one solo power-user wearing three hats: **Operator** (runs sessions), **Capacity Planner** (manages quota), **Backlog Groomer** (feeds the queue).

> **Scope:** v1 = the six Must-Have stories (US-001–006). Deferred stories (US-007–011) are listed as post-v1 backlog and not yet specified as files. Scope cut and the embed-the-terminal foundation follow **DD-001**.

## Contents (v1 — specified)

| ID | Title | Priority | Status |
|----|-------|----------|--------|
| US-001 | Launch/attach a session in the app's embedded terminal | Must Have | Draft |
| US-002 | Drill from a board card into its live terminal | Must Have | Draft |
| US-003 | See every session as a card placed by state | Must Have | Draft |
| US-004 | Trustworthy auto-detected session state | Must Have | Draft |
| US-005 | "Who needs me" attention signal | Must Have | Draft |
| US-006 | Two-pool quota visibility | Must Have | Draft |

## Backlog (post-v1 — not yet specified)

| ID | Title | Priority |
|----|-------|----------|
| US-007 | "Projects remaining this cycle" prediction (per pool) | Should Have |
| US-008 | Backlog tagged autonomous-ready vs. needs-interactive | Should Have |
| US-009 | Suggest-only capacity-aware launch recommendation | Should Have |
| US-010 | saha autonomous run appears as a Flow-A card (observed, not spawned) | Should Have |
| US-011 | Read-only diff viewer in the Review column | Could Have |

## Story Map

### Operator (situational awareness — Problem 1)
- US-001: Embedded terminal session *(foundation, DD-001)*
- US-002: Drill into terminal
- US-003: Board by state
- US-004: State detection *(critical feasibility)*
- US-005: Who-needs-me signal

### Capacity Planner (Problem 2 — the differentiator)
- US-006: Two-pool quota visibility
- US-007: Projects-remaining prediction *(deferred)*
- US-009: Suggest-only launch routing *(deferred)*

### Backlog Groomer (Problem 3)
- US-008: Flow-tagged backlog *(deferred)*

### Cross-flow / saha
- US-010: Observe saha Flow-A runs *(deferred)*
- US-011: Read-only diff review *(deferred)*

## Cross-cutting constraint (NFR, not a story)

The **never-auto-`claude -p` pool firewall** (DD-001 / watcher constraint) is baked into the acceptance criteria of US-001 and the future US-009 — the app only ever runs user-launched interactive sessions.
