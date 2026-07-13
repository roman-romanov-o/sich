import AppKit
import GhostlingCore

/// The POC diff palette (designer spec from "Task View" standalone): every value
/// is a literal token from the POC's line()/seg() style functions, so the native
/// view and the mockup read identically.
@MainActor
enum DiffTheme {
    static let addedText = BoardTheme.hex(0xD8E4DC)
    static let removedText = BoardTheme.hex(0xB8C2CC)
    static let contextText = BoardTheme.hex(0x7D8590)
    static let fold = BoardTheme.hex(0x39414C)
    static let foldBg = BoardTheme.hex(0x0D1117)

    static let addedWash = alpha(0x12261A, 0.20)
    static let addedRibbon = alpha(0x12261A, 0.53)
    static let removedWash = alpha(0x2D1214, 0.13)
    static let removedRibbon = alpha(0x2D1214, 0.40)
    static let addedGutter = alpha(0x3FB950, 0.40)
    static let removedGutter = alpha(0xF85149, 0.40)
    static let wordAdded = alpha(0x1F7A3D, 0.40)
    static let wordRemoved = alpha(0xF85149, 0.27)

    static let code = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let gutter = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    private static func alpha(_ rgb: UInt32, _ value: CGFloat) -> NSColor {
        BoardTheme.hex(rgb).withAlphaComponent(value)
    }
}

/// Full-width row wash painted behind the whole line (gutter included); the
/// denser code "ribbon" and word highlights ride on the standard
/// `.backgroundColor` attribute drawn behind glyphs only — the POC's two layers.
extension NSAttributedString.Key {
    static let diffRowWash = NSAttributedString.Key("ghostling.diffRowWash")
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
            for hunk in file.hunks {
                output.append(foldLine(Self.foldLabel(for: hunk)))
                append(hunk: hunk, to: output)
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

    private func append(hunk: DiffHunk, to output: NSMutableAttributedString) {
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
                                  new: newNum + offset, to: output)
                    }
                    let hidden = run - 2 * Self.contextKeep
                    output.append(foldLine("⋯ \(hidden) unchanged lines"))
                    for offset in (run - Self.contextKeep)..<run {
                        appendRow(lines[index + offset], old: oldNum + offset,
                                  new: newNum + offset, to: output)
                    }
                } else {
                    for offset in 0..<run {
                        appendRow(lines[index + offset], old: oldNum + offset,
                                  new: newNum + offset, to: output)
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
                                  addition: false, to: output)
                    appendWordRow(marker: "+", number: newNum, spans: spans.new,
                                  addition: true, to: output)
                    oldNum += 1
                    newNum += 1
                    index += 2
                } else {
                    appendRow(line, old: oldNum, new: newNum, to: output)
                    oldNum += 1
                    index += 1
                }
            case .addition:
                appendRow(line, old: oldNum, new: newNum, to: output)
                newNum += 1
                index += 1
            case .metadata:
                appendRow(line, old: oldNum, new: newNum, to: output)
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
        _ line: DiffLine, old: Int, new: Int, to output: NSMutableAttributedString
    ) {
        let style = Self.rowStyle(line.kind)
        let number: Int? = line.kind == .metadata ? nil : (line.kind == .deletion ? old : new)
        output.append(gutter(number, color: style.gutter, wash: style.wash))
        var attributes = attrs(foreground: style.text, wash: style.wash)
        if let ribbon = style.ribbon { attributes[.backgroundColor] = ribbon }
        output.append(NSAttributedString(string: line.text + "\n", attributes: attributes))
    }

    private func appendWordRow(
        marker: String, number: Int, spans: [WordDiff.Span], addition: Bool,
        to output: NSMutableAttributedString
    ) {
        let style = Self.rowStyle(addition ? .addition : .deletion)
        output.append(gutter(number, color: style.gutter, wash: style.wash))
        var base = attrs(foreground: style.text, wash: style.wash)
        base[.backgroundColor] = style.ribbon
        let row = NSMutableAttributedString(string: marker, attributes: base)
        for span in spans {
            var attributes = base
            if span.changed {
                attributes[.backgroundColor] =
                    addition ? DiffTheme.wordAdded : DiffTheme.wordRemoved
                attributes[.foregroundColor] = BoardTheme.textPrimary
            }
            row.append(NSAttributedString(string: span.text, attributes: attributes))
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

    private func fileHeader(_ file: DiffFile) -> NSAttributedString {
        var attributes = attrs(foreground: BoardTheme.textMuted,
                               wash: BoardTheme.canvasSunken,
                               font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold))
        attributes[.paragraphStyle] = Self.paragraph(spacing: 8)
        return NSAttributedString(string: "  \(file.displayPath)\n", attributes: attributes)
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
@MainActor
private final class FullWidthDiffLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let container = textContainers.first {
            let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            storage.enumerateAttribute(.diffRowWash, in: chars) { value, range, _ in
                guard let color = value as? NSColor else { return }
                let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                self.enumerateLineFragments(forGlyphRange: glyphRange) { _, used, _, _, _ in
                    color.setFill()
                    NSRect(x: origin.x, y: origin.y + used.minY,
                           width: container.containerSize.width, height: used.height).fill()
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}
