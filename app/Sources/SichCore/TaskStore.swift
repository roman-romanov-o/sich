import Foundation

/// Where a task lives right now: the backlog (pure intent, no session yet) or a
/// board column, expressed as the ``CardState`` that column maps to. Encoded as a
/// single string — `"backlog"` or the state's raw value — so the JSON stays flat
/// and hand-inspectable.
public enum TaskPlacement: RawRepresentable, Codable, Sendable, Equatable {
    case backlog
    case board(CardState)

    public init?(rawValue: String) {
        if rawValue == "backlog" {
            self = .backlog
        } else if let state = CardState(rawValue: rawValue) {
            self = .board(state)
        } else {
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .backlog: return "backlog"
        case .board(let state): return state.rawValue
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let placement = TaskPlacement(rawValue: raw) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "unknown task placement '\(raw)'"
            ))
        }
        self = placement
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A task's pointer at its last known session — resume *hints* only, never
/// authority. The session layer may fail to bring a shell back; the task record
/// must survive regardless.
public struct TaskSessionRef: Codable, Sendable, Equatable {
    public let claudeSessionID: UUID?
    public let lastCwd: String?

    public init(claudeSessionID: UUID? = nil, lastCwd: String? = nil) {
        self.claudeSessionID = claudeSessionID
        self.lastCwd = lastCwd
    }
}

/// One durable task — the operator's INPUT (title, description, placement, launch
/// choice), never a session's output. The task is the root entity; a session is an
/// ephemeral attachment, so losing every shell can no longer lose the work list.
public struct TaskRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    /// The free-form backlog description — what this task actually is.
    public var details: String
    public var placement: TaskPlacement
    public var agent: String?
    public var projectDir: String?
    public var createdAt: Date
    public var sessionRef: TaskSessionRef?
    /// Cumulative seconds spent actively in WORKING. Optional on disk so task
    /// books written before duration tracking decode as zero without a version bump.
    public var accumulatedWorkingTime: TimeInterval?
    /// The remote tmux session this task drives, when it is a remote card — the
    /// constructor's INPUT spec (never an argv), same rule as the pane snapshot.
    /// Without it, a remote task that outlives its ssh child has only a
    /// `user@host` label where a local task has a cwd, and no revival can rebuild
    /// the attach. Optional on disk: older books decode without a version bump.
    public var remote: RemoteSpecSnapshot?
    /// When this task left the board for the archive. Non-nil means the task no
    /// longer renders as a card at all — it lives in the archive view, keeping the
    /// DONE column (and the per-refresh card rebuild) lean while the record itself
    /// stays durable. Optional on disk: older books decode without a version bump.
    public var archivedAt: Date?
    /// Which Claude Code config dir this task's sessions use (`CLAUDE_CONFIG_DIR`).
    /// Nil means the default `~/.claude` profile. Optional on disk for back-compat.
    public var claudeProfileID: UUID?
    /// Rule 1 (``docs/OPERATING-RULES.md``): explicit snooze off NEEDS YOU until this
    /// instant. Optional on disk for back-compat.
    public var needsYouDeferredUntil: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        details: String = "",
        placement: TaskPlacement,
        agent: String? = nil,
        projectDir: String? = nil,
        createdAt: Date = Date(),
        sessionRef: TaskSessionRef? = nil,
        accumulatedWorkingTime: TimeInterval? = nil,
        remote: RemoteSpecSnapshot? = nil,
        archivedAt: Date? = nil,
        claudeProfileID: UUID? = nil,
        needsYouDeferredUntil: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.placement = placement
        self.agent = agent
        self.projectDir = projectDir
        self.createdAt = createdAt
        self.sessionRef = sessionRef
        self.accumulatedWorkingTime = accumulatedWorkingTime
        self.remote = remote
        self.archivedAt = archivedAt
        self.claudeProfileID = claudeProfileID
        self.needsYouDeferredUntil = needsYouDeferredUntil
    }
}

/// The persisted task book: every backlog + board task, versioned so a future
/// schema change degrades to a clean start instead of a crash.
public struct TaskBook: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let savedAt: Date
    public let tasks: [TaskRecord]

    public init(version: Int = TaskBook.currentVersion, savedAt: Date, tasks: [TaskRecord]) {
        self.version = version
        self.savedAt = savedAt
        self.tasks = tasks
    }
}

/// Persists the task book on EVERY board mutation, not at quit — a crash between
/// mutations may lose seconds of work, never the board. Mirrors
/// ``SessionSnapshotStore``: atomic `current` write, `-previous` last-known-good
/// rotation on a successful load, injectable directory + clock so tests never
/// touch the real Application Support or the wall clock.
public final class BoardTaskStore {
    private let directory: URL
    private let clock: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.clock = now
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    /// The store rooted under `Application Support/Sich` (the same directory the
    /// session snapshot uses). Falls back to the temp dir only if Application Support
    /// is somehow unavailable.
    public static func applicationSupport(now: @escaping () -> Date = Date.init) -> BoardTaskStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return BoardTaskStore(
            directory: base.appendingPathComponent("Sich", isDirectory: true), now: now
        )
    }

    public var currentURL: URL { directory.appendingPathComponent("board-tasks-current.json") }
    public var previousURL: URL { directory.appendingPathComponent("board-tasks-previous.json") }

    /// Persist `tasks` as a fresh, current-versioned book stamped with the injected
    /// clock (the every-mutation path).
    @discardableResult
    public func save(tasks: [TaskRecord]) throws -> TaskBook {
        let book = TaskBook(savedAt: clock(), tasks: tasks)
        try save(book)
        return book
    }

    /// Persist an explicit book to `current` (atomic write).
    public func save(_ book: TaskBook) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(book).write(to: currentURL, options: .atomic)
    }

    /// The newest usable book: prefer `current`, rotating it to `-previous` on a
    /// successful decode; otherwise fall back to `-previous`. `nil` means start
    /// clean — never a blank crash on a corrupt/partial/version-mismatched file.
    public func load() -> TaskBook? {
        if let book = decodeUsable(at: currentURL) {
            rotateCurrentToPrevious()
            return book
        }
        return decodeUsable(at: previousURL)
    }

    /// Decode a book only if it parses AND matches the current schema version; a
    /// version mismatch or corruption yields `nil`, never a throw.
    private func decodeUsable(at url: URL) -> TaskBook? {
        guard let data = try? Data(contentsOf: url),
              let book = try? decoder.decode(TaskBook.self, from: data),
              book.version == TaskBook.currentVersion
        else { return nil }
        return book
    }

    /// Promote the just-loaded `current` to the `-previous` last-known-good.
    private func rotateCurrentToPrevious() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: currentURL.path) else { return }
        try? fm.removeItem(at: previousURL)
        try? fm.copyItem(at: currentURL, to: previousURL)
    }
}
