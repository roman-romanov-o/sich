import XCTest
@testable import GhostlingApp

/// Opt-in E2E smoke against the user's installed agent CLIs.
///
/// This deliberately uses `--help` so it exercises the real `claude` and `codex`
/// binaries through Ghostling's shims without starting a model turn or spending
/// quota. Run with:
///
///     GHOSTLING_REAL_AGENT_E2E=1 GHOSTLING_REAL_CODEX_TURN_E2E=1 swift test --filter RealAgentStatusE2ETests
final class RealAgentStatusE2ETests: XCTestCase {
    func testInstalledClaudeAndCodexResolveThroughGhostlingShims() throws {
        guard ProcessInfo.processInfo.environment["GHOSTLING_REAL_AGENT_E2E"] == "1" else {
            throw XCTSkip("set GHOSTLING_REAL_AGENT_E2E=1 to run against installed claude/codex")
        }

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostling-real-agent-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertTrue(HookInstaller.installClaudeShim(home: home))
        XCTAssertTrue(HookInstaller.installCodexShim(home: home))

        let shimDir = home.appendingPathComponent(".ghostling/bin").path
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["PATH"] = "\(shimDir):\(env["PATH"] ?? "/usr/bin:/bin")"
        env["GHOSTLING_CARD_ID"] = UUID().uuidString
        env["GHOSTLING_EVENTS_FILE"] = home.appendingPathComponent("events.jsonl").path

        let claude = try run(shimDir + "/claude", ["--help"], env: env)
        XCTAssertEqual(claude.status, 0, claude.stderr)
        XCTAssertTrue(claude.stdout.contains("Usage: claude"), claude.stdout)

        let codex = try run(shimDir + "/codex", ["--help"], env: env)
        XCTAssertEqual(codex.status, 0, codex.stderr)
        XCTAssertTrue(codex.stdout.contains("Usage: codex"), codex.stdout)
    }

    func testRealCodexTurnEmitsGhostlingStatusEvents() throws {
        guard ProcessInfo.processInfo.environment["GHOSTLING_REAL_CODEX_TURN_E2E"] == "1" else {
            throw XCTSkip("set GHOSTLING_REAL_CODEX_TURN_E2E=1 to run a minimal real Codex turn")
        }

        let realCodexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostling-real-codex-turn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        for name in ["auth.json", "config.toml"] {
            let src = realCodexHome.appendingPathComponent(name)
            let dst = codexHome.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(at: src, to: dst)
            }
        }

        XCTAssertTrue(HookInstaller.installCodexShim(home: home))

        let events = home.appendingPathComponent("events.jsonl")
        let shimDir = home.appendingPathComponent(".ghostling/bin").path
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["CODEX_HOME"] = codexHome.path
        env["PATH"] = "\(shimDir):\(env["PATH"] ?? "/usr/bin:/bin")"
        env["GHOSTLING_CARD_ID"] = UUID().uuidString
        env["GHOSTLING_EVENTS_FILE"] = events.path

        let result = try run(
            shimDir + "/codex",
            ["exec", "--ephemeral", "--json", "Reply exactly OK and do not run tools."],
            env: env
        )
        XCTAssertEqual(result.status, 0, result.stderr)

        let body = try String(contentsOf: events, encoding: .utf8)
        XCTAssertTrue(body.contains(#""ghostling_agent":"codex""#), body)
        XCTAssertTrue(body.contains(#""hook_event_name":"SessionStart""#), body)
        XCTAssertTrue(body.contains(#""hook_event_name":"UserPromptSubmit""#), body)
        XCTAssertTrue(body.contains(#""hook_event_name":"Stop""#), body)
        XCTAssertTrue(body.contains(#""ghostling_card_id":""#), body)
    }

    private func run(_ executable: String, _ args: [String], env: [String: String]) throws
        -> (status: Int32, stdout: String, stderr: String)
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}
