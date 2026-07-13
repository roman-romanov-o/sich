# User Stories

User stories define features from the user's perspective.

## Contents

| ID | Title | Priority | Status |
|----|-------|----------|--------|
| US-001 | Create a saha-flow card bound to a task folder | Must Have | Draft |
| US-002 | Infer task-folder binding for pre-existing cards | Should Have | Draft |
| US-003 | Live planning-progress stepper | Must Have | Draft |
| US-004 | Planning Mode altitude with driven terminal | Must Have | Draft |
| US-005 | Native markdown + mermaid doc viewer | Must Have | Draft |
| US-006 | `saha plan-status --json` command | Should Have | Draft |

## Story Map

### Kanban app user (planning)
- US-001: Create a saha-flow card bound to a task folder
- US-002: Infer task-folder binding for pre-existing cards
- US-003: Live planning-progress stepper
- US-004: Planning Mode altitude with driven terminal
- US-005: Native markdown + mermaid doc viewer

### Saha CLI / cross-tool consumers
- US-006: `saha plan-status --json` command

## Dependency chain

```
US-001 ─┐
US-002 ─┴─→ US-003 ─→ US-004 ─→ US-005
              ↑
US-006 ───────┘ (optional fast path)
```
