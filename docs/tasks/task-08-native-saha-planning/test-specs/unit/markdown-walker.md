# Unit Test Spec: Markdown → NSAttributedString walker

**File:** `app/Sources/GhostlingCore/MarkdownDocRenderer.swift`
**Priority:** High
**Status:** Draft

## Overview

Pure-function tests for swift-markdown AST → `NSAttributedString` conversion (US-005) — exactly the kind of "tricky, isolated logic" this project's unit-test philosophy reserves unit tests for. Complements TC-E2E-015/016 (which check the rendered result inside the real doc-viewer pane); these tests check the conversion function alone, with many more edge-case inputs than is practical at the E2E level.

## Test Cases

### TC-UNIT-010: render - GFM table

**Input:** `render("| a | b |\n|---|---|\n| 1 | 2 |")`

**Expected:** attributed string contains a table-styled region with cells "a", "b", "1", "2" (structural check: text extraction + range count, not pixel layout)

---

### TC-UNIT-011: render - task-list checkboxes

**Input:** `render("- [ ] todo\n- [x] done")`

**Expected:** output contains "☐" immediately before "todo" and "☑" immediately before "done"

---

### TC-UNIT-012: render - header hierarchy gets distinct styling

**Input:** `render("# H1\n## H2")`

**Expected:** the two resulting attributed ranges have different font/size attributes pulled from `BoardTheme`

---

### TC-UNIT-013: render - malformed table falls back to plain text

**Input:** `render("| broken | table\nno closing pipes")`

**Expected:** does not throw; falls back to monospace/plain rendering of that block, rest of doc (if any) still renders

---

### TC-UNIT-014: render - mermaid block with renderer available

**Input:** `render("```mermaid\ngraph TD; A-->B\n```", mermaidRenderer: fakeSuccess)`

**Expected:** an image attachment is embedded at that block's location

---

### TC-UNIT-015: render - mermaid block with renderer unavailable

**Input:** `render("```mermaid\ngraph TD; A-->B\n```", mermaidRenderer: nil)`

**Expected:** the raw mermaid source renders as a code block with an install-hint string appended; no throw

## Mocks Required

- `mermaidRenderer` - injectable seam so mermaid success/absence is tested without shelling out to real `mmdc` in unit tests (integration/E2E already covers the real shell-out path via TC-E2E-016)
