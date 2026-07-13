# Phase 04: Native document viewer

**Status:** Test Critique (partial implementation)
**Estimated Effort:** L
**Dependencies:** Phase 03

## Execution Progress

| Stage | Status | Last Updated | Notes |
|-------|--------|--------------|-------|
| Implementation | ⚠️ Partial | 2026-07-06 iter 1 | Step 1 in progress (NativeMarkdownRenderer added); Steps 2–3 pending (full GFM and Mermaid CLI paths, verification flow) |
| Test Critique | ✅ Passed | 2026-07-06 iter 1 | score B; flagged real artifact and mmdc coverage incomplete; WKWebView non-regression check noted |
| QA Verification | ⚠️ Partial | 2026-07-06 iter 1 | swift test 213/213 green; rendering coverage to be verified alongside Phase 03 fixes |
| Code Quality | ✅ Passed | 2026-07-06 iter 1 | 0 blocking issues |
| DoD Check | ⏳ Pending | - | Blocked by Phase 03 AC3/AC4 resolution and Phase 04 step completion |

## Objective

Replace the raw artifact placeholder with a themed native markdown viewer,
support optional cached Mermaid images, and verify the complete planning flow.

## Scope

### Stories Included

| Story | Priority | Complexity | Status |
|-------|----------|------------|--------|
| US-005 | Must Have | L | [ ] |

### Out of Scope (Deferred)

- Web-based rendering.
- Editing planning documents inside the viewer.
- Requiring Mermaid CLI installation.

## Implementation Steps

### Step 1: Add the native markdown walker ⚠️ (iteration 1, in progress)

**Description:** Parse GFM with `swift-markdown` and walk its AST into a themed
`NSAttributedString` displayed by a read-only `NSTextView`.

**Files to Create/Modify:**
- `app/Package.swift` - add and pin the `swift-markdown` package dependency
- `app/Sources/GhostlingApp/NativeMarkdownRenderer.swift` - AST walker and attributed output ✓
- `app/Sources/GhostlingApp/PlanningDocumentView.swift` - replace raw placeholder
- `app/Sources/GhostlingApp/BoardTheme.swift` - add document typography/table/code tokens
- `app/Tests/GhostlingAppTests/PlanningModeTests.swift` - rendering integration (noted in iteration 1)

**Technical Notes:**
- AppKit types keep this renderer in `GhostlingApp`; factor pure intermediate
  transforms into `GhostlingCore` only if they do not import AppKit.
- Render malformed blocks locally as plain or monospace text; never fail the
  complete document.
- Avoid reparsing during scrolling; rerender only when selection, theme, or the
  shared planning-state/file callback changes.

**Acceptance Criteria (US-005 AC1–3):**
- [ ] Headers, GFM tables, task lists, and code blocks have distinct native styling. (test coverage flagged incomplete)
- [ ] Malformed content degrades locally and the rest of the document remains visible.
- [x] The view is read-only, selectable, scrollable, and contains no `WKWebView`. (verified in iteration 1)

**Tests:**
- TC-UNIT-010, TC-UNIT-011, TC-UNIT-012, TC-UNIT-013 (test coverage to expand)
- TC-E2E-015 (pending Phase 03 fix)

---

### Step 2: Add optional cached Mermaid rendering

**Description:** Introduce an injected renderer that invokes `mmdc` when
available, caches by content hash, and embeds output as text attachments.

**Files to Create/Modify:**
- `app/Sources/GhostlingApp/MermaidRenderer.swift` - availability check, safe process invocation, cache, and image loading
- `app/Sources/GhostlingApp/MarkdownDocRenderer.swift` - Mermaid fence handling and fallback
- `app/Tests/GhostlingAppTests/MermaidRendererTests.swift` - fake process and cache tests

**Technical Notes:**
- Pass Mermaid source through stdin or a controlled temporary file, never shell interpolation.
- Cache successful output by source plus renderer/theme version; clean temporary files.
- When unavailable or failing, show raw source plus one install hint.

**Acceptance Criteria:**
- [ ] Available `mmdc` output appears inline and identical source is not rerun.
- [ ] Missing, failing, or invalid `mmdc` output degrades to a code block without crashing.

**Tests:**
- TC-UNIT-014, TC-UNIT-015
- TC-E2E-016

---

### Step 3: Verify the integrated workflow and non-regression constraints

**Description:** Exercise task creation through live planning updates, document
selection/rendering, command suggestion, and return to board.

**Files to Create/Modify:**
- `app/Tests/GhostlingAppTests/NativePlanningFlowE2ETests.swift` - assembled deterministic flow
- `app/Tests/GhostlingAppTests/PlanningModeTests.swift` - large-document and repeated lifecycle coverage
- `docs/tasks/task-08-native-saha-planning/README.md` - update status after verified implementation

**Technical Notes:**
- Use temporary task folders and fake process runners; do not spend provider quota.
- Add a source/build assertion that the planning viewer does not link or instantiate `WKWebView`.
- Verify the existing drill-in and board suites alongside the new flow.

**Acceptance Criteria:**
- [ ] All 16 specified E2E cases and supporting unit/integration cases pass.
- [ ] A real multi-section task artifact renders and refreshes after an external write.
- [ ] Planning Mode remains suggest-only and board/drill-in behavior does not regress.

**Tests:**
- All cases in `test-specs/e2e/card-creation-flow.md`
- All cases in `test-specs/e2e/planning-mode-flow.md`

## Definition of Done

- [ ] US-005 acceptance criteria and task-level success criteria pass. (BLOCKED: Phase 03 Step 3 AC3/AC4 gap, rendering tests noted incomplete)
- [x] All Swift test suites affected by the four phases pass. (213/213 green, iteration 1)
- [ ] Saha test suites pass (Phase 02 Step 3 still pending).
- [x] Test critique passed (score B, iteration 1; flags noted for rendering/Mermaid coverage expansion).
- [x] Swift build warnings and blocking lint findings resolved (0 blocking issues, iteration 1).
- [x] No `WKWebView`, auto-dispatch, or quota-spending E2E exists (verified iteration 1).
- [ ] Fast polling path constraint verified (Phase 02 complete, iteration 1).
- [ ] QA verification and final DoD check pass (awaiting Phase 03 fixes and Phase 04 Step 2–3 completion).

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| GFM tables are awkward in attributed text | High | Medium | Use a bounded native table representation with local monospace fallback |
| `mmdc` process work blocks the UI | Medium | High | Render off the main thread and publish immutable results on the main actor |
| Large documents rerender too often | Medium | Medium | Share watcher callback, debounce, cache, and avoid scroll-triggered parsing |
| Dependency version changes rendering behavior | Low | Medium | Pin `swift-markdown` and test output structure rather than pixels |

## Rollback Plan

1. Disable Mermaid rendering while retaining its code-block fallback.
2. Restore the raw read-only document pane if native markdown causes instability;
   Planning Mode remains usable.

## Related

- **Stories:** US-005
- **Decisions:** Pending no-webview and Mermaid-degradation decisions
- **Contracts:** `markdown-doc-renderer.md`
- **Tests:** `unit/markdown-walker.md`, `e2e/planning-mode-flow.md`
