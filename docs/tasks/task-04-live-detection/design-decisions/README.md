# Design Decisions

Architectural decisions and their rationale (ADR format).

## Contents

| ID | Title | Status | Date |
|----|-------|--------|------|
| DD-001 | Use cmux as reference impl, do not fork | Accepted | 2026-07-01 |
| DD-002 | Event delivery — file-watch the sink, not a socket | Accepted | 2026-07-01 |
| DD-003 | Reconciliation — timestamp-first (`updatedAt`) ordering + wired JSONL fallback + deterministic close | Accepted | 2026-07-01 |

## Decision Log

### Accepted
- **DD-001** — cmux is our architecture one level ahead but has no board/quota; a fork rebuilds our differentiator for zero foundational gain, so we port patterns instead.
- **DD-002** — single-process app doesn't need cmux's cross-process socket; a `DispatchSource` file-watch + incremental read hits ≤250ms with no new IPC surface.
- **DD-003** — order the reconciler by the store's existing `updatedAt`/`timestamp` (newest-wins), wire the dead `JSONLNormalizer` fallback, and close deterministically on `sessionEnd`. Attention is already first-class via `permissionRequest`; `ppid`/workspace-index (cmux's heavier primitives) are **deferred** — no producer, not needed for any AC.

### Proposed
_None._

### Deprecated
_None._

## Note

Statuses are marked **Accepted** because the operator delegated the calls
("do all that for me"). They remain open to reversal in review — each records
its options and the cost of reversal.
