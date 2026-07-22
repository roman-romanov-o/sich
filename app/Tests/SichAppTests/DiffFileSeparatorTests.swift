import AppKit
import SichCore
import Testing

@testable import SichApp

/// The diff pane renders every file of a turn into ONE document, so the only thing
/// telling a reader "a new file starts here" is the header band. The band used to be
/// a single faint wash on a mono row, which vanished among 24 files of near-identical
/// rows — these assert the four cues that replaced it are actually on the render path.
@MainActor
@Suite("Diff pane file separators")
struct DiffFileSeparatorTests {

    private let twoFileDiff = """
        diff --git a/app/Sources/Foo.swift b/app/Sources/Foo.swift
        --- a/app/Sources/Foo.swift
        +++ b/app/Sources/Foo.swift
        @@ -1,2 +1,2 @@
         let kept = 1
        -let old = 2
        +let new = 3
        diff --git a/Tests/BarTests.swift b/Tests/BarTests.swift
        --- a/Tests/BarTests.swift
        +++ b/Tests/BarTests.swift
        @@ -0,0 +1,2 @@
        +import Testing
        +let added = 4
        """

    private func render() -> NSAttributedString {
        let view = DiffTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        view.render(twoFileDiff, filePath: "app/Sources/Foo.swift")
        return view.renderedForTesting
    }

    /// Attributes at the first character of `needle`.
    private func attributes(at needle: String, in doc: NSAttributedString)
        -> [NSAttributedString.Key: Any]?
    {
        let range = (doc.string as NSString).range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return doc.attributes(at: range.location, effectiveRange: nil)
    }

    @Test("every file header carries the rule-above attribute the layout manager paints")
    func headersCarryARule() {
        let doc = render()
        var ruled = 0
        doc.enumerateAttribute(.diffRuleAbove, in: NSRange(location: 0, length: doc.length)) {
            value, _, _ in
            if value is NSColor { ruled += 1 }
        }
        // One run per file — the hard edge that separates the two.
        #expect(ruled == 2)
    }

    /// A code row must never inherit the rule, or every line would draw its own edge
    /// and the file boundary would stop meaning anything.
    @Test("code rows carry no rule")
    func codeRowsAreNotRuled() {
        let doc = render()
        #expect(attributes(at: "let kept", in: doc)?[.diffRuleAbove] == nil)
    }

    @Test("the filename is bold and bright; its directory stays dim")
    func leafOutweighsDirectory() {
        let doc = render()
        let dir = attributes(at: "app/Sources/", in: doc)
        let leaf = attributes(at: "Foo.swift", in: doc)
        #expect(dir?[.foregroundColor] as? NSColor == DiffTheme.headerDir)
        #expect(leaf?[.foregroundColor] as? NSColor == DiffTheme.headerPath)
        let leafFont = leaf?[.font] as? NSFont
        let dirFont = dir?[.font] as? NSFont
        #expect(leafFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(dirFont?.fontDescriptor.symbolicTraits.contains(.bold) == false)
    }

    /// The header band steps FORWARD off the canvas; code rows do not paint it.
    @Test("the header row is washed with the raised band colour")
    func headerRowIsBanded() {
        let doc = render()
        #expect(attributes(at: "Foo.swift", in: doc)?[.diffRowWash] as? NSColor
            == DiffTheme.headerBand)
        #expect(attributes(at: "let kept", in: doc)?[.diffRowWash] as? NSColor
            != DiffTheme.headerBand)
    }

    @Test("each header states its own ± counts in the ± colours")
    func headerCarriesPerFileStats() {
        let doc = render()
        // Foo.swift: one deletion, one addition. BarTests.swift: two additions, none removed.
        #expect(doc.string.contains("+1"))
        #expect(doc.string.contains("−1"))
        #expect(doc.string.contains("+2"))
        #expect(doc.string.contains("−0"))
        // Anchored on the band, not just the colour: an addition *row* is addedText too,
        // so a bare colour check here could pass off a code row as the header's stat.
        let plus = attributes(at: "+2", in: doc)
        #expect(plus?[.foregroundColor] as? NSColor == DiffTheme.addedText)
        #expect(plus?[.diffRowWash] as? NSColor == DiffTheme.headerBand)
        let minus = attributes(at: "−0", in: doc)
        #expect(minus?[.foregroundColor] as? NSColor == DiffTheme.removedText)
        #expect(minus?[.diffRowWash] as? NSColor == DiffTheme.headerBand)
    }
}
