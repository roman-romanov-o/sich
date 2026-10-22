import Foundation
import SichCore

/// Checklist 18.08, item 6: a really verbose, human-readable journal of WHO worked
/// on a task WHEN — every state edge the agent goes through, and every interval the
/// operator actually spent inside the task's terminal. One append-only plain-text
/// file per task under `Application Support/Sich/worklogs/<card-id>.log`, so the
/// history is greppable and survives the app, the session, and the card itself.
@MainActor
final class TaskWorkLog {
    var directory: URL
    /// Open agent-work intervals, so the falling edge can log its duration.
    private var agentSince: [UUID: Date] = [:]
    /// Open operator intervals (drill-in / planning mode), same idea.
    private var userSince: [UUID: Date] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    /// The journal rooted next to the task book (`Application Support/Sich`).
    static func applicationSupport() -> TaskWorkLog {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return TaskWorkLog(
            directory: base.appendingPathComponent("Sich/worklogs", isDirectory: true))
    }

    // MARK: - the three journal feeds

    /// A card newly on the board — created, promoted, or restored on launch.
    func noteAppeared(_ card: BoardCard, at date: Date = Date()) {
        append("task on the board in \(card.state.rawValue)", card: card, at: date)
        if card.state.isWorking { agentSince[card.id] = date }
    }

    /// Every observed state edge, verbatim — plus explicit agent-interval lines with
    /// durations on the working↔not-working edges, so "how long did the agent run"
    /// never needs arithmetic across lines.
    func noteState(from previous: CardState, of card: BoardCard, at date: Date = Date()) {
        guard previous != card.state else { return }
        append("state: \(previous.rawValue) → \(card.state.rawValue)", card: card, at: date)
        if !previous.isWorking, card.state.isWorking {
            agentSince[card.id] = date
            append("agent started working", card: card, at: date)
        }
        if previous.isWorking, !card.state.isWorking {
            let opened = agentSince.removeValue(forKey: card.id)
            append("agent stopped working\(Self.durationSuffix(since: opened, at: date))",
                   card: card, at: date)
        }
    }

    /// The operator entered the task (drill-in or planning mode takeover).
    func noteUserEntered(_ card: BoardCard, at date: Date = Date()) {
        userSince[card.id] = date
        append("you entered the task", card: card, at: date)
    }

    /// The operator left it again.
    func noteUserLeft(_ card: BoardCard, at date: Date = Date()) {
        let opened = userSince.removeValue(forKey: card.id)
        append("you left the task\(Self.durationSuffix(since: opened, at: date))",
               card: card, at: date)
    }

    /// An operator-initiated event (account/harness switch, etc.).
    func noteEvent(_ event: String, card: BoardCard, at date: Date = Date()) {
        append(event, card: card, at: date)
    }

    // MARK: - the file

    func fileURL(for cardID: UUID) -> URL {
        directory.appendingPathComponent("\(cardID.uuidString).log")
    }

    private func append(_ event: String, card: BoardCard, at date: Date) {
        let url = fileURL(for: card.id)
        var text = ""
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            text += "# \(card.title ?? card.projectDir) — \(card.projectDir)\n"
        }
        text += "\(Self.stamp.string(from: date)) | \(event)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func durationSuffix(since opened: Date?, at date: Date) -> String {
        guard let opened else { return "" }
        let seconds = Int(date.timeIntervalSince(opened).rounded())
        let clock = String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        return " after \(clock)"
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
