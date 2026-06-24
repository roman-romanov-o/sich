# TASK-01: Initial

**Status:** Building (planning complete; Phase 00 **GO**, logic core green, Swift surface in progress)
**Mode:** Minimal
**Created:** 2026-04-27 · **Updated:** 2026-06-17

## Overview

Began as a research task validating whether a Ghostty-first "agentic coding mission control" product should exist or whether current OSS already covers the need. **Resolved toward building** via **DD-001** (embed libghostty / become the terminal) with a hard **never-auto-`claude -p` pool firewall**. Now executing the 5-phase plan: Phase 00 (embedding gate) passed GO, the headless Python logic core for Phases 02–04 is built + green, and the Swift/AppKit surface is underway.

## Planning Progress

| Step | Status | Artifacts |
|------|--------|-----------|
| Research | Done | research/*.md |
| Task Description | Done | task-description.md |
| Design Decisions | DD-001 accepted; DD-004 resolved (HELM POC); DD-002/003 assumed | design-decisions/DD-*.md |
| User Stories | Done (v1: US-001–006) | user-stories/US-*.md |
| Test Specs | Done (v1) | test-specs/**/*.md |
| Implementation Plan | Done + refreshed (5 phases; statuses current 2026-06-17) | implementation-plan/phase-*.md |
| Python Sidecar (Phase 02–04 logic) | Built + green (50 tests; ruff/ty/complexipy clean) | src/mission_control/**, tests/** |
| Swift app (Phase 01 core) | First slice built + green (`app/`, swift test 8/8) | app/Sources/GhostlingCore/* |
| Verification | ⚠️ Passed with warnings (2026-06-17) — ready for implementation | verification-report.md |

## Next Steps

Critical path is **01 → 02-wiring → 03**; Phase 04 runs in parallel.

- [ ] **Phase 01 surface:** AppKit `NSView` rendering the `libghostty-vt` screen + routing keystrokes into `PTYSession.write` (the live interactive pane; verify by launch + visual check) + a Swift `SessionRegistry`/lifecycle.
- [ ] **Phase 02 wiring:** HTTP hook endpoint → `detector.hook_receiver.normalize_*` → `StateReconciler` → `SessionRegistry`, feeding real sessions into the (already-green) logic core.
- [ ] **Phase 03 rendering:** board (state-columns × two-flow swimlanes per the HELM POC), attention signal, and <500 ms drill-in to the embedded terminal — applying the POC critique's keep/cut/fix.
- [ ] **Phase 04 (parallel):** `QuotaPanel.swift` four-pool gauges over the built `QuotaAggregator`.
- [ ] Formalize a **DD-004** file (board topology) and, if challenged, DD-002 (in-app-only) / DD-003 (macOS-first).
