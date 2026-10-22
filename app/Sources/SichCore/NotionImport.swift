import Foundation

/// One-way Notion → Sich import: open sprint tasks assigned to the operator land in
/// the backlog, so they never get retyped by hand. Nothing is written to Notion.
///
/// The token lives in a plain `0600` file next to the task book, never the Keychain
/// (operator choice). No file or an empty token → the import never starts.
public struct NotionConfig: Codable, Sendable, Equatable {
    /// A Notion personal access token — requests act as the operator, so the
    /// `Assignee contains me` filter resolves to them with no connection to share.
    public var token: String
    public var tasksDataSourceID: String

    public init(token: String, tasksDataSourceID: String) {
        self.token = token
        self.tasksDataSourceID = tasksDataSourceID
    }

    public static func load(from url: URL) -> NotionConfig? {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(NotionConfig.self, from: data),
              !config.token.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return config
    }

    public static var applicationSupportURL: URL {
        sichSupportDirectory().appendingPathComponent("notion.json")
    }
}

/// A Notion task as the backlog needs it.
public struct NotionTask: Sendable, Equatable {
    public let id: String
    public let title: String
    public let details: String
    public let url: String

    public init(id: String, title: String, details: String, url: String) {
        self.id = id
        self.title = title
        self.details = details
        self.url = url
    }

    /// The backlog description: the Notion details plus a link back to the page.
    public var backlogDetails: String {
        details.isEmpty ? "Notion: \(url)" : "\(details)\n\nNotion: \(url)"
    }
}

/// The Notion calls the import needs — a seam so tests never touch the network.
public protocol NotionAPI: Sendable {
    func openTasks() async throws -> [NotionTask]
}

/// Notion page ids already imported. Kept even after the backlog task is deleted or
/// done, so a task the operator dismissed never comes back.
public final class NotionImportStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func applicationSupport() -> NotionImportStore {
        NotionImportStore(url: sichSupportDirectory().appendingPathComponent("notion-imported.json"))
    }

    public func load() -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(ids)
    }

    public func save(_ ids: Set<String>) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ids.sorted()).write(to: url, options: .atomic)
    }
}

@MainActor
public final class NotionImporter {
    private let api: NotionAPI
    private let store: NotionImportStore
    private var imported: Set<String>

    public init(api: NotionAPI, store: NotionImportStore) {
        self.api = api
        self.store = store
        self.imported = store.load()
    }

    /// Fetch open tasks and hand over the ones never seen before, marking them
    /// imported. A failed fetch yields nothing; the next pull tries again.
    public func pull() async -> [NotionTask] {
        let tasks: [NotionTask]
        do {
            tasks = try await api.openTasks()
        } catch {
            FileHandle.standardError.write(Data("notion import: \(error)\n".utf8))
            return []
        }
        let fresh = tasks.filter { !imported.contains($0.id) }
        guard !fresh.isEmpty else { return [] }
        imported.formUnion(fresh.map(\.id))
        do {
            try store.save(imported)
        } catch {
            FileHandle.standardError.write(Data("notion import: saving ids failed: \(error)\n".utf8))
        }
        return fresh
    }
}

public enum NotionError: Error, Equatable {
    case http(status: Int, body: String)
    case malformedResponse
}

/// The REST client, authenticated with the operator's personal access token.
public struct NotionClient: NotionAPI {
    private static let base = URL(string: "https://api.notion.com/v1/")!
    private static let version = "2026-03-11"
    /// The statuses that mean "work for now" — Backlog stays in Notion.
    private static let openStatuses = ["To do", "In progress"]

    private let config: NotionConfig
    private let session: URLSession

    public init(config: NotionConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func openTasks() async throws -> [NotionTask] {
        let statusFilters = Self.openStatuses.map {
            ["property": "Status", "status": ["equals": $0]] as [String: Any]
        }
        var tasks: [NotionTask] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = [
                "filter": ["and": [
                    ["property": "Assignee", "people": ["contains": "me"]],
                    ["or": statusFilters],
                ]],
                "page_size": 100,
            ]
            if let cursor { body["start_cursor"] = cursor }
            let json = try await send("data_sources/\(config.tasksDataSourceID)/query", body: body)
            guard let results = json["results"] as? [[String: Any]] else {
                throw NotionError.malformedResponse
            }
            tasks += results.compactMap(Self.task(from:))
            cursor = json["has_more"] as? Bool == true ? json["next_cursor"] as? String : nil
        } while cursor != nil
        return tasks
    }

    /// A query row as a task, or `nil` when it has no title.
    private static func task(from page: [String: Any]) -> NotionTask? {
        guard let id = page["id"] as? String,
              let url = page["url"] as? String,
              let properties = page["properties"] as? [String: [String: Any]]
        else { return nil }
        let title = plainText(properties["Task"]?["title"])
        guard !title.isEmpty else { return nil }
        return NotionTask(
            id: id, title: title, details: plainText(properties["Details"]?["rich_text"]), url: url)
    }

    private static func plainText(_ value: Any?) -> String {
        ((value as? [[String: Any]]) ?? []).compactMap { $0["plain_text"] as? String }.joined()
    }

    private func send(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.version, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NotionError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotionError.malformedResponse
        }
        return json
    }
}

/// `Application Support/Sich`, the directory the task book lives in.
private func sichSupportDirectory() -> URL {
    let base = (try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true
    )) ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("Sich", isDirectory: true)
}
