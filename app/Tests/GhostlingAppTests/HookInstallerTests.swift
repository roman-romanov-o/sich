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

    /// Regression for "card never moves when its repo isn't THIS repo": the global
    /// install must land in ~/.claude/settings.json with an ABSOLUTE script path,
    /// write the self-contained forwarder copy, preserve pre-existing user hooks
    /// (e.g. a Stop notifier), and stay idempotent.
    func testGlobalInstallIsAbsoluteSelfContainedAndPreservesUserHooks() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostling-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let seed = """
        {"model":"opus","hooks":{"Stop":[{"matcher":"","hooks":[\
        {"type":"command","command":"bash ~/.claude/hooks/ntfy-stop.sh"}]}]}}
        """
        try seed.write(to: settings, atomically: true, encoding: .utf8)

        XCTAssertTrue(HookInstaller.installGlobal(home: home), "first run wires the hooks")
        XCTAssertFalse(HookInstaller.installGlobal(home: home), "second run is a no-op")

        let script = home.appendingPathComponent(".ghostling/ghostling-forward.sh")
        let body = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(body.contains("GHOSTLING_CARD_ID"), "self-contained forwarder written")

        let cfg = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual(cfg["model"] as? String, "opus", "non-hook settings preserved")
        let hooks = try XCTUnwrap(cfg["hooks"] as? [String: Any])
        XCTAssertTrue(commands(in: hooks["Stop"]).contains("bash ~/.claude/hooks/ntfy-stop.sh"),
                      "user's existing Stop hook preserved")
        for event in HookInstaller.events {
            let fwd = commands(in: hooks[event]).filter { $0 == "bash \(script.path)" }
            XCTAssertEqual(fwd.count, 1, "\(event) carries exactly one absolute-path forwarder")
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
