# US-005: Native markdown + mermaid doc viewer

**Priority:** Must Have
**Status:** Draft
**Persona:** Kanban app user reviewing planning docs
**Estimated Complexity:** L

## User Story

As a **kanban app user**,
I want to **read the saha doc for the current planning step rendered natively (tables, checkboxes, headers, and mermaid diagrams where present)**,
So that **I can review planning artifacts without opening a separate editor or a webview**.

## Acceptance Criteria

1. **Given** the current planning step's artifact file
   **When** the doc viewer pane renders it
   **Then** GFM markdown (tables, task-lists, headers) renders via swift-markdown → `NSAttributedString` → `NSTextView`, styled from `BoardTheme` tokens

2. **Given** a doc contains a mermaid code block and `mmdc` is installed
   **When** the viewer encounters it
   **Then** it renders the block to an image (cached by content hash) and shows it inline

3. **Given** `mmdc` is not installed
   **When** a mermaid block is encountered
   **Then** it degrades to a syntax-highlighted code block with an install hint, without erroring the whole render

4. **Given** the underlying file changes (e.g. mid-planning-session edit)
   **When** the file-watcher fires
   **Then** the doc viewer re-renders live [x] (iteration 5)

## Edge Cases

1. **Very large doc (long implementation plan)**
   - Trigger: multi-thousand-line file
   - Expected behavior: scrolls smoothly in `NSTextView`, no full re-parse per keystroke/scroll

2. **Malformed markdown table**
   - Trigger: broken pipe syntax
   - Expected behavior: falls back to a monospace/plain rendering of that block rather than crashing

## Technical Notes

No `WKWebView` anywhere — hard constraint carried over from task-05. This is the one genuinely new rendering capability in the codebase; the walker (markdown AST → NSAttributedString) should be a pure function, independently testable.

## Dependencies

- **Requires:** US-004 (lives in the doc viewer pane)
- **Enables:** none additional

## Questions

- [ ] Is degraded (code-block) mermaid rendering acceptable for v1, or should mermaid support be deferred entirely? (open question from task description)

## Related

- Task: ../task-description.md
- Research: ../research/native-planning-proposal.md
- Design Decision: no-webview confirmation (design-decisions/, still to author)
