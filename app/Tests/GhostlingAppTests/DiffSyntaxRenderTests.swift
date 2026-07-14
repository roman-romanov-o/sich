import AppKit
import GhostlingCore
import Testing

@testable import GhostlingApp

/// Wiring proof for the diff pane's native syntax highlighting: the pure lexer is
/// tested in GhostlingCore; this asserts the DiffTextView *render path* actually
/// consults it and paints the syntax palette. Without this, a green lexer could sit
/// unreachable behind the view (the dead-code false-pass this repo has been bitten by).
@MainActor
@Suite("Diff pane syntax highlighting render")
struct DiffSyntaxRenderTests {

    /// A context line carries a keyword, an identifier, a number and a trailing comment;
    /// the paired change below it exercises the word-diff row (its *unchanged* `guard`
    /// must still be highlighted, its *changed* word must keep the edit emphasis).
    private let swiftDiff = """
        diff --git a/Foo.swift b/Foo.swift
        --- a/Foo.swift
        +++ b/Foo.swift
        @@ -1,3 +1,3 @@
         let kept = 42 // note
        -guard oldName else { return }
        +guard newName else { return }
        """

    /// The foreground colour applied to a substring's run in the rendered doc.
    private func foreground(of needle: String, in doc: NSAttributedString) -> NSColor? {
        let range = (doc.string as NSString).range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return doc.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    private func render() -> NSAttributedString {
        let view = DiffTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.render(swiftDiff, filePath: "Foo.swift")
        return view.renderedForTesting
    }

    @Test("keyword, number and comment on a whole-line row get their syntax colours")
    func wholeLineRowIsColoured() {
        let doc = render()
        // `let` on the context line → keyword blue.
        #expect(foreground(of: "let", in: doc) == DiffTheme.synKeyword)
        #expect(foreground(of: "42", in: doc) == DiffTheme.synNumber)
        #expect(foreground(of: "// note", in: doc) == DiffTheme.synComment)
        // `kept` is an ordinary identifier → NOT the keyword colour.
        #expect(foreground(of: "kept", in: doc) != DiffTheme.synKeyword)
    }

    @Test("an unchanged keyword survives on a modified (word-diff) row; the edit stays emphasised")
    func wordDiffRowKeepsSyntaxOnUnchangedSpans() {
        let doc = render()
        // `guard` is unchanged across the -/+ pair → still highlighted as a keyword,
        // proving syntax reaches the common case of a *modified* line, not just pure
        // add/deletes. (The first `guard` in the doc is on the deletion row.)
        #expect(foreground(of: "guard", in: doc) == DiffTheme.synKeyword)
        // `newName` is the changed word → keeps the word-diff emphasis, not a syntax colour.
        #expect(foreground(of: "newName", in: doc) != DiffTheme.synKeyword)
    }
}
