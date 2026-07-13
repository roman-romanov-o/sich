# Code Change: `saha plan-status --json`

**Type:** CLI contract (process stdout, not HTTP)
**Command:** `saha plan-status <task-id> [--json]`
**Repo:** sahaidachny (external to this app)
**Status:** Draft

## Overview

New saha CLI command wrapping the existing `saha/verification/checker.py::TaskVerifier`. Consumed by this app's `PlanningStateReader` (US-003) as its preferred state source, falling back to marker-scraping when unavailable (older saha version, or command missing). Without `--json`, behaves as today (human-readable); `--json` is additive, non-breaking.

## Invocation

```
saha plan-status task-08-native-saha-planning --json
```

**Working directory:** must be run from (or given) the project root containing `docs/tasks/`.

## Success Output (stdout, exit 0)

```json
{
  "task_id": "task-08-native-saha-planning",
  "checks": [
    { "name": "research", "status": "passed" },
    { "name": "task_description", "status": "passed" },
    { "name": "user_stories", "status": "passed" },
    { "name": "design_decisions", "status": "failed" },
    { "name": "code_changes", "status": "failed" },
    { "name": "test_specs", "status": "failed" },
    { "name": "implementation_plan", "status": "failed" },
    { "name": "verify", "status": "failed" }
  ],
  "next_step": "design_decisions",
  "complete": false
}
```

**Field notes:**
- `checks[].name` values are the fixed 8-entry set matching US-003's step→command table (research, task_description, user_stories, design_decisions, code_changes, test_specs, implementation_plan, verify) — order is significant, always emitted in pipeline order regardless of completion state.
- `next_step` is `null` when `complete: true`.
- `complete` is `true` iff every check's status is `"passed"`.

## Error Output (non-zero exit)

- Unknown/unresolvable `task-id`: exit 2, stderr message, **no stdout emitted** (never partial/malformed JSON).
- Missing `--json` on a saha version too old to support it: not applicable — this is the new command itself; callers detect absence via a non-zero exit / "unknown flag" stderr message from the *old* binary, which is the fallback signal `PlanningStateReader` uses (see planning-state-reader.md).

## Related

- **Stories:** US-006, US-003 (consumer)
- **Test Specs:** test-specs/integration/saha-plan-status-json.md, test-specs/integration/planning-state-file-watch.md
