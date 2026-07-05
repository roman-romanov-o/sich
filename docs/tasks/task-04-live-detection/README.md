# TASK-04: Task 04 Live Detection

**Status:** Planned — Ready for Execution (reviewed & corrected)
**Mode:** Full
**Created:** 2026-07-01

## Overview

Make the board update **reliably and instantly** from agent activity. The pain
("ghostty updates the board badly") traced to the **detection/reconciler
layer**, not the terminal. Port four proven plumbing patterns from `cmux` (same
Swift+Ghostty+Claude-hook stack, used as a **reference — not a fork**):
(1) event-driven delivery, (2) reconciler correctness, (3) session resume,
(4) Ghostty shell-integration.

## Planning Progress

| Step | Status | Artifacts |
|------|--------|-----------|
| Research | Done (inline) | task-description.md → cmux reference model |
| Task Description | **Done** | task-description.md |
| User Stories | **Done** | user-stories/US-001..005 |
| Design Decisions | **Done** | design-decisions/DD-001..003 |
| Code Changes | Folded into plan | (existing types — no separate contracts) |
| Test Specs | **Done** | test-specs/README.md (AC→TC matrix) + integration/unit/producer |
| Implementation Plan | **Done** | implementation-plan/phase-01..03 |
| Review | **Done — corrected** | 5 findings applied (see below) |
| Verification | **✅ Passed w/ warnings** | verification-report.md (0 errors, 3 non-blocking) |

## Review outcome (post-planning, applied)

A consolidated reviewer pass caught that ~3 planned "new work" items were already
built. Corrections applied across every artifact:

1. **Incremental read already exists** — `HookEventTail.poll()` seeks to a saved
   offset; reframed from "new work" to a *regression guard* (`TC-INT-001`).
2. **`occurred_at` already exists** — as `SignalEvent.timestamp`; no new field.
3. **`ppid` deferred** — the stateless forwarder has no producer for it and no AC
   needs it; correlation orders by the store's existing `updatedAt`.
4. **Global `seq` dropped** — the O_APPEND forwarder can't produce a monotonic
   global counter; ordering uses `timestamp`. (Dropped `TC-UNIT-004`/`TC-UNIT-011`.)
5. **Rotation must key on inode** — `resolveStart` only resets on `saved > fileSize`,
   silently skipping the head of a fresh-but-large rotated file (`TC-UNIT-003`).
   Attention is already first-class via `permissionRequest` — confirmed, not rebuilt.

## Next Steps

- [ ] Execute Phase 01 (`/saha:execute`) once planning is signed off
- [ ] Phases 01+02 first — they resolve the stated pain
