# Implementation Plan

Phased execution plan for **task-04 live detection** — port cmux's proven
detection plumbing (reference, not fork; DD-001).

## Overview

| Phase | Name | Status | Stories | Effort |
|-------|------|--------|---------|--------|
| 01 | Event-driven delivery | Not Started | US-001 | M |
| 02 | Reconciler correctness | Not Started | US-002, US-005 | L |
| 03 | Durable & rich surface | Not Started | US-003, US-004 | L |

## Dependency Graph

```
Phase 01 (delivery: seq/occurred_at, incremental read, file-watch)
    ↓ (state ordering needs seq/occurred_at)
Phase 02 (correctness: ppid/workspace index, wired JSONL fallback, deterministic close, live-while-drilled)

Phase 03 (resume + shell-integration) — independent, deferrable
```

## Critical Path

**Phases 01 → 02 are the stated pain** ("board updates badly") and are the two
Must-have stories. Phase 01 is the foundation: the rotation-safe, FS-driven
delivery is what makes Phase 02's `timestamp`/`updatedAt` ordering trustworthy
(`occurred_at` already exists; there is no `seq`). Phase 03 is parallelizable
and can slip.

## Risks Summary

| Phase | Key Risk |
|-------|----------|
| 01 | rotation re-arm race → single `readNew()` mutator + TC-UNIT-003 |
| 02 | ppid absent for observed sessions (by design) → documented `session_id` fallback |
| 03 | restore must not spawn `claude -p` → explicit TC-UNIT-022 |

## Execution Notes

- Ship **01 + 02 first** — they resolve the pain; demo the board moving ≤250ms with correct state.
- Every step lists its AC and bound `TC-*` ids; the test-specs make those runnable and the DoD gate binds against them.
- Interface changes are folded into the phase steps (existing Swift types, not new API surface) — no separate `code-changes/*.md`.
- Watcher-not-spawner is a standing invariant across all phases.
