import Foundation

/// One clickable span found in a terminal row (checklist 18.08, item 9).
public struct TerminalLink: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case url
        case file
    }

    public let kind: Kind
    /// The link text exactly as it appears on screen (trailing punctuation trimmed).
    public let text: String
    /// The grid columns the link occupies — one unicode scalar per terminal cell,
    /// so these index cells, not UTF-16 units.
    public let columns: Range<Int>

    public init(kind: Kind, text: String, columns: Range<Int>) {
        self.kind = kind
        self.text = text
        self.columns = columns
    }
}

/// Finds URLs and file paths in a single terminal row. Pure text → spans, no I/O:
/// whether a path actually exists is the opener's business (the screen may show
/// paths from another machine), the detector only recognizes the *shape*.
public enum TerminalLinkDetector {

    /// `https://…` / `http://…` up to whitespace; common wrappers and trailing
    /// punctuation are trimmed so `(https://a.dev/b).` links `https://a.dev/b`.
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"https?://\S+"#)

    /// Path shapes worth linking: absolute (`/a/b`, `~/a`), explicitly relative
    /// (`./a`, `../a`), multi-segment relative (`Sources/App/File.swift`), or a
    /// bare compiler-style `File.swift:12` — each with an optional `:line[:col]`.
    private static let filePattern = try! NSRegularExpression(
        pattern: #"(?:~/|\.{1,2}/|/)[\w.+@%~/-]*[\w+@%-](?::\d+(?::\d+)?)?"#
            + #"|(?<![\w./-])[\w.+@%-]+(?:/[\w.+@%-]+)+(?::\d+(?::\d+)?)?"#
            + #"|(?<![\w./-])[\w+@%-]+\.[A-Za-z]{1,8}:\d+(?::\d+)?"#)

    private static let trailingJunk = CharacterSet(charactersIn: ".,;:!?)\"'\u{5D}>")

    public static func links(in line: String) -> [TerminalLink] {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var found: [TerminalLink] = []
        for match in urlPattern.matches(in: line, range: whole) {
            if let link = trimmed(ns.substring(with: match.range), at: match.range,
                                  in: line, kind: .url) {
                found.append(link)
            }
        }
        for match in filePattern.matches(in: line, range: whole) {
            guard let link = trimmed(ns.substring(with: match.range), at: match.range,
                                     in: line, kind: .file),
                  looksLikeAPath(link.text),
                  // A span inside an already-found URL is the URL's path, not a file.
                  !found.contains(where: { $0.columns.overlaps(link.columns) })
            else { continue }
            found.append(link)
        }
        return found.sorted { $0.columns.lowerBound < $1.columns.lowerBound }
    }

    /// Prose is full of `n/a`, `w/o`, `either/or` — a bare relative candidate only
    /// counts as a path when it is at least two levels deep or its last segment
    /// carries an extension. Anchored shapes (`/…`, `~/…`, `./…`) always count.
    private static func looksLikeAPath(_ text: String) -> Bool {
        if text.hasPrefix("/") || text.hasPrefix("~/")
            || text.hasPrefix("./") || text.hasPrefix("../") { return true }
        var path = text
        if let match = path.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) {
            path.removeSubrange(match)
        }
        let segments = path.split(separator: "/")
        return segments.count > 2 || (segments.last?.contains(".") ?? false)
    }

    /// Drop trailing punctuation the shell prompt / prose glued onto the link, then
    /// convert the UTF-16 match range into grid columns (unicode-scalar offsets).
    private static func trimmed(
        _ raw: String, at range: NSRange, in line: String, kind: TerminalLink.Kind
    ) -> TerminalLink? {
        var text = raw
        // `File.swift:12` is safe here — digits are never junk, so a `:line` suffix
        // survives; only a truly dangling `:` (or `.`/`)"…`) trims away.
        while let last = text.unicodeScalars.last, trailingJunk.contains(last) {
            text.unicodeScalars.removeLast()
        }
        guard !text.isEmpty, let start = Range(range, in: line)?.lowerBound else { return nil }
        let scalars = line.unicodeScalars
        let lower = scalars.distance(from: scalars.startIndex, to: start)
        let count = text.unicodeScalars.count
        guard count > 0 else { return nil }
        return TerminalLink(kind: kind, text: text, columns: lower..<(lower + count))
    }
}
