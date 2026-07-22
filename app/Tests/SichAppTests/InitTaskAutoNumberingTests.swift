import Foundation
import SichCore
import Testing

@testable import SichApp

/// TC-INT-002 (US-001) — the real regression guard for the bug hit this very session:
/// a bare `task-07-*/research/` stub (no README, no scaffold) must NOT confuse
/// auto-numbering. Driven through the app's real wrapper
/// (`TaskScaffolder` + `FoundationTaskScaffoldRunner`) calling saha's REAL
/// `init_task.sh` — no mock script, per the "real dependency over mock" philosophy.
/// This asserts documented behavior (the next number is produced regardless of stub
/// folders); it does not "fix" the script.
@MainActor
struct InitTaskAutoNumberingTests {

    @Test func autoNumberingSkipsANonConformingStubFolder() throws {
        let project = try makeTempProjectDir()
        defer { try? FileManager.default.removeItem(at: project) }
        // A bare stub: task-07 exists but is unscaffolded (no README) — the exact shape
        // that produced `task-08` instead of reusing `07` in the session that spawned
        // this regression test.
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("docs/tasks/task-07-native-saha-planning/research"),
            withIntermediateDirectories: true)

        // Drive the REAL script through the app's real process runner (the argument /
        // exit-code contract, not the UI). Asserting at the script's `createdPath`
        // contract — TC-INT-002's Expected Output — rather than through
        // `TaskScaffolder.create`, whose stdout parser is a separate US-001 concern.
        let result = try FoundationTaskScaffoldRunner().run(
            executable: initTaskScript(), arguments: ["native-saha-planning"],
            directory: project)

        // Documented behavior: numbering reads the `07` prefix regardless of scaffold
        // completeness and produces the next number — a gap-free assumption would fail.
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains(
            "Created task folder: docs/tasks/task-08-native-saha-planning"))
        var isDir: ObjCBool = false
        let created = project.appendingPathComponent("docs/tasks/task-08-native-saha-planning")
        #expect(FileManager.default.fileExists(atPath: created.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    /// The real `.claude/scripts/init_task.sh`, located from the repo root (this test
    /// file sits at `app/Tests/SichAppTests/` — four levels down).
    private func initTaskScript() throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent(".claude/scripts/init_task.sh")
        try #require(FileManager.default.isExecutableFile(atPath: script.path))
        return script
    }

    private func makeTempProjectDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
