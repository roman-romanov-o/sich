# Implementation Plan

Phased execution plan for **task-01 v1** (Agentic Coding Mission Control — US-001–006), built on **DD-001** (embed libghostty / become the terminal).

> **Planning assumptions** (defaults, since DD-002/DD-003 are unresolved): **in-app-only** sessions (no external Ghostty.app observation in v1) and **macOS-first**. Surfaced as risks below; formalize as DD-002/DD-003 if challenged.

> **Status currency** (2026-06-17): Phase 00 passed (**GO**); the headless Python logic core for Phases 02–04 is built + green; what remains is the Swift/AppKit *surface* (terminal NSView, board rendering, drill-in, quota gauges). The **HELM UI POC** (`research/UI_POC.html`, critique in `research/14-ui-mockup-critique.md`) is the design reference for the rendering phases (03/04) and **resolves DD-004** toward *state-columns × two-flow swimlanes*.

## Overview

| Phase | Name | Status | Stories | Effort |
|-------|------|--------|---------|--------|
| 00 | libghostty Embedding Spike (GATE) | ✅ **GO** (2026-06-16) — `spike/phase00-pty-smoke/RESULT.md` | de-risks US-001 | M |
| 01 | Terminal Foundation | 🔨 Core slice built + green (8 swift tests); windowed NSView surface pending | US-001 | XL |
| 02 | State Detection | ✅ Logic core done (29 tests: 21 unit + 8 integration); live HTTP/PTY wiring deferred to Phase 01 shell | US-004 | L |
| 03 | Board + Attention + Drill-in | 🔨 Derivations done (E2E-green); rendering + drill-in pending Phase 01 shell | US-002, US-003, US-005 | L |
| 04 | Two-Pool Quota Visibility | ✅ Logic core done (8 tests); `QuotaPanel` UI pending Phase 01 shell | US-006 | L |

## Dependency Graph

```
Phase 00: libghostty Spike (GATE)
    │  GO ──────────────┐         NO-GO → DD-005 Option-3 fallback (ride cmux), re-plan 01–03
    ▼                   │
Phase 01: Terminal Foundation (US-001)
    │                   │
    ├─────────────┐     └────────────────┐
    ▼             ▼                       ▼
Phase 02:     (app shell ready)     Phase 04: Two-Pool Quota (US-006)
State Detection (US-004)            [INDEPENDENT — parallel track]
    │
    ▼
Phase 03: Board + Attention + Drill-in (US-002/003/005)
```

## Critical Path

The terminal/board track is the critical path; the quota track is off it.

1. ~~**Phase 00 GO** — the keystone~~ — **resolved GO 2026-06-16** (in-process PTY read proven on pinned `ghostty@ae52f97d` / Zig 0.15.2). The Option-3 (ride-cmux) fallback branch is now closed; downstream phases are unblocked.
2. **Phase 01** — terminal substrate + session registry + pool firewall.
3. **Phase 02** — state detection (depends on PTY read).
4. **Phase 03** — board/attention/drill-in (depends on state).

**Phase 04 (quota) is parallelizable** — it only needs the Phase 01 app shell, not the state/board track. It's the lowest-risk, highest-differentiation work and can run alongside 02–03 (or early, for momentum/value).

## Timeline (relative, solo dev)

```
Phase 00 ███░░░░░░░░░░░░░░░░░░░░░░   (gate first)
Phase 01 ░░░██████████░░░░░░░░░░░░
Phase 02 ░░░░░░░░░░░░████████░░░░░
Phase 03 ░░░░░░░░░░░░░░░░░░██████░
Phase 04 ░░░░░░░░░░░░██████████░░░   (parallel with 02–03)
```

## Risks Summary

| Phase | Key Risks |
|-------|-----------|
| 00 | libghostty embedding API unstable (Medium/Critical) → Option-3 fallback |
| 01 | Maintaining a terminal emulator (large); pool-firewall bypass by later features |
| 02 | Hook coverage gaps; flaky detection on real sessions |
| 03 | Terminal-switch lag at 6–7 sessions; DD-004 resolved (HELM POC) — residual risk only if topology is revisited |
| 04 | Interactive-pool remaining only inferable (show confidence, not precision) |

## Execution Notes

- **Solo developer.** Critical path is 00→01→02→03; slot Phase 04 in parallel once the app shell exists.
- **Every phase ships its tests** (the E2E-first suite, driven by the fake-agent fixture — the suite never spends quota / never calls `claude -p`).
- **Open sub-decisions:** DD-002 (hybrid vs. in-app-only) and DD-003 (cross-platform) are assumed for now. **DD-004 (board topology) is now resolved** by the HELM POC → *state-columns × two-flow swimlanes* (Flow-A saha / Flow-B interactive), with the saha pipeline as an Altitude-1 drill-in, not a board column; formalize as a DD-004 file when convenient.
- **Stack** (DD-001): Swift/AppKit + libghostty C API, macOS-first. Any Python sidecar (quota/state) follows the repo's Python conventions (Pydantic V2, module-level imports, functions ≲50 lines, pytest E2E-first).
