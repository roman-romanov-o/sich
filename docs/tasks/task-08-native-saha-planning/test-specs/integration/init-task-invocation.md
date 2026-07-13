# Integration Test Spec: init_task.sh invocation

**Related:** US-001
**Priority:** High
**Status:** Draft

## Overview

Tests the app's shell-out to saha's real `init_task.sh` in isolation from the full creation-flow UI (E2E already covers the UI path with a fixture script; this covers the real script's actual argument/exit-code contract).

## Dependencies

- Real `init_task.sh` from a checked-out sahaidachny (or vendored copy), invoked in a temp directory
- No mocks — this is exactly the "real dependency over mock" testing philosophy

## Test Cases

### TC-INT-001: Successful scaffold in an empty project

**Description:** Confirms the app's process-invocation code correctly parses the script's stdout/exit code.

**Setup:**
```swift
let tempDir = makeTempProjectDir()
```

**Input:**
```json
{ "name": "sample-feature", "cwd": "<tempDir>" }
```

**Expected Output:**
```json
{ "exitCode": 0, "createdPath": "docs/tasks/task-01-sample-feature", "currentTaskFile": ".sahaidachny/current-task" }
```

**Assertions:**
- Process exit code is 0
- Parsed `createdPath` matches an actual folder on disk with the standard scaffold files
- `.sahaidachny/current-task` file content matches the folder name

---

### TC-INT-002: Auto-numbering skips a non-conforming existing folder

**Description:** Regression guard for the exact bug hit during this session (a bare `task-07-x/research/` stub wasn't recognized, so init produced `task-08` instead of reusing `07`).

**Setup:**
```swift
let tempDir = makeTempProjectDir()
makeDir(tempDir + "/docs/tasks/task-07-native-saha-planning/research") // no README, no scaffold
```

**Input:**
```json
{ "name": "native-saha-planning", "cwd": "<tempDir>" }
```

**Expected Output:**
```json
{ "createdPath": "docs/tasks/task-08-native-saha-planning" }
```

**Assertions:**
- Script does not error or collide; produces the next number regardless of stub folders
- This is documented behavior (asserted, not "fixed") — the app's consuming code must not assume folder numbers are gap-free

---

### TC-INT-003: Non-zero exit surfaces a structured error

**Description:** US-001 edge case 2.

**Setup:**
```swift
// point at a read-only docs/tasks/ to force a script failure
```

**Expected Output:**
```json
{ "exitCode": 1 }
```

**Assertions:**
- The app's wrapper surfaces a typed error (not a silently-ignored non-zero exit)
- No `BoardCard` creation proceeds past this point

## Data Fixtures

```swift
func makeTempProjectDir() -> URL { /* creates a throwaway dir with docs/tasks/ */ }
```
