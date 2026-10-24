import Foundation
import SichCore
import Testing

/// The durable task book: round-trips, the flat placement encoding, and the
/// corruption/version degradation paths that make "never lose a task" hold even
/// when a write was cut short or the schema moved on.
struct TaskStoreTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-taskstore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    /// Fixed clock + fixed record dates so Equatable comparisons don't ride the wall clock.
    private let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let createdAt = Date(timeIntervalSince1970: 1_600_000_000)

    private func sampleTasks() -> [TaskRecord] {
        [
            TaskRecord(
                title: "Design the importer", details: "CSV first, then the API feed.",
                placement: .backlog, projectDir: "/tmp/proj", createdAt: createdAt
            ),
            TaskRecord(
                title: "Fix login redirect", placement: .board(.done), agent: "claude",
                projectDir: "/tmp/proj", createdAt: createdAt,
                sessionRef: TaskSessionRef(claudeSessionID: UUID(), lastCwd: "/tmp/proj"),
                accumulatedWorkingTime: 5_400
            ),
        ]
    }

    @Test func savedTasksRoundTripThroughLoad() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let store = BoardTaskStore(directory: dir, now: { self.savedAt })

        let tasks = sampleTasks()
        let saved = try store.save(tasks: tasks)
        let loaded = try #require(store.load())

        #expect(loaded == saved)
        #expect(loaded.tasks == tasks)
        #expect(loaded.version == TaskBook.currentVersion)
    }

    /// Placement is a flat string in the JSON ("backlog" / the CardState raw value)
    /// so the file stays hand-inspectable — pinned at the byte level, not just via
    /// Codable symmetry.
    @Test func placementEncodesAsFlatStrings() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let store = BoardTaskStore(directory: dir, now: { self.savedAt })

        try store.save(tasks: sampleTasks())
        let json = try #require(String(data: Data(contentsOf: store.currentURL), encoding: .utf8))

        #expect(json.contains("\"placement\" : \"backlog\""))
        #expect(json.contains("\"placement\" : \"\(CardState.done.rawValue)\""))
        #expect(json.contains("\"accumulatedWorkingTime\" : 5400"))
    }

    @Test func legacyRecordWithoutDurationDecodesAsZeroCompatibleNil() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "title": "Legacy task",
          "details": "",
          "placement": "idle",
          "createdAt": 0
        }
        """

        let record = try JSONDecoder().decode(TaskRecord.self, from: Data(json.utf8))
        #expect(record.accumulatedWorkingTime == nil)
    }

    /// A write cut short (crash mid-save) must degrade to the last-known-good
    /// `-previous` book that the prior successful load rotated into place.
    @Test func corruptCurrentFallsBackToRotatedPrevious() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let store = BoardTaskStore(directory: dir, now: { self.savedAt })

        let good = try store.save(tasks: sampleTasks())
        _ = try #require(store.load())   // rotates current → previous
        try Data("{ truncated".utf8).write(to: store.currentURL)

        let recovered = try #require(BoardTaskStore(directory: dir).load())
        #expect(recovered == good)
    }

    /// A future-schema book loads as nil (clean start), never a crash or a
    /// half-understood record set.
    @Test func versionMismatchLoadsNil() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let store = BoardTaskStore(directory: dir, now: { self.savedAt })

        try store.save(TaskBook(version: 99, savedAt: savedAt, tasks: []))

        #expect(store.load() == nil)
    }
}
