# Implementation Plan

Phased execution plan with steps and dependencies.

## Contents

| Phase | Scope | Stories | Effort | Dependency |
|------|-------|---------|--------|------------|
| [01 — Task-folder binding](phase-01-task-folder-binding.md) | Persist card bindings, discover/infer task folders, and scaffold or select them during card creation | US-001, US-002 | L | None |
| [02 — Planning-state contract](phase-02-planning-state-contract.md) | Parse planning state, watch artifact changes, and add the optional `saha plan-status --json` source | US-003, US-006 | L | Phase 01 |
| [03 — Planning Mode](phase-03-planning-mode.md) | Add the full-window planning altitude, stepper, raw document pane, and suggest-only terminal interaction | US-004 | L | Phase 02 |
| [04 — Native document viewer](phase-04-native-document-viewer.md) | Render markdown and optional Mermaid natively, then verify the complete flow | US-005 | L | Phase 03 |

## Execution Order

Phases are ordered by the user-visible dependency chain. Phase 02's saha CLI
work may be implemented in parallel with its Swift reader, but the reader must
retain marker scraping as a tested fallback. Phase 03 deliberately uses raw
document text until Phase 04 replaces it with native rendering.

## Cross-Phase Invariants

- Never auto-submit a `/saha:*` command or introduce a `claude -p` spawn path.
- An explicit `BoardCard.taskFolder` binding is authoritative; the project-wide
  `.sahaidachny/current-task` pointer is inference-only.
- Planning-state updates reuse filesystem events and debounce bursts; they do
  not add a fast polling loop.
- No `WKWebView` is introduced in the planning or document-viewer path.
- Unknown, missing, or malformed planning artifacts degrade visibly and do not
  crash the board.
