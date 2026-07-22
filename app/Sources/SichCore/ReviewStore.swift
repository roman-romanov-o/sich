import Foundation

/// One review note the operator attached to a planning artifact. `sent` flips when
/// the note has been folded into a feedback draft pre-typed into the terminal.
public struct ReviewComment: Codable, Equatable, Sendable {
    public let file: String   // artifact lastPathComponent
    public let text: String
    public var sent: Bool

    public init(file: String, text: String, sent: Bool = false) {
        self.file = file
        self.text = text
        self.sent = sent
    }
}

/// Persisted per-task review state (approvals + comments) backing the PR-style
/// planning review. Stored as a dotfile inside the task folder so the planning
/// marker scraper (which only reads `*.md`) never sees it.
public final class ReviewStore {
    public private(set) var approved: Set<String> = []
    public private(set) var comments: [ReviewComment] = []
    private let url: URL

    private struct Snapshot: Codable {
        var approved: [String]
        var comments: [ReviewComment]
    }

    public init(taskFolder: URL) {
        url = taskFolder.appendingPathComponent(".review-state.json")
        if let data = try? Data(contentsOf: url),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            approved = Set(snap.approved)
            comments = snap.comments
        }
    }

    public func isApproved(_ file: String) -> Bool { approved.contains(file) }

    public func approve(_ file: String) {
        approved.insert(file)
        save()
    }

    public func addComment(file: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        comments.append(ReviewComment(file: file, text: trimmed))
        save()
    }

    public func comments(for file: String) -> [ReviewComment] {
        comments.filter { $0.file == file }
    }

    /// Comments not yet folded into a pre-typed feedback draft.
    public var queued: [ReviewComment] { comments.filter { !$0.sent } }

    /// Called after a draft was pre-typed into the terminal. ponytail: "pre-typed"
    /// counts as sent — tracking the actual Enter keypress would need pty echo parsing.
    public func markQueuedSent() {
        comments = comments.map { ReviewComment(file: $0.file, text: $0.text, sent: true) }
        save()
    }

    private func save() {
        let snap = Snapshot(approved: approved.sorted(), comments: comments)
        try? JSONEncoder().encode(snap).write(to: url, options: .atomic)
    }
}

/// Builds the `/saha:<step> — revise per review: …` line from queued comments.
/// Always a SINGLE line: the draft is pre-typed into a live pty input line, where an
/// embedded newline would submit it — the one thing this flow must never do.
public enum FeedbackDraft {
    public static func compose(command: String, comments: [ReviewComment]) -> String? {
        let queued = comments.filter { !$0.sent }
        guard !queued.isEmpty else { return nil }
        let items = queued.enumerated()
            .map { "\($0.offset + 1)) \(stem($0.element.file)): \(flatten($0.element.text))" }
            .joined(separator: "; ")
        return "\(command) revise per review: \(items)"
    }

    public static func stem(_ file: String) -> String { (file as NSString).deletingPathExtension }

    private static func flatten(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }
}
