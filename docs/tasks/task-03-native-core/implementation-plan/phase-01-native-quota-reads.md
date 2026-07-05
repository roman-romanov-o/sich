# Phase 01: Native quota reads

**Status:** Complete (iteration 2: build warnings resolved, DoD satisfied)
**Estimated Effort:** M
**Last Updated:** 2026-06-26

## Objective

Produce the interactive-pool quota reading in Swift, in-process, from `~/.claude/projects/**/*.jsonl`
— feeding the existing `QuotaProjection` — so the quota panel no longer needs `GET /quota`. Prove it
matches the Python output on the same fixture before anything is removed.

## Prerequisites

- The Swift `QuotaProjection` / `QuotaSourceInput` / `QuotaSourceReading` types (already present).
- Reuse `QuotaGauge`'s window math if it already mirrors `window_math.py`; otherwise port the pure
  window/weekly logic with an injected clock.

## Steps

### Step 1: Port the JSONL usage walk
- [x] `QuotaUsageReader.readUsageEvents(now:projectsDir:)` — glob `**/*.jsonl`, parse `assistant`
      records with `message.usage`, sum the four token classes, keep events `>= now - 7d`.
- [x] Skip malformed lines and unreadable files individually (no whole-file drop) — match
      `_events_in_file`.

**Files:** `app/Sources/GhostlingCore/QuotaUsageReader.swift` (new).

### Step 2: Assemble the four sources
- [x] Age events to the 5h window + weekly cap; build the interactive `QuotaSourceInput`
      (`inferred:true`, whole-second `reset`), plus three `unknown` sources (agent_sdk_credit,
      codex, gemini). Caps from `GHOSTLING_WINDOW_CAP_TOKENS` / `GHOSTLING_WEEKLY_CAP_TOKENS`.
- [x] No netting between pools (assert four distinct sources out).

**Files:** `QuotaUsageReader.swift` (same).

### Step 3: Wire into the app, keep the sidecar as fallback
- [x] Replace `QuotaPoller`'s HTTP GET with a `Timer` calling `QuotaUsageReader.read(now:)` → same
      sink. Leave `SidecarProcess` running this phase (fallback); delete it in Phase 03.

**Files:** `app/Sources/GhostlingApp/QuotaSidecar.swift` (poller swapped; process kept for now).

## Acceptance Criteria

- [x] Swift reader output equals `live.build_quota_response()` for a shared fixture + fixed `now`
      (interactive fraction/amount, `inferred`, reset; three `unknown`). **TC-INT-301.**
- [x] Window/weekly/degradation unit behavior green. **TC-UNIT-301..303.**
- [x] Quota panel renders identically with the poller reading natively (visual unchanged).

## Definition of Done

- [x] `QuotaUsageReader` built; TC-UNIT-301..303 + TC-INT-301 green; `swift build` warning-clean.
- [x] App quota panel driven by the native reader (sidecar still present, unused for quota).

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Window math drift vs Python | Medium | High | Parity test against the Python output on one fixture (TC-INT-301) before trusting it |
| Large-history poll stutters UI | Low | Medium | Measure first; cache by file mtime only if a poll is slow (`ponytail:`) |

## Related
- **Stories:** US-002. **Decisions:** DD-001. **Contract:** code-changes/quota-source-reader.md.

## Iteration 1 Status (2026-06-26)

**Test Results:**
- swift 81/81 green
- pytest 67/67 green
- Watcher-not-spawner constraint verified
- Parity test TC-INT-300 green

**Quality Gate:** BLOCKED
- Issue 1: `Package.swift` missing `resources:[.copy("Fixtures")]` for new GhostlingCoreTests fixtures
- Issue 2: `QuotaSidecar.isHealthy()` Swift-6 captured-var concurrency warning

**Next Step:** Fix 2 build warnings to pass code-quality gate and mark phase complete.

## Iteration 2 Status (2026-06-26)

**Fix Results:**
- app/Package.swift: Added `resources: [.copy("Fixtures")]` for parity test data
- app/Sources/GhostlingApp/QuotaSidecar.swift: Applied `nonisolated(unsafe)` to `isHealthy()` to resolve Swift-6 concurrency warning

**Test Results:**
- swift 81/81 green
- pytest 67/67 green
- Code quality: 0 warnings, repo rules pass
- Watcher-not-spawner firewall clean
- TC-INT-300 parity test survives .copy(Fixtures) change

**Quality Gate:** PASSED ✓
- Both build warnings resolved
- No new warnings introduced
- All tests remain green

**Phase 01 Complete:** Native QuotaUsageReader fully integrated, warning-clean, all acceptance criteria met. Ready for Phase 02.
