---
description: Define code changes as component contracts in the task model
argument-hint: [task-path]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion, Task, mcp__context7__resolve-library-id, mcp__context7__query-docs
---

# Code Changes (Contracts)

Define the interfaces the implementation must honor as **LikeC4 components with
contract metadata** (`model/contracts.c4`). The reviewer sees each contract as a
node wired into the system it extends — signatures and payloads live in
`metadata`, not in a separate document.

## Arguments

- **task-path** (optional): Path to task folder
  - If not provided, auto-detects using:
    1. Current task from `.sahaidachny/current-task` (set via `saha use`)
    2. Most recent task folder in `docs/tasks/`
  - If no context found, asks the user

## Prerequisites

- Task model exists (`model/task.c4`)
- User stories defined (`model/stories.c4` + progress.yaml stories)
- Design decisions documented (recommended, `model/decisions.c4`)

## Execution

### 1. Analyze Requirements

Read:
- `{task_path}/model/task.c4` - The element vocabulary (`sys`, its components)
- `{task_path}/model/stories.c4` + `{task_path}/progress.yaml` - What flows exist
- `{task_path}/model/decisions.c4` - Constraints already decided
- `.claude/templates/contracts.c4` - Template/conventions for this artifact

### 2. Identify Contract Surfaces

From the story flows, list every interface the implementation will create or
change:
- **API endpoints** (REST/GraphQL/RPC): route, request, response, errors
- **Events** (published/consumed): topic, payload, ordering/delivery
- **Functions/methods** (internal seams other code will call): signature, behavior
- **Data schemas** (tables, files, config): shape, migration

Present the list to the user; confirm which surfaces need explicit contracts.
Skip surfaces that are pure implementation detail — a contract is only worth
writing where getting the interface wrong is expensive.

### 3. Author Contract Components

Add each contract to `{task_path}/model/contracts.c4`
(following `.claude/templates/contracts.c4`):

```likec4
model {
  // Contracts attach INSIDE existing task.c4 elements. Re-opening a nested
  // element from another file requires the `extend` keyword:
  extend sys.new_part {
    api = component 'POST /sessions' {
      description 'Registers a session and returns its board card id.'
      metadata {
        contract_kind 'rest'         // rest | event | function | schema
        file 'app/Sources/GhostlingCore/SessionRegistry.swift'
        contract '''
          POST /sessions
          Request:  { "cwd": "string — absolute repo path", "pid": "int" }
          Response: 201 { "card_id": "string" }
          Errors:   400 invalid cwd; 409 already registered
        '''
        stories 'US-001; US-002'
      }
    }
  }

  // Relations show WHO calls the contract; payload summaries go on the relation:
  sys.existing_part -> sys.new_part.api 'registers on launch' {
    metadata { payload '{ cwd, pid }' }
  }
}
```

Rules:
- `contract_kind` is the key name — `kind` is a **reserved word** inside
  `metadata {}` and will not compile.
- The `contract` block is the normative text: exact signatures, request/response
  shapes with field types, error cases. Write it with the same rigor the old
  markdown contract docs demanded — it renders in the element's detail panel.
- `file` names where the contract will live in code — the implementer and the
  DoD reachability check both use it.
- `stories` lists every US the contract serves; if a contract reveals a missing
  step in a story flow, fix the flow (spec is not frozen until execution starts).
- Every contract component must have at least one relation — a contract nobody
  calls is dead spec.
- Maintain the `contracts` view: all contract components + their callers.

Use Context7 to check current library/framework API conventions when a contract
wraps an external dependency.

### 4. Contract Quality Checklist

For each contract verify:
- [ ] Every error case has a defined response/behavior
- [ ] Field types are explicit (not "object" / "any")
- [ ] Naming is consistent with the existing codebase
- [ ] Breaking changes to existing interfaces are called out in `description`
- [ ] Related stories are referenced and consistent with the story flows

### 5. Compile Gate + Progress

```bash
likec4 validate {task_path}/model
```

Fix any errors, then update `{task_path}/progress.yaml`:

```yaml
planning:
  code_changes: { status: done, views: [contracts] }
```

## 6. Review Artifacts

Launch the reviewer agent to validate contracts:

```
Task tool:
  subagent_type: general-purpose
  prompt: |
    You are the Sahaidachny Reviewer. Read your instructions from:
    .claude/agents/planning_reviewer.md

    Review mode: contracts
    Task path: {task_path}
    Artifacts to review: {task_path}/model/contracts.c4

    Review the contracts and report any issues.
```

If the reviewer finds blockers (🔴), fix before proceeding.

## Example Usage

```
/saha:contracts docs/tasks/task-01-auth
```

## Output

Creates or updates:
- `{task_path}/model/contracts.c4` (view `contracts`)
- `{task_path}/progress.yaml` (planning.code_changes)
