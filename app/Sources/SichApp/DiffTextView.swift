import AppKit
import SichCore

/// The POC diff palette (designer spec from "Task View" standalone): every value
/// is a literal token from the POC's line()/seg() style functions, so the native
/// view and the mockup read identically.
@MainActor
enum DiffTheme {
    /// The file-header band: a raised surface + a bright rule above it, so the
    /// boundary between two files reads as a hard break rather than one more row
    /// in the stream. Deliberately *lighter* than the canvas — the code rows below
    /// it are all darker, so the band is the only thing that steps forward.
    static let headerBand = BoardTheme.dynamic(dark: BoardTheme.hex(0x00304A),
                                               light: BoardTheme.hex(0xD8CFB4))
    static let headerRule = BoardTheme.hex(0x3A9ADE)    // solarized blue — the file edge
    static let headerPath = BoardTheme.textPrimary
    static let headerDir = BoardTheme.textDim

    static let addedText = BoardTheme.hex(0xCBE08F)     // solarized green-tinted light
    static let removedText = BoardTheme.hex(0xE4B3AC)   // solarized red-tinted light
    static let contextText = BoardTheme.hex(0x728797)   // base00
    static let fold = BoardTheme.hex(0x2A4152)
    static let foldBg = BoardTheme.hex(0x00111F)

    static let addedWash = alpha(0x1E2E0A, 0.24)
    static let addedRibbon = alpha(0x1E2E0A, 0.55)
    static let removedWash = alpha(0x2D1214, 0.16)
    static let removedRibbon = alpha(0x2D1214, 0.42)
    static let addedGutter = alpha(0x99CC00, 0.40)
    static let removedGutter = alpha(0xE84C3D, 0.40)
    static let wordAdded = alpha(0x669900, 0.42)
    static let wordRemoved = alpha(0xE84C3D, 0.27)

    static let code = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let gutter = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    // Solarized-accent syntax palette, layered ON TOP of the diff row's base text
    // colour: keyword blue, string cyan, number magenta, comment dim. Each reads
    // clearly on both the near-black canvas and the faint add/remove washes, so
    // syntax colour enriches the line while the wash/ribbon/gutter still signal ±.
    static let synKeyword = BoardTheme.hex(0x268BD2)   // solarized blue
    static let synString = BoardTheme.hex(0x2AA198)    // solarized cyan
    static let synNumber = BoardTheme.hex(0xD33682)    // solarized magenta
    static let synComment = BoardTheme.hex(0x657B83)   // solarized base00 (dim)

    /// The foreground override for a syntax token, or `nil` for `plain` (which keeps
    /// the diff row's own colour — the ± signal on ordinary identifiers).
    static func syntaxColor(_ kind: SyntaxHighlight.TokenKind) -> NSColor? {
        switch kind {
        case .keyword: return synKeyword
        case .string: return synString
        case .number: return synNumber
        case .comment: return synComment
        case .plain: return nil
        }
    }

    private static func alpha(_ rgb: UInt32, _ value: CGFloat) -> NSColor {
        BoardTheme.hex(rgb).withAlphaComponent(value)
    }
}

/// Full-width row wash painted behind the whole line (gutter included); the
/// denser code "ribbon" and word highlights ride on the standard
/// `.backgroundColor` attribute drawn behind glyphs only — the POC's two layers.
extension NSAttributedString.Key {
    static let diffRowWash = NSAttributedString.Key("sich.diffRowWash")
    /// Paints a full-width rule along the TOP edge of the line's fragment — the hard
    /// edge that starts a new file, which a background wash alone can't draw.
    static let diffRuleAbove = NSAttributedString.Key("sich.diffRuleAbove")
}

@MainActor
final class DiffTextView: NSScrollView {
    private let textView: NSTextView
    /// Context runs longer than this collapse to edges + a fold line.
    private static let contextKeep = 3
    private static let contextFoldThreshold = 8

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layout = FullWidthDiffLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        textView = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)

        drawsBackground = true
        backgroundColor = BoardTheme.canvas
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        documentView = textView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = BoardTheme.canvas
        textView.textContainerInset = NSSize(width: 0, height: 10)
        textView.isHorizontallyResizable = false
        // The document must be free to grow vertically past the clip view or the
        // scroll view has nothing to scroll (the "diff won't scroll" defect).
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { nil }

    /// Test seam: the rendered attributed document, so a test can prove the syntax
    /// palette is actually applied on the render path (not just in the pure lexer).
    var renderedForTesting: NSAttributedString { textView.attributedString() }

    /// Render EVERY file in the diff with a header separator per file (the
    /// GitHub/GitLab review layout), then scroll so the selected `filePath`'s
    /// header sits at the top — the reader can keep scrolling into the
    /// neighbouring files instead of being fenced into one.
    func render(_ diff: String, filePath: String? = nil) {
        let output = NSMutableAttributedString()
        var selectedOffset: Int?
        for file in UnifiedDiffParser.parse(diff) {
            if file.displayPath == filePath { selectedOffset = output.length }
            output.append(fileHeader(file))
            let language = CodeLanguage.infer(fromPath: file.displayPath)
            for hunk in file.hunks {
                output.append(foldLine(Self.foldLabel(for: hunk)))
                append(hunk: hunk, to: output, language: language)
            }
        }
        textView.textStorage?.setAttributedString(output)
        if let offset = selectedOffset {
            scroll(toCharacter: offset)
        } else {
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    /// Scroll the document so the line holding `location` is at the top edge.
    private func scroll(toCharacter location: Int) {
        guard let layout = textView.layoutManager, let container = textView.textContainer else {
            return
        }
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        textView.scroll(NSPoint(x: 0, y: max(0, line.minY)))
    }

    // MARK: - Hunk rendering

    /// "⋯ func windowStart()" when the hunk header carries a symbol, else the range.
    private static func foldLabel(for hunk: DiffHunk) -> String {
        let parts = hunk.header.components(separatedBy: "@@")
        let symbol = parts.count > 2
            ? parts[2].trimmingCharacters(in: .whitespaces) : ""
        let range = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return "⋯ " + (symbol.isEmpty ? range : symbol)
    }

    private func append(
        hunk: DiffHunk, to output: NSMutableAttributedString, language: CodeLanguage
    ) {
        var (oldNum, newNum) = Self.startNumbers(of: hunk.header)
        var index = 0
        let lines = hunk.lines
        while index < lines.count {
            let line = lines[index]
            switch line.kind {
            case .context:
                var run = 0
                while index + run < lines.count, lines[index + run].kind == .context { run += 1 }
                if run >= Self.contextFoldThreshold {
                    for offset in 0..<Self.contextKeep {
                        appendRow(lines[index + offset], old: oldNum + offset,
                                  new: newNum + offset, to: output, language: language)
                    }
                    let hidden = run - 2 * Self.contextKeep
                    output.append(foldLine("⋯ \(hidden) unchanged lines"))
                    for offset in (run - Self.contextKeep)..<run {
                        appendRow(lines[index + offset], old: oldNum + offset,
                                  new: newNum + offset, to: output, language: language)
                    }
                } else {
                    for offset in 0..<run {
                        appendRow(lines[index + offset], old: oldNum + offset,
                                  new: newNum + offset, to: output, language: language)
                    }
                }
                oldNum += run
                newNum += run
                index += run
            case .deletion:
                if index + 1 < lines.count, lines[index + 1].kind == .addition {
                    let next = lines[index + 1]
                    let spans = WordDiff.spans(
                        old: String(line.text.dropFirst()), new: String(next.text.dropFirst()))
                    appendWordRow(marker: "-", number: oldNum, spans: spans.old,
                                  addition: false, to: output, language: language)
                    appendWordRow(marker: "+", number: newNum, spans: spans.new,
                                  addition: true, to: output, language: language)
                    oldNum += 1
                    newNum += 1
                    index += 2
                } else {
                    appendRow(line, old: oldNum, new: newNum, to: output, language: language)
                    oldNum += 1
                    index += 1
                }
            case .addition:
                appendRow(line, old: oldNum, new: newNum, to: output, language: language)
                newNum += 1
                index += 1
            case .metadata:
                appendRow(line, old: oldNum, new: newNum, to: output, language: language)
                index += 1
            }
        }
    }

    private static func startNumbers(of header: String) -> (old: Int, new: Int) {
        // "@@ -105,7 +105,9 @@ …"
        var old = 1
        var new = 1
        for token in header.split(separator: " ") {
            if token.hasPrefix("-") {
                old = Int(token.dropFirst().split(separator: ",")[0]) ?? 1
            } else if token.hasPrefix("+") {
                new = Int(token.dropFirst().split(separator: ",")[0]) ?? 1
            }
        }
        return (old, new)
    }

    // MARK: - Row construction

    private func appendRow(
        _ line: DiffLine, old: Int, new: Int, to output: NSMutableAttributedString,
        language: CodeLanguage
    ) {
        let style = Self.rowStyle(line.kind)
        let number: Int? = line.kind == .metadata ? nil : (line.kind == .deletion ? old : new)
        output.append(gutter(number, color: style.gutter, wash: style.wash))
        var base = attrs(foreground: style.text, wash: style.wash)
        if let ribbon = style.ribbon { base[.backgroundColor] = ribbon }
        // Metadata lines carry no code — render them flat. Code rows keep their base
        // (± diff) colour on ordinary text and overlay syntax colours on keywords,
        // strings, numbers and comments (single-char marker excluded from the lexer).
        guard line.kind != .metadata else {
            output.append(NSAttributedString(string: line.text + "\n", attributes: base))
            return
        }
        output.append(syntaxRow(line.text, base: base, language: language))
    }

    /// A code row whose leading ±/space marker keeps the base colour and whose code
    /// is split into syntax-coloured spans layered on that same base (so the wash /
    /// ribbon / background attributes carry through under every span).
    private func syntaxRow(
        _ text: String, base: [NSAttributedString.Key: Any], language: CodeLanguage
    ) -> NSAttributedString {
        let row = NSMutableAttributedString(string: String(text.prefix(1)), attributes: base)
        appendCode(String(text.dropFirst()), base: base, language: language, to: row)
        row.append(NSAttributedString(string: "\n", attributes: base))
        return row
    }

    /// Append `code` to `row`, split into syntax-coloured spans over `base` — the one
    /// place the lexer's token → colour mapping is applied, shared by whole-line rows
    /// and the unchanged segments of a word-diff row.
    private func appendCode(
        _ code: String, base: [NSAttributedString.Key: Any], language: CodeLanguage,
        to row: NSMutableAttributedString
    ) {
        for span in SyntaxHighlight.spans(code, language: language) {
            var attributes = base
            if let color = DiffTheme.syntaxColor(span.kind) { attributes[.foregroundColor] = color }
            row.append(NSAttributedString(string: span.text, attributes: attributes))
        }
    }

    /// A word-diff row for a paired ±. Changed word spans keep their emphasis (the
    /// added/removed background + primary text so the edit stands out); *unchanged*
    /// segments are syntax-coloured like a whole-line code row, so highlighting reaches
    /// the most common diff shape (a modified line) instead of only pure add/deletes.
    private func appendWordRow(
        marker: String, number: Int, spans: [WordDiff.Span], addition: Bool,
        to output: NSMutableAttributedString, language: CodeLanguage
    ) {
        let style = Self.rowStyle(addition ? .addition : .deletion)
        output.append(gutter(number, color: style.gutter, wash: style.wash))
        var base = attrs(foreground: style.text, wash: style.wash)
        base[.backgroundColor] = style.ribbon
        let row = NSMutableAttributedString(string: marker, attributes: base)
        for span in spans {
            if span.changed {
                var attributes = base
                attributes[.backgroundColor] =
                    addition ? DiffTheme.wordAdded : DiffTheme.wordRemoved
                attributes[.foregroundColor] = BoardTheme.textPrimary
                row.append(NSAttributedString(string: span.text, attributes: attributes))
            } else {
                appendCode(span.text, base: base, language: language, to: row)
            }
        }
        row.append(NSAttributedString(string: "\n", attributes: base))
        output.append(row)
    }

    private struct RowStyle {
        let text: NSColor
        let gutter: NSColor
        let wash: NSColor?
        let ribbon: NSColor?
    }

    private static func rowStyle(_ kind: DiffLineKind) -> RowStyle {
        switch kind {
        case .addition:
            return RowStyle(text: DiffTheme.addedText, gutter: DiffTheme.addedGutter,
                            wash: DiffTheme.addedWash, ribbon: DiffTheme.addedRibbon)
        case .deletion:
            return RowStyle(text: DiffTheme.removedText, gutter: DiffTheme.removedGutter,
                            wash: DiffTheme.removedWash, ribbon: DiffTheme.removedRibbon)
        case .context:
            return RowStyle(text: DiffTheme.contextText, gutter: DiffTheme.fold,
                            wash: nil, ribbon: nil)
        case .metadata:
            return RowStyle(text: BoardTheme.textDim, gutter: DiffTheme.fold,
                            wash: nil, ribbon: nil)
        }
    }

    /// 44pt-equivalent right-aligned mono gutter: "  105  ".
    private func gutter(_ number: Int?, color: NSColor, wash: NSColor?) -> NSAttributedString {
        let text = number.map { String(format: "%5d", $0) } ?? "     "
        var attributes = attrs(foreground: color, wash: wash, font: DiffTheme.gutter)
        attributes.removeValue(forKey: .backgroundColor)
        return NSAttributedString(string: "\(text)  ", attributes: attributes)
    }

    private func foldLine(_ label: String) -> NSAttributedString {
        var attributes = attrs(foreground: DiffTheme.fold, wash: DiffTheme.foldBg,
                               font: DiffTheme.gutter)
        attributes[.paragraphStyle] = Self.paragraph(spacing: 6)
        return NSAttributedString(string: "       \(label)\n", attributes: attributes)
    }

    /// The band that starts a file: a gap of canvas, a bright rule, then a raised
    /// row carrying `dir/` dim + `name.ext` bright + this file's ± counts. Four cues
    /// at once (gap, rule, surface step, weight) because the single faint wash the
    /// header used to have was lost among 24 files of near-identical rows.
    private func fileHeader(_ file: DiffFile) -> NSAttributedString {
        let header = NSMutableAttributedString(attributedString: gap())
        let (dir, name) = Self.split(path: file.displayPath)
        var band = attrs(foreground: DiffTheme.headerDir, wash: DiffTheme.headerBand,
                         font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular))
        band[.paragraphStyle] = Self.paragraph(spacing: 7)
        band[.diffRuleAbove] = DiffTheme.headerRule
        header.append(NSAttributedString(string: "  \(dir)", attributes: band))
        var leaf = band
        leaf[.foregroundColor] = DiffTheme.headerPath
        leaf[.font] = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        header.append(NSAttributedString(string: name, attributes: leaf))
        header.append(stats(of: file, band: band))
        header.append(NSAttributedString(string: "\n", attributes: band))
        return header
    }

    /// "  +12 −3" trailing the path, each count in its own ± colour.
    private func stats(of file: DiffFile, band: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let lines = file.hunks.flatMap(\.lines)
        let added = lines.filter { $0.kind == .addition }.count
        let removed = lines.filter { $0.kind == .deletion }.count
        let row = NSMutableAttributedString(string: "   ", attributes: band)
        var plus = band
        plus[.foregroundColor] = DiffTheme.addedText
        row.append(NSAttributedString(string: "+\(added)", attributes: plus))
        var minus = band
        minus[.foregroundColor] = DiffTheme.removedText
        row.append(NSAttributedString(string: " −\(removed)", attributes: minus))
        return row
    }

    /// A blank canvas row above a file header — the breathing room that makes the
    /// rule below it read as a boundary instead of a border on the previous line.
    private func gap() -> NSAttributedString {
        NSAttributedString(
            string: "\n",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular),
                         .foregroundColor: BoardTheme.canvas])
    }

    /// Split "app/Sources/Foo.swift" into ("app/Sources/", "Foo.swift") so the leaf —
    /// the part a reviewer scans for — can be the bright, bold half.
    private static func split(path: String) -> (dir: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        let cut = path.index(after: slash)
        return (String(path[..<cut]), String(path[cut...]))
    }

    private func attrs(
        foreground: NSColor, wash: NSColor?, font: NSFont = DiffTheme.code
    ) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: foreground,
            .paragraphStyle: Self.paragraph(spacing: 3),
        ]
        if let wash { result[.diffRowWash] = wash }
        return result
    }

    private static func paragraph(spacing: CGFloat) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = spacing
        return paragraph
    }
}

/// Paints the `.diffRowWash` attribute across the full pane width (the faint
/// row tint), then lets AppKit draw the standard glyph-bounded `.backgroundColor`
/// runs on top (the denser code ribbon and word-diff highlights).
private let diffRuleThickness: CGFloat = 2

@MainActor
private final class FullWidthDiffLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let container = textContainers.first {
            let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            let width = container.containerSize.width
            storage.enumerateAttribute(.diffRowWash, in: chars) { value, range, _ in
                guard let color = value as? NSColor else { return }
                self.fillFragments(of: range, origin: origin, width: width) { color.setFill(); return $0 }
            }
            // Rules paint after every wash so a file header's top edge is never
            // covered by the wash of the row that follows it.
            storage.enumerateAttribute(.diffRuleAbove, in: chars) { value, range, _ in
                guard let color = value as? NSColor else { return }
                self.fillFragments(of: range, origin: origin, width: width) { used in
                    color.setFill()
                    return NSRect(x: used.minX, y: used.minY,
                                  width: used.width, height: diffRuleThickness)
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Fill one rect per line fragment of `range`, letting `shape` set the colour and
    /// narrow the full-width row rect down to what it actually wants painted.
    /// `nonisolated` to match the drawing callbacks it runs inside — every call it
    /// makes is an inherited (nonisolated) NSLayoutManager method.
    private nonisolated func fillFragments(
        of range: NSRange, origin: NSPoint, width: CGFloat,
        shape: @escaping (NSRect) -> NSRect
    ) {
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            let row = NSRect(x: origin.x, y: origin.y + used.minY,
                             width: width, height: used.height)
            shape(row).fill()
        }
    }
}
