# TASK-03: Native Core — Eliminate the Python Sidecar

**Status:** Phase 03 Machine-Complete — awaiting human visual sign-off on pixel AC (US-001 AC3)
**Mode:** Full (existing-codebase port)
**Created:** 2026-06-26 · **Updated:** 2026-06-26

## Overview

Today the Swift app (`app/`) runs a **Python sidecar** (`src/mission_control`, a stdlib
`http.server` on `127.0.0.1:8787`) and polls it for `/quota` and `/sessions`. The
quota *projection* math is **already duplicated natively in Swift** (`QuotaProjection`);
only two pieces of real I/O remain Python-only — reading `~/.claude/projects/**/*.jsonl`
for interactive-pool usage, and receiving agent hooks. This task ports those two pieces
into `GhostlingCore`, replaces the HTTP hook transport with an **observe-only append-only
file sink**, proves behavioral parity in `swift test`, and then **deletes
`src/mission_control`** — shipping a single Swift binary (the cmux model), with the
**watcher-not-spawner** discipline fully intact.

## Planning Progress

| Step | Status | Artifacts |
|------|--------|-----------|
| Research | Reused (task-01 `research/*`, memory) | — (see task-description "Technical Context") |
| Task Description | Done | task-description.md |
| User Stories | Done (US-001–005) | user-stories/US-*.md |
| Design Decisions | Done (DD-001, DD-002) | design-decisions/DD-*.md |
| Code Changes | Done (2 contracts) | code-changes/*.md |
| Test Specs | Done (parity matrix) | test-specs/README.md |
| Implementation Plan | Done (4 phases) | implementation-plan/phase-*.md |
| Verification | ⚠️ Passed with Warnings (0 errors, 5 suggestions) | verification-report.md |

## Scope at a glance

| In scope | Out of scope |
|----------|--------------|
| Native interactive-quota reads (JSONL walk + window aging) in Swift | Changing the two-pool model / projection math (already correct + duplicated) |
| Observe-only file-sink hook intake; tail + normalize + reconcile in Swift | Adding an in-app HTTP/socket server (DD-002 rejects it) |
| Carry the 66 pytest behaviors into `swift test`, then delete `src/mission_control` | New quota *sources* (Agent-SDK credit precision, etc.) — stays UNKNOWN as today |
| Stretch: multi-tool hook normalization (Cursor/Codex/Gemini), US-005 | Building the multi-tool installers UI (a later task) |

## Hard constraints (inherited, non-negotiable)

- **Watcher-not-spawner:** the core only OBSERVES native interactive sessions; it never
  spawns `claude -p`. The file sink is append-only and read-only to the app — it cannot
  become a spawn path. ([[watcher-not-spawner-quota-constraint]], DD-001 of task-01.)
- **Two Anthropic pools never netted.** This task does not touch that math; it only
  changes *where the source readings come from* (in-process instead of over HTTP).

## Next Steps

Critical path **Phase 01 → 02 → 03 is complete**. Phase 04 is an optional stretch.

- [x] **Phase 01:** port `jsonl_usage` + `live` source-assembly into a Swift
      `QuotaUsageReader` producing `[QuotaSourceInput]` in-process; prove parity
      (TC-UNIT-30x, TC-INT-30x) while the sidecar still runs as a fallback. ✓ Complete (iter 2)
- [x] **Phase 02:** switch `ghostling-forward.sh` from `curl POST` to an atomic append;
      add Swift `HookEventTail` → normalize (`_HOOK_KIND`) → reconcile into `SessionRegistry`;
      prove parity (TC-INT-32x). ✓ Complete (iter 3)
- [~] **Phase 03:** flip the app off `SidecarProcess`/HTTP polling; **delete
      `src/mission_control` + `tests/` Python suite**; single-binary DoD (TC-E2E-30x). ✓ Machine complete (iter 4), visual sign-off pending (US-001 AC3)
- [ ] **Phase 04 (stretch):** Rosetta-Stone installers + normalization for Cursor/Codex/Gemini
      (US-005) — the "unlock my colleagues" win the file sink makes trivial. *Optional after Phase 03.*
