import Foundation

/// A single classified line in a rendered diff. `metadata` covers hunk headers
/// and file markers; the rest map to the usual unified-diff gutters.
public enum DiffLineKind: Sendable, Equatable {
    case context, addition, deletion, metadata
}

public struct DiffLine: Sendable, Equatable {
    public let kind: DiffLineKind
    public let text: String

    public init(kind: DiffLineKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct DiffHunk: Sendable, Equatable {
    public let header: String
    public let lines: [DiffLine]

    public init(header: String, lines: [DiffLine]) {
        self.header = header
        self.lines = lines
    }
}

public struct DiffFile: Sendable, Equatable {
    public let oldPath: String
    public let newPath: String
    public let hunks: [DiffHunk]
    public let metadata: [String]

    public var displayPath: String {
        let path = newPath == "/dev/null" ? oldPath : newPath
        return path.hasPrefix("b/") || path.hasPrefix("a/") ? String(path.dropFirst(2)) : path
    }

    public init(oldPath: String, newPath: String, hunks: [DiffHunk], metadata: [String]) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.hunks = hunks
        self.metadata = metadata
    }
}

public enum UnifiedDiffParser {
    public static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var oldPath = ""
        var newPath = ""
        var metadata: [String] = []
        var hunks: [DiffHunk] = []
        var hunkHeader: String?
        var hunkLines: [DiffLine] = []

        func flushHunk() {
            guard let header = hunkHeader else { return }
            hunks.append(DiffHunk(header: header, lines: hunkLines))
            hunkHeader = nil
            hunkLines = []
        }
        func flushFile() {
            flushHunk()
            guard !oldPath.isEmpty || !newPath.isEmpty else { return }
            files.append(DiffFile(
                oldPath: oldPath, newPath: newPath, hunks: hunks, metadata: metadata))
            oldPath = ""
            newPath = ""
            metadata = []
            hunks = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                flushFile()
                metadata.append(line)
            } else if line.hasPrefix("--- ") {
                oldPath = path(after: "--- ", in: line)
                metadata.append(line)
            } else if line.hasPrefix("+++ ") {
                newPath = path(after: "+++ ", in: line)
                metadata.append(line)
            } else if line.hasPrefix("@@") {
                flushHunk()
                hunkHeader = line
            } else if hunkHeader != nil {
                let kind: DiffLineKind
                if line.hasPrefix("+") { kind = .addition }
                else if line.hasPrefix("-") { kind = .deletion }
                else if line.hasPrefix(" ") { kind = .context }
                else { kind = .metadata }
                hunkLines.append(DiffLine(kind: kind, text: line))
            } else if !line.isEmpty {
                metadata.append(line)
            }
        }
        flushFile()
        return files
    }

    private static func path(after prefix: String, in line: String) -> String {
        String(line.dropFirst(prefix.count)).split(separator: "\t", maxSplits: 1)
            .first.map(String.init) ?? ""
    }
}

public struct TurnDiff: Sendable, Equatable {
    public let sessionID: String
    public let cardID: String?
    public let cwd: String?
    public let iteration: Int
    public let timestamp: Date
    public let unifiedDiff: String
    public let sessionDiff: String?

    public var files: [DiffFile] { UnifiedDiffParser.parse(unifiedDiff) }
    public var additions: Int {
        files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .addition }.count
    }
    public var deletions: Int {
        files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .deletion }.count
    }

    public init(
        sessionID: String, cardID: String? = nil, cwd: String? = nil,
        iteration: Int, timestamp: Date, unifiedDiff: String, sessionDiff: String? = nil
    ) {
        self.sessionID = sessionID
        self.cardID = cardID
        self.cwd = cwd
        self.iteration = iteration
        self.timestamp = timestamp
        self.unifiedDiff = unifiedDiff
        self.sessionDiff = sessionDiff
    }
}

public enum TurnDiffNormalizer {
    // periphery:ignore - test-only entry (scan runs with exclude_tests)
    public static func normalize(_ line: Data, arrival: Date) -> TurnDiff? {
        guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return nil }
        return normalize(payload: value, arrival: arrival)
    }

    /// Payload-based entry: a `turn_diff` line can be megabytes (the whole turn's
    /// unified diff, base64), so callers that already hold the parsed object must
    /// not pay a second full `JSONSerialization` pass just to classify it.
    public static func normalize(payload value: [String: Any], arrival: Date) -> TurnDiff? {
        guard value["sich_event_type"] as? String == "turn_diff",
              let encoded = value["diff_base64"] as? String,
              let data = Data(base64Encoded: encoded),
              let diff = String(data: data, encoding: .utf8)
        else { return nil }
        return TurnDiff(
            sessionID: value["session_id"] as? String ?? "",
            cardID: value["sich_card_id"] as? String,
            cwd: (value["cwd"] as? String) ?? decodeString(value["cwd_base64"]),
            iteration: value["iteration"] as? Int ?? 0,
            timestamp: SignalTimestamp.parse(value["timestamp"], arrival: arrival),
            unifiedDiff: diff,
            sessionDiff: decodeData(value["session_diff_base64"])
        )
    }

    private static func decodeString(_ value: Any?) -> String? {
        decodeData(value)
    }

    private static func decodeData(_ value: Any?) -> String? {
        guard let encoded = value as? String, let data = Data(base64Encoded: encoded)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public enum WordDiff {
    public struct Span: Sendable, Equatable {
        public let text: String
        public let changed: Bool
        public init(text: String, changed: Bool) {
            self.text = text
            self.changed = changed
        }
    }

    public static func spans(old: String, new: String) -> (old: [Span], new: [Span]) {
        let oldWords = tokens(old)
        let newWords = tokens(new)
        let changes = newWords.difference(from: oldWords)
        let removed = Set(changes.removals.compactMap { change -> Int? in
            if case let .remove(offset, _, _) = change { return offset }
            return nil
        })
        let inserted = Set(changes.insertions.compactMap { change -> Int? in
            if case let .insert(offset, _, _) = change { return offset }
            return nil
        })
        return (
            oldWords.enumerated().map { Span(text: $0.element, changed: removed.contains($0.offset)) },
            newWords.enumerated().map { Span(text: $0.element, changed: inserted.contains($0.offset)) }
        )
    }

    private static func tokens(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        var whitespace: Bool?
        for character in text {
            let isWhitespace = character.isWhitespace
            if let whitespace, whitespace != isWhitespace {
                result.append(current)
                current = ""
            }
            current.append(character)
            whitespace = isWhitespace
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
