import AppKit

@MainActor
struct MarkdownTheme {
    let text = BoardTheme.documentText
    let headingColor = BoardTheme.textPrimary
    let muted = BoardTheme.textMuted
    let faint = BoardTheme.textFaint
    let link = BoardTheme.attention
    let codeText = BoardTheme.textPrimary
    let codeInline = BoardTheme.codeInline      // inline `code` — cool, distinct from links
    let codeBackground = BoardTheme.canvasSunken.withAlphaComponent(0.92)
    let rule = BoardTheme.cardStrokeStrong
    let quoteBar = BoardTheme.attention
    let label = BoardTheme.textMuted

    let bodySize: CGFloat = 14.5
    var body: NSFont { .systemFont(ofSize: bodySize) }
    var code: NSFont { .monospacedSystemFont(ofSize: bodySize - 2, weight: .regular) }
    var table: NSFont { .monospacedSystemFont(ofSize: bodySize - 2.5, weight: .regular) }

    /// Distinct font per header level so H1…H6 are visually differentiated
    /// (US-005 AC "headers … have distinct native styling", TC-UNIT-012).
    func heading(level: Int) -> NSFont {
        let sizes: [CGFloat] = [23, 19, 16.5, 15.5, 14.5, 14]
        let size = sizes[min(max(level - 1, 0), sizes.count - 1)]
        return .systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)
    }
    func bold(_ f: NSFont) -> NSFont { NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
    func italic(_ f: NSFont) -> NSFont { NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
}

/// Install hint shown when a mermaid fence cannot be rendered (TC-UNIT-015/TC-E2E-016).
let mermaidInstallHint = "install mermaid-cli (`mmdc`) to render this diagram"

/// Renders CommonMark to a native `NSAttributedString`: block layout is hand-dispatched
/// here (headings, lists, tables, rules, code, quotes) while every inline span — bold,
/// italic, code, links, escaping — is parsed by Foundation's own markdown engine, so the
/// asterisks/backticks never leak through as literal text.
@MainActor
struct NativeMarkdownRenderer {
    typealias MermaidRenderer = (String) -> NSImage?

    let theme: MarkdownTheme
    let renderMermaid: MermaidRenderer

    init(theme: MarkdownTheme = MarkdownTheme(), renderMermaid: @escaping MermaidRenderer = { _ in nil }) {
        self.theme = theme
        self.renderMermaid = renderMermaid
    }

    func render(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            switch true {
            case t.hasPrefix("```"): i = appendFencedCode(lines, from: i, to: out)
            case isRule(t):          appendRule(to: out); i += 1
            case isHeading(t):       appendHeading(t, to: out); i += 1
            case t.hasPrefix(">"):   i = appendQuote(lines, from: i, to: out)
            case t.hasPrefix("|"):   i = appendTable(lines, from: i, to: out)
            case isListItem(line):   i = appendList(lines, from: i, to: out)
            case t.isEmpty:          i += 1
            default:                 i = appendParagraph(lines, from: i, to: out)
            }
        }
        return out
    }

    // MARK: - Block predicates

    private func isHeading(_ t: String) -> Bool {
        t.range(of: #"^#{1,6}(\s|$)"#, options: .regularExpression) != nil
    }
    private func isRule(_ t: String) -> Bool {
        t.replacingOccurrences(of: " ", with: "")
            .range(of: #"^([-*_])\1{2,}$"#, options: .regularExpression) != nil
    }
    private func isListItem(_ line: String) -> Bool {
        line.range(of: #"^\s*([-*+]|\d+\.)\s+"#, options: .regularExpression) != nil
    }

    // MARK: - Paragraph / heading / rule / quote

    /// Consecutive plain lines are one block, but each source line keeps its break
    /// (U+2028 = intra-paragraph break) — these docs use hard line breaks meaningfully,
    /// so collapsing them to spaces would run distinct points together.
    private func appendParagraph(_ lines: [String], from start: Int, to out: NSMutableAttributedString) -> Int {
        var i = start
        let body = NSMutableAttributedString()
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !isRule(t), !isHeading(t), !t.hasPrefix("```"),
                  !t.hasPrefix(">"), !t.hasPrefix("|"), !isListItem(lines[i]) else { break }
            if body.length > 0 { body.append(NSAttributedString(string: "\u{2028}")) }
            body.append(inline(t, font: theme.body, color: theme.text))
            i += 1
        }
        styleSahaFieldLabels(in: body)
        emit(body, style: paragraph(spacingAfter: 17, lineHeight: 1.46), to: out)
        return i
    }

    private func appendHeading(_ t: String, to out: NSMutableAttributedString) {
        let level = t.prefix(while: { $0 == "#" }).count
        let text = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        let before: CGFloat
        let after: CGFloat
        switch level {
        case 1: before = out.length == 0 ? 0 : 24; after = 14
        case 2: before = out.length == 0 ? 0 : 24; after = 11
        case 3: before = out.length == 0 ? 0 : 19; after = 8
        default: before = out.length == 0 ? 0 : 15; after = 6
        }
        let style = paragraph(spacingBefore: before, spacingAfter: after, lineHeight: 1.12)
        emit(inline(text, font: theme.heading(level: level), color: theme.headingColor), style: style, to: out)
    }

    private func appendRule(to out: NSMutableAttributedString) {
        // Clip, don't wrap: an over-wide box-drawing run would otherwise spill a stray
        // dash onto a second line instead of reading as one divider.
        let style = paragraph(spacingBefore: 6, spacingAfter: 13) as! NSMutableParagraphStyle
        style.lineBreakMode = .byClipping
        emit(NSAttributedString(string: String(repeating: "─", count: 80),
                                attributes: [.font: theme.body, .foregroundColor: theme.rule]),
             style: style, to: out)
    }

    private func appendQuote(_ lines: [String], from start: Int, to out: NSMutableAttributedString) -> Int {
        var i = start
        let body = NSMutableAttributedString()
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
            var t = lines[i].trimmingCharacters(in: .whitespaces)
            t.removeFirst()
            if body.length > 0 { body.append(NSAttributedString(string: "\u{2028}")) }
            body.append(inline(t.trimmingCharacters(in: .whitespaces), font: theme.body, color: theme.muted))
            i += 1
        }
        let bar = NSMutableAttributedString(string: "▌ ",
            attributes: [.font: theme.body, .foregroundColor: theme.quoteBar])
        bar.append(body)
        emit(bar, style: paragraph(spacingBefore: 4, spacingAfter: 11, head: 18, firstLine: 18), to: out)
        return i
    }

    // MARK: - Lists

    private func appendList(_ lines: [String], from start: Int, to out: NSMutableAttributedString) -> Int {
        var i = start
        while i < lines.count, isListItem(lines[i]) { appendListItem(lines[i], to: out); i += 1 }
        return i
    }

    private func appendListItem(_ line: String, to out: NSMutableAttributedString) {
        let indent = CGFloat(line.prefix(while: { $0 == " " }).count) / 2 * 16 + 16
        let content = Substring(line.drop(while: { $0 == " " }))
        let (marker, body) = listMarker(content)
        let item = NSMutableAttributedString(string: marker,
            attributes: [.font: theme.body, .foregroundColor: theme.muted])
        item.append(inline(body, font: theme.body, color: theme.text))
        emit(item, style: paragraph(spacingAfter: 7, head: indent + 22, firstLine: indent, lineHeight: 1.38), to: out)
    }

    /// Splits a list line into its rendered marker (`•`, `1.`, `☑`, `☐`) and body text.
    private func listMarker(_ content: Substring) -> (String, String) {
        if let m = content.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            return (content[m].trimmingCharacters(in: .whitespaces) + "  ", String(content[m.upperBound...]))
        }
        guard let m = content.range(of: #"^[-*+]\s+"#, options: .regularExpression) else {
            return ("•  ", String(content))
        }
        let rest = content[m.upperBound...]
        if let cb = rest.range(of: #"^\[[ xX]\]\s+"#, options: .regularExpression) {
            let checked = rest[cb].lowercased().contains("x")
            return (checked ? "☑  " : "☐  ", String(rest[cb.upperBound...]))
        }
        return ("•  ", String(rest))
    }

    // MARK: - Tables (aligned monospace)

    /// Real `NSTextTable`: each cell is its own text block so long values wrap *inside* the
    /// column instead of spilling across the grid, with automatic column sizing and drawn
    /// borders. Needs TextKit 1 (see `PlanningModeView.documentPane`).
    private func appendTable(_ lines: [String], from start: Int, to out: NSMutableAttributedString) -> Int {
        var i = start
        var rows: [[String]] = []
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            let row = cells(lines[i])
            if !isSeparatorRow(row) { rows.append(row) }
            i += 1
        }
        guard let cols = rows.map(\.count).max(), cols > 0 else { return i }
        let table = NSTextTable()
        table.numberOfColumns = cols
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        for (r, row) in rows.enumerated() {
            for c in 0..<cols {
                appendCell(c < row.count ? row[c] : "", table: table, row: r, col: c,
                           header: r == 0, to: out)
            }
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: theme.body]))
        return i
    }

    private func appendCell(_ text: String, table: NSTextTable, row: Int, col: Int,
                            header: Bool, to out: NSMutableAttributedString) {
        let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                     startingColumn: col, columnSpan: 1)
        block.setBorderColor(theme.rule)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setWidth(7, type: .absoluteValueType, for: .padding)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        style.lineHeightMultiple = 1.2
        let font = header ? theme.bold(theme.body) : theme.body
        let cell = NSMutableAttributedString(attributedString: inline(text, font: font, color: theme.text))
        cell.append(NSAttributedString(string: "\n"))
        cell.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: cell.length))
        out.append(cell)
    }

    private func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    private func isSeparatorRow(_ row: [String]) -> Bool {
        !row.isEmpty && row.allSatisfy { $0.range(of: #"^:?-{2,}:?$"#, options: .regularExpression) != nil }
    }

    // MARK: - Code / mermaid

    private func appendFencedCode(_ lines: [String], from start: Int, to out: NSMutableAttributedString) -> Int {
        let language = String(lines[start].trimmingCharacters(in: .whitespaces).dropFirst(3))
            .trimmingCharacters(in: .whitespaces)
        var body: [String] = []
        var i = start + 1
        while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            body.append(lines[i]); i += 1
        }
        appendCode(body.joined(separator: "\n"), language: language, to: out)
        return i < lines.count ? i + 1 : i
    }

    private func appendCode(_ source: String, language: String, to out: NSMutableAttributedString) {
        let isMermaid = language.lowercased() == "mermaid"
        if isMermaid, let image = renderMermaid(source) { appendImage(image, to: out); return }
        let padded = source
            .components(separatedBy: "\n")
            .map { "  " + $0 }
            .joined(separator: "\u{2028}")
        out.append(NSAttributedString(string: "\u{2028}" + padded + "\u{2028}\n",
            attributes: [
                .font: theme.code, .foregroundColor: theme.codeText,
                .backgroundColor: theme.codeBackground,
                .paragraphStyle: paragraph(spacingBefore: 7, spacingAfter: 16, head: 18, firstLine: 18, lineHeight: 1.32),
            ]))
        if isMermaid {
            out.append(NSAttributedString(string: mermaidInstallHint + "\n", attributes: [
                .font: theme.body.withSize(theme.bodySize - 2), .foregroundColor: theme.muted,
            ]))
        }
    }

    private func appendImage(_ image: NSImage, to out: NSMutableAttributedString) {
        let attachment = NSTextAttachment()
        attachment.image = image
        let maxW: CGFloat = 620
        if image.size.width > maxW {
            attachment.bounds = NSRect(x: 0, y: 0, width: maxW, height: image.size.height * maxW / image.size.width)
        }
        out.append(NSAttributedString(attachment: attachment))
        out.append(NSAttributedString(string: "\n"))
    }

    // MARK: - Inline (Foundation-parsed) + shared plumbing

    /// Parses inline markdown via Foundation and maps its intents to native fonts/colors.
    /// `path/to/File.swift` optionally suffixed `:48`, `:48-97`, or `:38-39,52` (multi-range,
    /// as real research docs write it). Scheme `ghostling-file:` carries the raw ref for the
    /// doc viewer to resolve.
    static let fileRefPattern = try! NSRegularExpression(
        pattern: #"^[\w./~-]+\.(swift|py|c|h|hpp|cpp|m|mm|ts|tsx|js|jsx|json|ya?ml|sh|md|txt)(:\d+(-\d+)?(,\d+(-\d+)?)*)?$"#)

    static func fileLinkURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let range = NSRange(t.startIndex..., in: t)
        guard fileRefPattern.firstMatch(in: t, range: range) != nil,
              let enc = t.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "ghostling-file:" + enc)
    }

    private func inline(_ raw: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: raw, options: opts) else {
            return NSAttributedString(string: raw, attributes: [.font: font, .foregroundColor: color])
        }
        let ns = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        let full = NSRange(location: 0, length: ns.length)
        ns.addAttributes([.font: font, .foregroundColor: color], range: full)
        ns.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue ?? (value as? InlinePresentationIntent)?.rawValue
            else { return }
            applyIntent(InlinePresentationIntent(rawValue: raw), font: font, range: range, to: ns)
        }
        ns.enumerateAttribute(.link, in: full) { value, range, _ in
            guard value != nil else { return }
            ns.addAttributes([.foregroundColor: theme.link,
                              .underlineStyle: NSUnderlineStyle.patternDot.rawValue], range: range)
        }
        return ns
    }

    private func applyIntent(_ intent: InlinePresentationIntent, font: NSFont, range: NSRange,
                             to ns: NSMutableAttributedString) {
        if intent.contains(.code) {
            ns.addAttributes([.font: theme.code, .backgroundColor: theme.codeBackground,
                              .foregroundColor: theme.codeInline], range: range)
            // A code span that looks like a source path (`foo/Bar.swift:48-97`) becomes a
            // link so the reader can jump into the file and back — the rest stay plain code.
            if let url = Self.fileLinkURL((ns.string as NSString).substring(with: range)) {
                ns.addAttributes([.link: url,
                                  .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            }
            return
        }
        var f = font
        if intent.contains(.stronglyEmphasized) { f = theme.bold(f) }
        if intent.contains(.emphasized) { f = theme.italic(f) }
        ns.addAttribute(.font, value: f, range: range)
        if intent.contains(.strikethrough) {
            ns.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
    }

    private func emit(_ body: NSAttributedString, style: NSParagraphStyle, to out: NSMutableAttributedString) {
        let m = NSMutableAttributedString(attributedString: body)
        m.append(NSAttributedString(string: "\n"))
        m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
        out.append(m)
    }

    private func paragraph(spacingBefore: CGFloat = 0, spacingAfter: CGFloat, head: CGFloat = 0,
                           firstLine: CGFloat = 0, lineHeight: CGFloat = 1.45) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = spacingAfter
        p.paragraphSpacingBefore = spacingBefore
        p.lineHeightMultiple = lineHeight
        p.headIndent = head
        p.firstLineHeadIndent = firstLine
        return p
    }

    private func styleSahaFieldLabels(in text: NSMutableAttributedString) {
        let labels = [
            "Date:", "Status:", "Researcher:",
            "Evidence:", "Implication:", "Recommendation:", "Rationale:", "Decision:",
        ]
        let ns = text.string as NSString
        for label in labels {
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let found = ns.range(of: label, options: [], range: search)
                if found.location == NSNotFound { break }
                let atBlockStart = found.location == 0
                    || ns.substring(with: NSRange(location: found.location - 1, length: 1)) == "\u{2028}"
                if atBlockStart {
                    text.addAttributes([
                        .font: theme.bold(theme.body),
                        .foregroundColor: theme.label,
                    ], range: found)
                }
                let next = found.location + found.length
                search = NSRange(location: next, length: ns.length - next)
            }
        }
    }
}
