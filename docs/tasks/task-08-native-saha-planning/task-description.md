# Task Description: Native saha planning surface in the kanban UI

**Task ID:** task-08
**Status:** Draft
**Last Updated:** 2026-07-05

## Problem Statement

Today, using saha's structured planning pipeline (`/saha:init → task → research → stories → decide → contracts → test-specs → plan → verify`) happens entirely in raw CLI/terminal, with the user manually remembering which slash command comes next and reading raw markdown files to review docs. The kanban app already hosts live interactive Claude terminal sessions and models a "saha flow" (`CardFlow.a`) vs "interactive flow" (`CardFlow.b`) distinction, but has no native surface for the planning pipeline itself — no doc rendering, no step guidance, and no mapping from a board card to its `docs/tasks/task-XX/` folder.

### Current State

- Planning progress lives entirely as markdown markers (`**Status:**` lines, README progress tables, `- [ ]` checkboxes) with no machine-readable state; the user (or `/saha:status`) must scan files to know what's next.
- The app has no markdown/mermaid rendering capability anywhere (chrome is `NSTextField` + `NSStackView`; task-05 explicitly ruled out a webview for the diff panel).
- `BoardCard` has no link to a `docs/tasks/task-XX/` folder — saha-flow cards and their planning artifacts are entirely disconnected from the board today.
- Chat during planning already works today only by manually opening a terminal and typing `/saha:xxx` commands yourself — no proactive guidance.

### Desired State

- Creating a saha-flow card lets the user pick an existing task folder or create a new one (via saha's own `init_task.sh`), binding the card to it from birth.
- A new "Planning Mode" altitude (full-window overlay, sibling to today's drill-in) shows: a live stepper of the planning pipeline (derived from the task folder's status markers, file-watched), a native rendered doc viewer (markdown + optional mermaid, no webview) for the artifact the current step produces, and an embedded terminal session where the user runs the actual `/saha:*` commands — with the app pre-typing the next command as a suggestion.
- Saha itself gains a `--json` planning-status output (wrapping the existing `TaskVerifier`) so parsing planning state has one official source of truth instead of two repos independently reading markdown heuristics.

## Success Criteria

Measurable outcomes that define "done":

1. [ ] A user can create a saha-flow card, pick "create new" or an existing task folder, and land in Planning Mode bound to that folder.
2. [ ] The stepper accurately reflects real planning progress (derived from the task folder) and updates live as `/saha:*` commands run in the embedded terminal, without polling faster than the existing file-watcher cadence.
3. [ ] The doc viewer renders a real saha markdown artifact (tables, checkboxes, headers) natively with app theming, with no `WKWebView` anywhere in the diff/doc path.
4. [ ] Clicking the next incomplete step in the stepper pre-types the corresponding `/saha:*` command into the terminal pane without auto-executing it (suggest, not dispatch).
5. [ ] `saha plan-status --json` (or equivalent) exists in sahaidachny and is pytest-covered, returning the same completeness data the stepper needs.

## Scope

### In Scope

- Card creation flow: flow choice (saha vs interactive), existing-task picker with progress chips, create-new via `init_task.sh`.
- `BoardCard.taskFolder` binding + `TaskFolderIndex` fallback (projectDir scan + `.sahaidachny/current-task`) for cards created outside the app.
- `PlanningStateReader`: parse task folder status markers/README table into a `PlanningState` model, file-watched.
- Planning Mode altitude in `BoardShell`: stepper pane, doc viewer pane, terminal pane (normal `SessionRegistry` session).
- Native markdown rendering (swift-markdown → `NSAttributedString` → `NSTextView`), with mermaid rendered via optional `mmdc` shell-out and graceful degradation when absent.
- Saha-side `plan-status --json` command wrapping `TaskVerifier`.

### Out of Scope

- Any change to saha's planning *commands themselves* (the slash-command recipes) — this task only adds a native viewer/driver around them, not new planning logic.
- Execution-mode UI (running `/saha:execute` / `saha run` and visualizing the execution-state YAML) — covered by a future task; this task only surfaces the hand-off suggestion once verify passes.
- task-06's proactive advisor policy/DAG reasoning — this task produces the artifact state task-06 would consume, but does not implement task-06's decision logic.
- A webview-based renderer of any kind.

## Constraints

| Type | Constraint | Reason |
|------|------------|--------|
| Technical | No `WKWebView` in the doc viewer | Consistent with task-05's stock-chrome rule; native rendering keeps app theming pixel-consistent |
| Technical | Never auto-dispatch `/saha:*` commands or spawn `claude -p` | Watcher-not-spawner pool-firewall invariant is a hard economic constraint for this app |
| Technical | Planning state must be derivable without a saha code change (fallback) | The app should degrade gracefully against older saha versions without `plan-status --json` |

## Dependencies

### Prerequisites

- [ ] None blocking — saha and the app are both already in place; this is additive.

### Blockers

- [ ] None currently known.

## Technical Context

Two-repo change. On the app side (`agentic-coding-kanban`): a new altitude (reuses `BoardShell`'s proven `drill()/returnToBoard()`-style overlay mechanics), a new pure-logic `PlanningStateReader` (GhostlingCore, unit-testable), a new native markdown renderer, and a `BoardCard`/`TaskFolderIndex` extension. On the saha side (`sahaidachny`): one new Typer subcommand wrapping the existing `TaskVerifier`.

### Affected Components

- `app/Sources/GhostlingApp/BoardShell.swift` - add a third altitude/overlay for Planning Mode
- `app/Sources/GhostlingCore/BoardCard.swift` - add `taskFolder` field
- `app/Sources/GhostlingCore/` (new) - `PlanningStateReader`, `TaskFolderIndex`, markdown→NSAttributedString walker
- `app/Sources/GhostlingApp/` (new) - stepper view, doc viewer view, Planning Mode container view
- `~/MyProjects/sahaidachny/saha/commands/execution.py` (or a new command module) - `plan-status --json`
- `~/MyProjects/sahaidachny/saha/verification/checker.py` - reused as-is (`TaskVerifier`)

### Integration Points

- `FileWatcher` (existing, sub-250ms) - watch the bound task folder for doc/status changes
- `SessionRegistry` / `PoolFirewall` (existing) - the planning terminal is a normal registered session, no new spawn path
- `docs/tasks/task-06-proactive-mission-control` - shares the task-folder artifact model; this task's output state should be consumable by task-06's future `PlanAttestation` without rework

## Planning Artifacts

<!-- Check off artifacts as they are created -->

### Required

- [ ] **User Stories** - `user-stories/` folder
- [ ] **Implementation Plan** - `implementation-plan/` folder with phases
- [ ] **Test Specifications** - `test-specs/` folder

### Optional

- [ ] **UI Design** - `ui-design/` folder (stepper/doc-viewer/terminal layout)
- [ ] **Code Changes** - `code-changes/` folder (the `plan-status --json` contract, `PlanningState` model)
- [x] **Design Decisions** - `design-decisions/` folder (already anticipated: no-webview confirmation, creation-time flow binding)
- [x] **Research Report** - `research/native-planning-proposal.md` (done — this task description is derived from it)

## Open Questions

- [ ] Should `plan-status --json` live in sahaidachny as a hard dependency, or should the app always prefer its own `PlanningStateReader` and treat saha's JSON as an optional fast-path/cross-check?
- [ ] What's the minimum viable mermaid support given `mmdc` is an optional external dependency — is degraded (code-block) rendering acceptable for v1, or should mermaid be deferred entirely to a later task?
- [ ] Does the "pre-type the next command" interaction need an explicit confirm step in the UI, or is landing it in the terminal's input line (unsent) sufficient signal that it's a suggestion?

## References

- `docs/tasks/task-08-native-saha-planning/research/native-planning-proposal.md`
- `docs/tasks/task-06-proactive-mission-control/README.md` (shared artifact model, future consumer)
- `docs/tasks/task-05-turn-diffs/task-description.md` (precedent for "no webview" chrome rule)
