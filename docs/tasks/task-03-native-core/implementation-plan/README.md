# Implementation Plan — task-03

**Strategy:** strangler-fig. Build each native path **alongside** the still-running sidecar, prove
parity in `swift test`, then cut over and delete. The sidecar stays as a live fallback through
Phase 02 so nothing on the board goes dark mid-port.

| Phase | Title | Status | Gist |
|-------|-------|--------|------|
| [01](phase-01-native-quota-reads.md) | Native quota reads | Complete (iter 2) | Port JSONL walk + window aging → `QuotaUsageReader`; feed `QuotaProjection` in-process |
| [02](phase-02-native-hook-sink.md) | Native hook sink | Complete (iter 3) | Forwarder `curl`→append; `HookEventTail` + normalize + reconcile |
| [03](phase-03-cutover-and-delete.md) | Cutover + delete | Machine-complete (iter 4) | Flip app off HTTP; **delete `src/mission_control` + `tests/`**; single-binary DoD; visual AC pending |
| [04](phase-04-multitool-unlock.md) | Multi-tool unlock (stretch) | Pending | Cursor/Codex/Gemini installers + event maps |

**Critical path:** 01 → 02 → 03. Phase 01 and 02 are independent of each other (quota vs hooks)
and may proceed in parallel; both must be green before 03. Phase 04 is optional, after 03.

**Integrity gate (US-004 AC1):** Phase 03 deletes nothing until the `test-specs` parity matrix is
fully bound to green `swift test` cases. `execution-dod-native` enforces this (dual baseline: pytest
count AND swift count, so test deletion in either runtime is caught).
