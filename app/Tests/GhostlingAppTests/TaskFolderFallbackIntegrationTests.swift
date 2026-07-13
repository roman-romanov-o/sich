import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

@MainActor
@Test func loadingFlowACardAppliesOnlyUnambiguousFallback() throws {
    let unambiguousRoot = try temporaryProject()
    let ambiguousRoot = try temporaryProject()
    defer {
        try? FileManager.default.removeItem(at: unambiguousRoot)
        try? FileManager.default.removeItem(at: ambiguousRoot)
    }
    let inferred = unambiguousRoot.appendingPathComponent("docs/tasks/task-01-only")
    try FileManager.default.createDirectory(at: inferred, withIntermediateDirectories: true)
    for name in ["task-01-first", "task-02-second"] {
        try FileManager.default.createDirectory(
            at: ambiguousRoot.appendingPathComponent("docs/tasks/\(name)"),
            withIntermediateDirectories: true
        )
    }
    let shell = BoardShell(seeds: [
        flowASeed(id: "unambiguous", project: unambiguousRoot),
        flowASeed(id: "ambiguous", project: ambiguousRoot),
    ])

    shell.buildContentForTesting()

    #expect(shell.cards.first { $0.sessionID == "unambiguous" }?.taskFolder == inferred.path)
    #expect(shell.cards.first { $0.sessionID == "ambiguous" }?.taskFolder == nil)
}

@MainActor
@Test func currentTaskFallbackPreservesExplicitBindingsAndSkipsOtherCards() throws {
    let root = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("docs/tasks/task-01-first")
    let second = root.appendingPathComponent("docs/tasks/task-02-second")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let saha = root.appendingPathComponent(".sahaidachny")
    try FileManager.default.createDirectory(at: saha, withIntermediateDirectories: true)
    try "task-02-second\n".write(
        to: saha.appendingPathComponent("current-task"),
        atomically: true,
        encoding: .utf8
    )
    let explicit = flowASeed(id: "explicit", project: root, taskFolder: first.path)
    let fallback = flowASeed(id: "fallback", project: root)
    let interactive = BoardSeed(
        sessionID: "interactive",
        projectDir: root.path,
        agent: .claude,
        flow: .b,
        state: .idle,
        scrollback: ""
    )
    let shell = BoardShell(seeds: [explicit, fallback, interactive])

    shell.buildContentForTesting()

    #expect(shell.cards.first { $0.sessionID == "explicit" }?.taskFolder == first.path)
    #expect(shell.cards.first { $0.sessionID == "fallback" }?.taskFolder == second.path)
    #expect(shell.cards.first { $0.sessionID == "interactive" }?.taskFolder == nil)
    shell.e2eTeardown()
}

@MainActor
@Test func zeroTaskFoldersLeavesSahaCardUnbound() throws {
    let root = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let shell = BoardShell(seeds: [flowASeed(id: "empty", project: root)])

    shell.buildContentForTesting()

    #expect(shell.cards.first?.taskFolder == nil)
    shell.e2eTeardown()
}

private func temporaryProject() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func flowASeed(id: String, project: URL, taskFolder: String? = nil) -> BoardSeed {
    BoardSeed(
        sessionID: id,
        projectDir: project.path,
        agent: .claude,
        flow: .a,
        state: .idle,
        scrollback: "",
        taskFolder: taskFolder
    )
}
