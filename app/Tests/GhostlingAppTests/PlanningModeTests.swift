import AppKit
import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

@MainActor
struct PlanningModeTests {
    /// Structure + the back affordance driven by a REAL `mouseDown` through the
    /// window's hit-test (the interaction-AC binding rule — never `performClick`).
    @Test func exposesThreePanesAndReturnNavigationViaRealClick() throws {
        let view = PlanningModeView(reader: PlanningStateReader())
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        var returned = false
        view.onReturn = { returned = true }
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()

        #expect(view.stepperPane.superview != nil)
        #expect(view.documentPane.superview != nil)
        #expect(view.terminalContainer.superview != nil)

        let pill = view.returnButton
        let center = pill.convert(NSPoint(x: pill.bounds.midX, y: pill.bounds.midY), to: nil)
        let hit = try #require(view.hitTest(center))
        #expect(hit === pill)
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        window.sendEvent(click)
        #expect(returned)
    }

    @Test func rendererHandlesNativeMarkdownAndMermaidFallback() {
        let markdown = "# Heading\n| A | B |\n- [x] done\n```swift\nlet x = 1\n```\n```mermaid\ngraph TD\n```"
        let rendered = NativeMarkdownRenderer().render(markdown)
        #expect(rendered.string.contains("Heading"))
        // NSTextTable cells carry no pipe glyphs — assert the cell text survives instead.
        #expect(rendered.string.contains("A") && rendered.string.contains("B"))
        #expect(rendered.string.contains("☑") && rendered.string.contains("done"))
        #expect(rendered.string.contains("let x = 1"))
        #expect(rendered.string.contains("graph TD"))
        #expect(rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil)
        #expect(NSClassFromString("WKWebView") == nil || !String(describing: type(of: rendered)).contains("WK"))
    }

    @Test func reviewRailSelectsArtifactAndTerminalExpandsFromStatusRail() throws {
        let folder = try planningFixture()
        let view = PlanningModeView(reader: PlanningStateReader())
        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)

        view.show(card: BoardCard(
            sessionID: "planning", projectDir: folder.path, agent: .claude,
            flow: .a, state: .idle, taskFolder: folder.path
        ))
        view.layoutSubtreeIfNeeded()

        #expect(view.selectedStep == .userStories)
        #expect(view.selectedArtifactURL?.lastPathComponent == "US-001-first.md")
        #expect(view.reviewPane.arrangedSubviews.count == 2)

        let second = try #require(view.reviewPane.arrangedSubviews
            .compactMap { $0 as? PlanningReviewButton }
            .first { $0.url?.lastPathComponent == "US-002-second.md" })
        try click(second, in: window, root: view)

        #expect(view.selectedArtifactURL?.lastPathComponent == "US-002-second.md")
        #expect(view.documentHeaderField.stringValue == "US-002-second.md")
        // The doc pane must have a non-zero-width text container: without the canonical
        // NSTextView-in-NSScrollView sizing (widthTracksTextView + isVerticallyResizable)
        // every glyph lays out into a zero-width container off-screen — the blank pane bug.
        #expect((view.documentPane.textContainer?.size.width ?? 0) > 0)
        #expect((view.documentPane.textStorage?.length ?? 0) > 0)
        #expect(!view.terminalRail.isHidden)
        #expect(view.terminalContainer.superview?.isHidden == true)
        #expect(view.documentPane.textContainerInset.width >= 72)

        try click(view.terminalToggle, in: window, root: view)
        #expect(view.terminalRail.isHidden)
        #expect(view.terminalContainer.superview?.isHidden == false)
    }

    @Test func rendererUsesSuccessfulMermaidImage() {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        let rendered = NativeMarkdownRenderer(renderMermaid: { _ in image })
            .render("```mermaid\ngraph TD\n```")
        #expect(rendered.containsAttachments(in: NSRange(location: 0, length: rendered.length)))
        #expect(!rendered.string.contains("graph TD"))
    }

    // TC-UNIT-015 — mermaid unavailable degrades to a code block plus install hint.
    @Test func mermaidWithoutRendererShowsSourceAndInstallHint() {
        let rendered = NativeMarkdownRenderer(renderMermaid: { _ in nil })
            .render("```mermaid\ngraph TD; A-->B\n```")
        #expect(rendered.string.contains("graph TD; A-->B"))
        #expect(rendered.string.lowercased().contains("mmdc"))
        #expect(!rendered.containsAttachments(in: NSRange(location: 0, length: rendered.length)))
    }

    // TC-UNIT-012 — header levels get distinct font styling.
    @Test func headerHierarchyGetsDistinctStyling() {
        let rendered = NativeMarkdownRenderer().render("# H1\n## H2")
        let h1Range = (rendered.string as NSString).range(of: "H1")
        let h2Range = (rendered.string as NSString).range(of: "H2")
        let h1Font = rendered.attribute(.font, at: h1Range.location, effectiveRange: nil) as? NSFont
        let h2Font = rendered.attribute(.font, at: h2Range.location, effectiveRange: nil) as? NSFont
        #expect(h1Font != nil && h2Font != nil)
        #expect(h1Font?.pointSize != h2Font?.pointSize)
    }

    @Test func documentReaderConstrainsReadableLineWidthWithInsets() {
        let view = PlanningModeView(reader: PlanningStateReader())
        view.frame = NSRect(x: 0, y: 0, width: 1800, height: 900)
        view.layoutSubtreeIfNeeded()
        let readableWidth = view.documentPane.bounds.width - view.documentPane.textContainerInset.width * 2
        #expect(readableWidth <= view.documentPane.maximumReadableWidth + 1)
    }

    @Test func documentReaderUsesDistinctDocumentSurface() {
        let view = PlanningModeView(reader: PlanningStateReader())
        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        view.layoutSubtreeIfNeeded()

        #expect(view.documentPane.backgroundColor.isEqual(BoardTheme.documentSurface))
        #expect(!view.documentPane.backgroundColor.isEqual(BoardTheme.canvas))
    }

    @Test func sahaFieldLabelsReceiveDistinctStyling() {
        let r = NativeMarkdownRenderer().render("Date: today\nStatus: complete\nEvidence: one\nImplication: two")
        let s = r.string as NSString
        let evidence = s.range(of: "Evidence:")
        let date = s.range(of: "Date:")
        let body = s.range(of: "one")
        let evidenceColor = r.attribute(.foregroundColor, at: evidence.location, effectiveRange: nil) as? NSColor
        let bodyColor = r.attribute(.foregroundColor, at: body.location, effectiveRange: nil) as? NSColor
        let evidenceFont = r.attribute(.font, at: evidence.location, effectiveRange: nil) as? NSFont
        let dateFont = r.attribute(.font, at: date.location, effectiveRange: nil) as? NSFont
        #expect(evidenceColor != bodyColor)
        #expect(evidenceFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(dateFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test func documentTypographyKeepsHeadingsInsideToolScale() {
        let rendered = NativeMarkdownRenderer().render("# H1\n\nBody text")
        let s = rendered.string as NSString
        let h1Range = s.range(of: "H1")
        let bodyRange = s.range(of: "Body text")
        let h1Font = rendered.attribute(.font, at: h1Range.location, effectiveRange: nil) as? NSFont
        let bodyFont = rendered.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont

        #expect((h1Font?.pointSize ?? 0) <= 24)
        #expect((h1Font?.pointSize ?? 0) > (bodyFont?.pointSize ?? 0))
    }

    @Test func fencedCodeBlocksGetReadablePadding() {
        let rendered = NativeMarkdownRenderer().render("```swift\nlet x = 1\n```")
        #expect(rendered.string.contains("  let x = 1"))
        let codeRange = (rendered.string as NSString).range(of: "let x = 1")
        let background = rendered.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor
        #expect(background != nil)
    }

    // Inline markdown is parsed (no literal `**`/backticks leak) and mapped to real
    // bold / italic / mono runs — the core "text is readable now" fix.
    @Test func inlineEmphasisStripsMarkersAndStylesRuns() {
        let r = NativeMarkdownRenderer().render("Plain **bold** and *italic* and `code` here.")
        let s = r.string
        #expect(!s.contains("**") && !s.contains("`"))
        #expect(s.contains("bold") && s.contains("italic") && s.contains("code"))
        func font(_ needle: String) -> NSFont? {
            r.attribute(.font, at: (s as NSString).range(of: needle).location,
                        effectiveRange: nil) as? NSFont
        }
        #expect(font("bold")?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(font("Plain")?.fontDescriptor.symbolicTraits.contains(.bold) != true)
        #expect(font("italic")?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        #expect(font("code")?.isFixedPitch == true)
    }

    // A horizontal rule renders as a native divider, not literal dashes.
    @Test func horizontalRuleRendersAsDivider() {
        let r = NativeMarkdownRenderer().render("above\n\n---\n\nbelow")
        #expect(!r.string.contains("---"))
        #expect(r.string.contains("─"))
        #expect(r.string.contains("above") && r.string.contains("below"))
    }

    // TC-UNIT-013 — a malformed table degrades to text without dropping the rest.
    @Test func malformedTableDegradesWithoutLosingTheRestOfTheDoc() {
        let rendered = NativeMarkdownRenderer()
            .render("| broken | table\nno closing pipes\n\n# Still Here")
        #expect(rendered.string.contains("broken"))
        #expect(rendered.string.contains("Still Here"))
    }

    // A source-path code span becomes a `ghostling-file:` link; a plain identifier stays code.
    @Test func filePathCodeSpansBecomeFileLinks() {
        let r = NativeMarkdownRenderer().render("See `app/Sources/Foo.swift:48-97` but `resetText` stays.")
        let s = r.string as NSString
        let pathRange = s.range(of: "app/Sources/Foo.swift:48-97")
        let link = r.attribute(.link, at: pathRange.location, effectiveRange: nil) as? URL
        #expect(link?.scheme == "ghostling-file")
        let idRange = s.range(of: "resetText")
        #expect(r.attribute(.link, at: idRange.location, effectiveRange: nil) == nil)

        // Real docs write multi-range suffixes like `:38-39,52` — those must still link.
        let multi = NativeMarkdownRenderer().render("At `app/Sources/GhostlingCore/QuotaGauge.swift:38-39,52`.")
        let ms = multi.string as NSString
        let mr = ms.range(of: "app/Sources/GhostlingCore/QuotaGauge.swift:38-39,52")
        let mlink = multi.attribute(.link, at: mr.location, effectiveRange: nil) as? URL
        #expect(mlink?.scheme == "ghostling-file")
    }

    // The reader opens a referenced source file in the same pane, then a REAL click on the
    // back pill (never `performClick`) restores the doc — the "go back" interaction AC.
    @Test func opensReferencedFileAndReturnsViaRealBackClick() throws {
        let folder = try planningFixtureWithSource()
        let view = PlanningModeView(reader: PlanningStateReader())
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.show(card: BoardCard(
            sessionID: "planning", projectDir: folder.path, agent: .claude,
            flow: .a, state: .idle, taskFolder: folder.path))
        view.layoutSubtreeIfNeeded()

        view.openFileRef("src/Sample.swift:2")
        #expect(view.isViewingFile)
        #expect(!view.docBackButton.isHidden)
        #expect(view.documentPane.string.contains("let marker = 42"))

        try click(view.docBackButton, in: window, root: view)
        #expect(!view.isViewingFile)
        #expect(view.docBackButton.isHidden)
        #expect(!view.documentPane.string.contains("let marker = 42"))
    }

    // saha/v2: the rail lists stories from progress.yaml with display titles, a REAL
    // click selects by reviewKey (several rows share model/stories.c4 as their url),
    // and the story pane overlays the doc area for the selected LikeC4 view.
    @Test func v2RailListsStoriesAndClickSelectsByReviewKey() throws {
        let folder = try v2Fixture()
        let view = PlanningModeView(reader: PlanningStateReader())
        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.show(card: BoardCard(
            sessionID: "planning", projectDir: folder.path, agent: .claude,
            flow: .a, state: .idle, taskFolder: folder.path))
        view.layoutSubtreeIfNeeded()

        #expect(view.selectedStep == .userStories)
        #expect(view.selectedReviewKey == "us-001-flow")
        #expect(view.documentHeaderField.stringValue == "US-001 · First story")
        #expect(!view.storyPane.isHidden)

        let buttons = view.reviewPane.arrangedSubviews
            .compactMap { $0 as? PlanningReviewButton }
        #expect(buttons.count == 2)
        let second = try #require(buttons.first { $0.reviewKey == "us-002-flow" })
        try click(second, in: window, root: view)

        #expect(view.selectedReviewKey == "us-002-flow")
        #expect(view.documentHeaderField.stringValue == "US-002 · Second story")
        #expect(!view.storyPane.isHidden)
    }

    private func v2Fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        // model/ stays empty of .c4 files so the story pane resolves to .noSources —
        // no likec4 build process spawns during the test.
        let model = folder.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try """
        format: saha/v2
        task: task-99-fixture
        title: Fixture task
        status: planning
        planning:
          research:         {status: done, artifacts: []}
          task_description: {status: done, views: [task-context]}
          user_stories:     {status: in_progress, views: [us-001-flow, us-002-flow]}
        stories:
          - {id: US-001, title: First story, view: us-001-flow, status: ready}
          - {id: US-002, title: Second story, view: us-002-flow, status: draft}
        """.write(to: folder.appendingPathComponent("progress.yaml"), atomically: true,
                  encoding: .utf8)
        return folder
    }

    private func planningFixtureWithSource() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let research = folder.appendingPathComponent("research", isDirectory: true)
        let src = folder.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "| Research | In Progress |".write(
            to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "# Doc\n\nSee `src/Sample.swift:2`.".write(
            to: research.appendingPathComponent("01-doc.md"), atomically: true, encoding: .utf8)
        try "// header\nlet marker = 42\n".write(
            to: src.appendingPathComponent("Sample.swift"), atomically: true, encoding: .utf8)
        return folder
    }

    private func click(_ target: NSView, in window: NSWindow, root: NSView) throws {
        let center = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        let hit = try #require(root.hitTest(center))
        #expect(hit === target)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        window.sendEvent(event)
    }

    private func planningFixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stories = folder.appendingPathComponent("user-stories", isDirectory: true)
        try FileManager.default.createDirectory(at: stories, withIntermediateDirectories: true)
        try """
        | Research | Done |
        | Task Description | Done |
        | User Stories | In Progress |
        | Design Decisions | Pending |
        """.write(to: folder.appendingPathComponent("README.md"), atomically: true,
                  encoding: .utf8)
        try "# US-001\n\nFirst story".write(
            to: stories.appendingPathComponent("US-001-first.md"), atomically: true,
            encoding: .utf8
        )
        try "# US-002\n\nSecond story".write(
            to: stories.appendingPathComponent("US-002-second.md"), atomically: true,
            encoding: .utf8
        )
        return folder
    }
}
