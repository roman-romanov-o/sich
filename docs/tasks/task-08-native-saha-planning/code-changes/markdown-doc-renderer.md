# Code Change: `MarkdownDocRenderer`

**Type:** Internal Swift interface
**Module:** GhostlingCore / GhostlingApp
**Status:** Draft

## Overview

Converts a saha markdown artifact into an `NSAttributedString` for display in a read-only `NSTextView`, using apple/swift-markdown for GFM parsing. No `WKWebView` anywhere (hard constraint carried from task-05, reconfirmed by explicit user instruction this session). Mermaid code fences render via an optional external `mmdc` shell-out, injected as a seam so it's swappable/mockable and never a hard dependency.

## Interface

```swift
protocol MermaidRendering {
    // returns nil if mmdc is unavailable or rendering fails.
    // Implementations own their own content-hash cache (US-005 AC2): given the
    // same `source` string, a cache hit skips the `mmdc` shell-out entirely.
    func renderToImage(source: String) -> NSImage?
}

struct MarkdownDocRenderer {
    let theme: BoardTheme
    let mermaidRenderer: MermaidRendering? // nil => always degrade to code block

    func render(markdown: String) -> NSAttributedString
}
```

## Behavior

- Headers get distinct font/size from `BoardTheme` tokens per level.
- GFM tables render as an aligned/styled table region; a malformed table falls back to a plain/monospace block for that section only — one bad block never fails the whole render.
- Task-list markers `- [ ]` / `- [x]` render as `☐` / `☑` glyphs immediately preceding their text.
- ` ```mermaid ` fences: if `mermaidRenderer` is non-nil and returns an image, embed it as an `NSTextAttachment` at that block's position; otherwise render the raw source as a code block with an appended install-hint line (e.g. "install mermaid-cli (`mmdc`) to render this diagram").
- Never throws; any unparseable block degrades to plain text rather than aborting the whole document.
- Re-invoked whenever the currently-selected doc's `PlanningStateReader.onStateChanged` fires for the bound task folder — the viewer subscribes to that same callback (see planning-state-reader.md) rather than running its own file-watch, so US-004's live-update requirement carries through without a second poll loop.

## Related

- **Stories:** US-005
- **Test Specs:** test-specs/unit/markdown-walker.md, test-specs/e2e/planning-mode-flow.md (TC-E2E-015/016)
