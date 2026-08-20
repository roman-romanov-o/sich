import XCTest
@testable import SichApp

/// The hook installer's JSON merge is the genuinely tricky bit (idempotent,
/// matcher-group reuse, preserve welcome.sh) — so it gets a real check: a temp
/// settings.json seeded with welcome.sh, installed twice.
final class HookInstallerTests: XCTestCase {
    func testMergePreservesWelcomeAndIsIdempotent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-hooktest-\(UUID().uuidString)")
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
            .appendingPathComponent("sich-home-\(UUID().uuidString)")
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

        let script = home.appendingPathComponent(".sich/sich-forward.sh")
        let body = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(body.contains("SICH_CARD_ID"), "self-contained forwarder written")

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

    func testGlobalUninstallRemovesOnlySichForwarder() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-home-cleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sich = "bash \(home.appendingPathComponent(".sich/sich-forward.sh").path)"
        let seed = """
        {"model":"opus","hooks":{"Stop":[{"matcher":"","hooks":[\
        {"type":"command","command":"\(sich)"},\
        {"type":"command","command":"bash ~/.claude/hooks/ntfy-stop.sh"}]}],\
        "SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"\(sich)"}]}]}}
        """
        try seed.write(to: settings, atomically: true, encoding: .utf8)

        XCTAssertTrue(HookInstaller.uninstallGlobal(home: home))
        XCTAssertFalse(HookInstaller.uninstallGlobal(home: home), "second cleanup is a no-op")

        let cfg = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual(cfg["model"] as? String, "opus")
        let hooks = try XCTUnwrap(cfg["hooks"] as? [String: Any])
        XCTAssertFalse(commands(in: hooks["Stop"]).contains(sich))
        XCTAssertTrue(commands(in: hooks["Stop"]).contains("bash ~/.claude/hooks/ntfy-stop.sh"))
        XCTAssertNil(hooks["SessionStart"], "empty Sich-only event is removed")
    }

    func testCodexShimInstallWritesWrapperAndEventHooks() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-codex-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertTrue(HookInstaller.installCodexShim(home: home))

        let shim = home.appendingPathComponent(".sich/bin/codex")
        let shimBody = try String(contentsOf: shim, encoding: .utf8)
        XCTAssertTrue(shimBody.contains("Sich Codex wrapper"))
        XCTAssertTrue(shimBody.contains("--profile"))
        XCTAssertTrue(shimBody.contains("sich-hooks"))

        let attrs = try FileManager.default.attributesOfItem(atPath: shim.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o755)

        let hook = home.appendingPathComponent(".sich/hooks/sich-codex-PermissionRequest.sh")
        let hookBody = try String(contentsOf: hook, encoding: .utf8)
        XCTAssertTrue(hookBody.contains("plutil -replace sich_agent -string codex"))
        XCTAssertTrue(hookBody.contains("plutil -replace sich_card_id"))

        let profile = home.appendingPathComponent(".codex/sich-hooks.config.toml")
        let profileBody = try String(contentsOf: profile, encoding: .utf8)
        XCTAssertTrue(profileBody.contains("[features]"))
        XCTAssertTrue(profileBody.contains("hooks = true"))
        XCTAssertTrue(profileBody.contains("[[hooks.SessionStart]]"))
        XCTAssertTrue(profileBody.contains("matcher = \"startup|resume\""))
        XCTAssertTrue(profileBody.contains("[[hooks.SubagentStart]]"))
        XCTAssertTrue(profileBody.contains("[[hooks.SubagentStop]]"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(
            ".sich/hooks/sich-codex-SubagentStart.sh").path))
        XCTAssertTrue(profileBody.contains(hook.path))
    }

    func testCodexShimInjectsHooksOnlyInsideBoundSichTerminal() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-codex-wrapper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertTrue(HookInstaller.installCodexShim(home: home))

        let realDir = home.appendingPathComponent("real-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let log = home.appendingPathComponent("codex-argv.log")
        let realCodex = realDir.appendingPathComponent("codex")
        try """
        #!/usr/bin/env bash
        : > "$SICH_TEST_ARGV_LOG"
        for arg in "$@"; do printf '%s\\n' "$arg" >> "$SICH_TEST_ARGV_LOG"; done
        exit 0
        """.write(to: realCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realCodex.path)

        let shim = home.appendingPathComponent(".sich/bin/codex")
        let baseEnv = [
            "HOME": home.path,
            "PATH": "\(shim.deletingLastPathComponent().path):\(realDir.path):/usr/bin:/bin",
            "SICH_TEST_ARGV_LOG": log.path,
        ]

        _ = try run(shim.path, ["hello"], env: baseEnv)
        XCTAssertEqual(try loggedArgs(log), ["hello"], "unbound shells pass through unchanged")

        var boundEnv = baseEnv
        boundEnv["SICH_CARD_ID"] = UUID().uuidString
        _ = try run(shim.path, ["hello"], env: boundEnv)
        let bound = try loggedArgs(log)
        XCTAssertEqual(Array(bound.prefix(3)), ["--profile", "sich-hooks", "--dangerously-bypass-hook-trust"])
        XCTAssertTrue(bound.contains("--dangerously-bypass-hook-trust"))
        XCTAssertEqual(bound.last, "hello")

        _ = try run(shim.path, ["--help"], env: boundEnv)
        XCTAssertEqual(try loggedArgs(log), ["--help"], "help/version commands must not inject hooks")
    }

    func testCodexHooksAppendCompleteJSONAtomically() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-codex-atomic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertTrue(HookInstaller.installCodexShim(home: home))

        let events = home.appendingPathComponent("events.jsonl")
        let hook = home.appendingPathComponent(
            ".sich/hooks/sich-codex-PreToolUse.sh")
        var processes: [Process] = []
        for index in 0..<24 {
            let process = Process()
            process.executableURL = hook
            var env = ProcessInfo.processInfo.environment
            env["SICH_EVENTS_FILE"] = events.path
            env["SICH_CARD_ID"] = "card-\(index)"
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let input = Pipe()
            process.standardInput = input
            try process.run()
            let payload = #"{"session_id":"session-\#(index)","cwd":"/repo","tool_name":"Bash"}"#
            input.fileHandleForWriting.write(Data(payload.utf8))
            try input.fileHandleForWriting.close()
            processes.append(process)
        }
        processes.forEach { $0.waitUntilExit() }

        let lines = try String(contentsOf: events, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 24)
        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            let session = try XCTUnwrap(object?["session_id"] as? String)
            let card = try XCTUnwrap(object?["sich_card_id"] as? String)
            XCTAssertTrue(session.hasPrefix("session-"))
            XCTAssertTrue(card.hasPrefix("card-"))
            XCTAssertEqual(object?["cwd"] as? String, "/repo")
            XCTAssertEqual(object?["tool_name"] as? String, "Bash")
        }
    }

    func testClaudeShimInstallWritesScopedWrapperWithoutGlobalSettings() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-claude-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertTrue(HookInstaller.installClaudeShim(home: home))

        let shim = home.appendingPathComponent(".sich/bin/claude")
        let shimBody = try String(contentsOf: shim, encoding: .utf8)
        XCTAssertTrue(shimBody.contains("Sich Claude wrapper"))
        XCTAssertTrue(shimBody.contains("SICH_CARD_ID"))
        XCTAssertTrue(shimBody.contains("--settings"))
        XCTAssertTrue(shimBody.contains("SessionStart"))
        XCTAssertTrue(shimBody.contains("PermissionRequest"))

        let forwarder = home.appendingPathComponent(".sich/sich-forward.sh")
        let forwarderBody = try String(contentsOf: forwarder, encoding: .utf8)
        XCTAssertTrue(forwarderBody.contains("SICH_CARD_ID"))

        let attrs = try FileManager.default.attributesOfItem(atPath: shim.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path),
            "scoped shim install must not mutate global Claude settings")
    }

    func testClaudeShimInjectsOnlyInsideBoundSichTerminal() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-claude-wrapper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertTrue(HookInstaller.installClaudeShim(home: home))

        let realDir = home.appendingPathComponent("real-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let log = home.appendingPathComponent("argv.log")
        let realClaude = realDir.appendingPathComponent("claude")
        try """
        #!/usr/bin/env bash
        : > "$SICH_TEST_ARGV_LOG"
        for arg in "$@"; do printf '%s\\n' "$arg" >> "$SICH_TEST_ARGV_LOG"; done
        exit 0
        """.write(to: realClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realClaude.path)

        let shim = home.appendingPathComponent(".sich/bin/claude")
        let baseEnv = [
            "HOME": home.path,
            "PATH": "\(shim.deletingLastPathComponent().path):\(realDir.path):/usr/bin:/bin",
            "SICH_TEST_ARGV_LOG": log.path,
        ]

        _ = try run(shim.path, ["hello"], env: baseEnv)
        XCTAssertEqual(try loggedArgs(log), ["hello"], "unbound shells pass through unchanged")

        var boundEnv = baseEnv
        boundEnv["SICH_CARD_ID"] = UUID().uuidString
        _ = try run(shim.path, ["hello"], env: boundEnv)
        let bound = try loggedArgs(log)
        XCTAssertEqual(bound.first, "--settings")
        XCTAssertTrue(bound.dropFirst(2).contains("hello"))
        XCTAssertTrue(bound[1].contains(#""SessionStart""#))
        XCTAssertTrue(bound[1].contains(#""PermissionRequest""#))
        // The board's TUI palette rides the same blob, so it lands only in bound
        // terminals — the operator's own Claude keeps whatever `/theme` set.
        let boundSettings = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(bound[1].utf8)) as? [String: Any])
        XCTAssertEqual(boundSettings["theme"] as? String, ClaudeTheme.settingsRef)

        _ = try run(shim.path, ["--help"], env: boundEnv)
        XCTAssertEqual(try loggedArgs(log), ["--help"], "help/version commands must not inject hooks")

        _ = try run(shim.path, ["--print", "hello"], env: boundEnv)
        let printArgs = try loggedArgs(log)
        XCTAssertEqual(printArgs.first, "--settings",
                       "a bound headless turn must report the same lifecycle as interactive Claude")
        XCTAssertEqual(Array(printArgs.suffix(2)), ["--print", "hello"])
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(printArgs[1].utf8)))
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

    private func run(_ executable: String, _ args: [String], env: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func loggedArgs(_ url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
    }
}
