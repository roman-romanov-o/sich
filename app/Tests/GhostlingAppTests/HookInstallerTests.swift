import XCTest
@testable import GhostlingApp

/// The hook installer's JSON merge is the genuinely tricky bit (idempotent,
/// matcher-group reuse, preserve welcome.sh) — so it gets a real check: a temp
/// settings.json seeded with welcome.sh, installed twice.
final class HookInstallerTests: XCTestCase {
    func testMergePreservesWelcomeAndIsIdempotent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostling-hooktest-\(UUID().uuidString)")
        let settings = tmp.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let seed = """
        {"hooks":{"SessionStart":[{"matcher":"","hooks":[\
        {"type":"command","command":"bash .claude/scripts/welcome.sh"}]}]}}
        """
        try seed.write(to: settings, atomically: true, encoding: .utf8)

        XCTAssertTrue(HookInstaller.install(repoRoot: tmp), "first run writes the forwarder")
        XCTAssertFalse(HookInstaller.install(repoRoot: tmp), "second run is a no-op (idempotent)")

        let hooks = try loadHooks(settings)

        // welcome.sh survived and shares SessionStart's matcher-"" group with the forwarder.
        let startCmds = commands(in: hooks["SessionStart"])
        XCTAssertTrue(startCmds.contains("bash .claude/scripts/welcome.sh"), "welcome.sh preserved")
        XCTAssertTrue(startCmds.contains(HookInstaller.forward), "forwarder added to SessionStart")

        // Every board event got exactly one forwarder — no duplicates after two installs.
        for event in HookInstaller.events {
            let count = commands(in: hooks[event]).filter { $0 == HookInstaller.forward }.count
            XCTAssertEqual(count, 1, "\(event) should carry exactly one forwarder")
        }
    }

    private func loadHooks(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let cfg = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(cfg["hooks"] as? [String: Any])
    }

    /// Flatten every command string under one event's groups.
    private func commands(in event: Any?) -> [String] {
        let groups = event as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
    }
}
