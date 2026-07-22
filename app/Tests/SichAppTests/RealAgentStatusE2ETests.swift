import XCTest
@testable import SichApp
import SichCore

/// Opt-in, quota-free smoke: the user's installed agent CLIs resolve through
/// Sich's scoped shims (`~/.sich/bin/{claude,codex}`) without a real turn.
///
/// The old second test here (headless `claude -p` / `codex exec` turns asserted at
/// store level with a permissive `validFinal`) was removed: the headless path is one
/// the product never watches, and the wide accept-set let wrong resting states pass.
/// The trusted lifecycle coverage now lives in `CardStatusRealAgentE2ETests`, which
/// types into a real interactive card PTY and asserts board columns. Run with:
///
///     SICH_REAL_AGENT_E2E=1 swift test --filter RealAgentStatusE2ETests
final class RealAgentStatusE2ETests: XCTestCase {
    func testInstalledClaudeAndCodexResolveThroughSichShims() throws {
        guard ProcessInfo.processInfo.environment["SICH_REAL_AGENT_E2E"] == "1" else {
            throw XCTSkip("set SICH_REAL_AGENT_E2E=1 to run against installed claude/codex")
        }

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-real-agent-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertTrue(HookInstaller.installClaudeShim(home: home))
        XCTAssertTrue(HookInstaller.installCodexShim(home: home))

        let shimDir = home.appendingPathComponent(".sich/bin").path
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["PATH"] = "\(shimDir):\(env["PATH"] ?? "/usr/bin:/bin")"
        env["SICH_CARD_ID"] = UUID().uuidString
        env["SICH_EVENTS_FILE"] = home.appendingPathComponent("events.jsonl").path

        let claude = try run(shimDir + "/claude", ["--help"], env: env)
        XCTAssertEqual(claude.status, 0, claude.stderr)
        XCTAssertTrue(claude.stdout.contains("Usage: claude"), claude.stdout)

        let codex = try run(shimDir + "/codex", ["--help"], env: env)
        XCTAssertEqual(codex.status, 0, codex.stderr)
        XCTAssertTrue(codex.stdout.contains("Usage: codex"), codex.stdout)
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
