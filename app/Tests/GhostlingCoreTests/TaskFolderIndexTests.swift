import Foundation
import Testing
@testable import GhostlingCore

@Test func discoversBareFoldersAndKeepsUnknownProgress() throws {
    let root = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let task = root.appendingPathComponent("docs/tasks/task-01-bare")
    try FileManager.default.createDirectory(at: task, withIntermediateDirectories: true)

    let result = TaskFolderIndex().discover(in: root)
    #expect(result.count == 1)
    #expect(result[0].progress == .unknown)
    #expect(TaskFolderIndex().inferredFolder(in: root) == task.standardizedFileURL)
}

@Test func currentTaskDisambiguatesMultipleFolders() throws {
    let root = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["task-01-one", "task-02-two"] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("docs/tasks/\(name)"),
            withIntermediateDirectories: true
        )
    }
    let saha = root.appendingPathComponent(".sahaidachny")
    try FileManager.default.createDirectory(at: saha, withIntermediateDirectories: true)
    try "task-02-two\n".write(
        to: saha.appendingPathComponent("current-task"), atomically: true, encoding: .utf8
    )

    #expect(TaskFolderIndex().inferredFolder(in: root)?.lastPathComponent == "task-02-two")
}

@Test func readmePlanningTableProvidesTitleAndProgress() throws {
    let root = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let task = try makeTask("task-03-progress", in: root)
    try """
    # Human-readable title

    ## Planning Progress

    | Step | Status | Artifacts |
    |------|--------|-----------|
    | Research | Done | research/*.md |
    | Stories | Complete | user-stories/*.md |
    | Plan | Pending | implementation-plan/*.md |
    """.write(to: task.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

    let summary = try #require(TaskFolderIndex().discover(in: root).first)
    #expect(summary.title == "Human-readable title")
    #expect(summary.progress == .known(completed: 2, total: 3))
}

@Test func discoveryFiltersFilesAndNonTaskDirectoriesAndSortsNaturally() throws {
    let root = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try makeTask("task-10-ten", in: root)
    _ = try makeTask("task-2-two", in: root)
    _ = try makeTask("notes", in: root)
    let file = root.appendingPathComponent("docs/tasks/task-01-file")
    try "not a folder".write(to: file, atomically: true, encoding: .utf8)

    #expect(TaskFolderIndex().discover(in: root).map(\.url.lastPathComponent) == [
        "task-2-two", "task-10-ten",
    ])
}

@Test(arguments: [
    "task-02-two",
    "docs/tasks/task-02-two",
    "\"docs/tasks/task-02-two\"",
])
func supportedPointerFormatsDisambiguate(_ pointer: String) throws {
    let root = try projectWithTwoTasks()
    defer { try? FileManager.default.removeItem(at: root) }
    try writePointer(pointer, in: root)

    #expect(TaskFolderIndex().inferredFolder(in: root)?.lastPathComponent == "task-02-two")
}

@Test func absolutePointerDisambiguates() throws {
    let root = try projectWithTwoTasks()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("docs/tasks/task-02-two")
    try writePointer(target.path, in: root)

    #expect(TaskFolderIndex().inferredFolder(in: root) == target.standardizedFileURL)
}

@Test(arguments: ["", "task-missing", "../task-02-two", "docs/tasks/task-missing"])
func malformedOrNonmatchingPointersDoNotBind(_ pointer: String) throws {
    let root = try projectWithTwoTasks()
    defer { try? FileManager.default.removeItem(at: root) }
    try writePointer(pointer, in: root)

    #expect(TaskFolderIndex().inferredFolder(in: root) == nil)
}

@Test func multipleFoldersWithoutPointerRemainUnbound() throws {
    let root = try projectWithTwoTasks()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(TaskFolderIndex().inferredFolder(in: root) == nil)
}

private func temporaryProject() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeTask(_ name: String, in root: URL) throws -> URL {
    let task = root.appendingPathComponent("docs/tasks/\(name)")
    try FileManager.default.createDirectory(at: task, withIntermediateDirectories: true)
    return task
}

private func projectWithTwoTasks() throws -> URL {
    let root = try temporaryProject()
    _ = try makeTask("task-01-one", in: root)
    _ = try makeTask("task-02-two", in: root)
    return root
}

private func writePointer(_ pointer: String, in root: URL) throws {
    let saha = root.appendingPathComponent(".sahaidachny")
    try FileManager.default.createDirectory(at: saha, withIntermediateDirectories: true)
    try "\(pointer)\n".write(
        to: saha.appendingPathComponent("current-task"), atomically: true, encoding: .utf8
    )
}
