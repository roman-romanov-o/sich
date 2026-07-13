# Code Change: Task-folder binding (`BoardCard.taskFolder`, `TaskFolderIndex`, `init_task.sh` invocation)

**Type:** Internal Swift interface
**Module:** GhostlingCore
**Status:** Draft

## Overview

Covers US-001 (creation-time binding) and US-002 (fallback inference for pre-existing cards). `BoardCard.taskFolder` is the single authoritative binding once set; `.sahaidachny/current-task` is read only as an inference hint for cards that have no binding yet, and is never re-consulted for a card once bound (fixes the multi-card hazard flagged by the stories reviewer).

## Interface

```swift
extension BoardCard {
    var taskFolder: URL? { get set } // authoritative once non-nil
}

enum SahaFlowChoice { case sahaFlow, interactiveFlow }
enum TaskFolderChoice { case createNew(name: String), pickExisting(URL) }

protocol TaskScaffolding {
    // shells out to init_task.sh; throws a typed error on non-zero exit
    func createTaskFolder(name: String, projectRoot: URL) throws -> URL
}

struct TaskFolderIndex {
    // scans projectRoot/docs/tasks/task-*/ ; reads each README's progress table
    // for a progress-chip summary (e.g. "2/8", or "unknown" if no markers)
    static func discover(projectRoot: URL) -> [TaskFolderSummary]
}

struct TaskFolderSummary {
    let path: URL
    let doneCount: Int?   // nil => "unknown" chip
    let totalCount: Int   // fixed at 8
}

protocol TaskFolderInferring {
    // used for cards with taskFolder == nil at board-load time
    // returns nil (leaves card unbound) on zero or ambiguous (>1) matches
    func inferBinding(for card: BoardCard, projectRoot: URL) -> URL?
}
```

## Behavior

- **Creation (US-001):** card creation UI presents `SahaFlowChoice` explicitly (AC1). Choosing `.sahaFlow` then presents `TaskFolderChoice`. `.createNew` calls `TaskScaffolding.createTaskFolder`, which shells to `init_task.sh` and sets `BoardCard.taskFolder` directly from its returned path — never reads back `.sahaidachny/current-task` to determine the binding, since a second concurrent/subsequent creation could have overwritten it.
- **Non-zero exit:** `createTaskFolder` throws; no `BoardCard` is created/bound as a result.
- **Zero `docs/tasks/` folders:** `TaskFolderIndex.discover` returns `[]`; the picker UI offers only "create new".
- **Bare folder (no README/markers):** `TaskFolderSummary.doneCount == nil` → picker renders "unknown" chip; binding still succeeds on selection.
- **Fallback inference (US-002):** on board load, any card with `taskFolder == nil` is passed through `TaskFolderInferring.inferBinding`. Resolution order: (1) exactly one folder in `docs/tasks/` → bind to it; (2) multiple folders, but exactly one matches `.sahaidachny/current-task`'s pointer → bind to that one (the single positive disambiguation case); (3) zero folders, or multiple folders with no match / more than one matching `current-task` → return nil, leave card unbound. Planning Mode entry on an unbound card prompts the US-001 create/pick UI instead of guessing.

## Related

- **Stories:** US-001, US-002
- **Test Specs:** test-specs/e2e/card-creation-flow.md, test-specs/integration/init-task-invocation.md
