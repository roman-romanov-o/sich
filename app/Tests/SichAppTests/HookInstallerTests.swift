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

    func testCursorInstallWritesShimsHookAndMergesUserHooksJSONIdempotently() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-cursor-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".cursor/hooks.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"hooks":{"stop":[{"command":"/usr/local/bin/mine.sh"}]}}"#.utf8).write(to: config)

        XCTAssertTrue(HookInstaller.installCursorHooks(home: home))

        for name in ["agent", "cursor-agent"] {
            let shim = home.appendingPathComponent(".sich/bin/\(name)")
            let body = try String(contentsOf: shim, encoding: .utf8)
            XCTAssertTrue(body.contains("Sich Cursor wrapper"))
            let attrs = try FileManager.default.attributesOfItem(atPath: shim.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        }
        let hook = home.appendingPathComponent(".sich/hooks/sich-cursor.sh")
        XCTAssertTrue(try String(contentsOf: hook, encoding: .utf8).contains("plutil -replace sich_agent -string cursor"))

        func hooks() throws -> [String: [[String: Any]]] {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
            return try XCTUnwrap(object?["hooks"] as? [String: [[String: Any]]])
        }
        let merged = try hooks()
        for event in ["sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure",
                      "subagentStart", "subagentStop", "preCompact", "stop", "sessionEnd"] {
            XCTAssertTrue(merged[event]?.contains { $0["command"] as? String == hook.path } == true, event)
        }
        XCTAssertEqual(merged["stop"]?.first?["command"] as? String, "/usr/local/bin/mine.sh", "user hooks survive")

        XCTAssertTrue(HookInstaller.installCursorHooks(home: home))
        XCTAssertEqual(try hooks()["stop"]?.count, 2, "second install adds nothing")
    }

    func testCursorHookIsSilentOutsideASichTerminalAndStampsInsideOne() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-cursor-hook-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertTrue(HookInstaller.installCursorHooks(home: home))
        let events = home.appendingPathComponent("events.jsonl")
        let hook = home.appendingPathComponent(".sich/hooks/sich-cursor.sh")
        let payload = #"{"hook_event_name":"stop","conversation_id":"conv","workspace_roots":["/repo"]}"#

        func fire(cardID: String?) throws {
            let process = Process()
            process.executableURL = hook
            var env = ["PATH": "/usr/bin:/bin", "SICH_EVENTS_FILE": events.path, "HOME": home.path]
            env["SICH_CARD_ID"] = cardID
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(Data(payload.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }

        try fire(cardID: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: events.path), "unbound Cursor runs emit nothing")

        try fire(cardID: "card-7")
        let line = try String(contentsOf: events, encoding: .utf8).split(separator: "\n").first
        let object = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(line).utf8)) as? [String: Any]
        XCTAssertEqual(object?["sich_agent"] as? String, "cursor")
        XCTAssertEqual(object?["sich_card_id"] as? String, "card-7")
        XCTAssertEqual(object?["conversation_id"] as? String, "conv")
        XCTAssertEqual(object?["hook_event_name"] as? String, "stop")
    }

    func testAntigravityInstallWritesShimHookAndMergesNamedEntryIdempotently() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-agy-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".gemini/config/hooks.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mine":{"Stop":[{"type":"command","command":"mine.sh"}]}}"#.utf8).write(to: config)

        XCTAssertTrue(HookInstaller.installAntigravityHooks(home: home))

        let shim = home.appendingPathComponent(".sich/bin/agy")
        XCTAssertTrue(try String(contentsOf: shim, encoding: .utf8).contains("Sich Antigravity wrapper"))
        let attrs = try FileManager.default.attributesOfItem(atPath: shim.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        let hook = home.appendingPathComponent(".sich/hooks/sich-antigravity.sh")
        XCTAssertTrue(try String(contentsOf: hook, encoding: .utf8).contains("plutil -replace sich_agent -string antigravity"))

        func entries() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        }
        let merged = try entries()
        XCTAssertNotNil(merged["mine"], "user entries survive")
        let sich = try XCTUnwrap(merged["sich"] as? [String: Any])
        XCTAssertNil(sich["PreToolUse"], "PreToolUse demands a permission decision — never hooked")
        for event in ["PreInvocation", "PostInvocation", "Stop"] {
            let handler = try XCTUnwrap((sich[event] as? [[String: Any]])?.first, event)
            XCTAssertEqual(handler["command"] as? String, "'\(hook.path)' \(event)")
        }
        let post = try XCTUnwrap((sich["PostToolUse"] as? [[String: Any]])?.first)
        XCTAssertEqual(post["matcher"] as? String, "*")
        XCTAssertEqual(((post["hooks"] as? [[String: Any]])?.first?["command"]) as? String, "'\(hook.path)' PostToolUse")

        let before = try Data(contentsOf: config)
        XCTAssertTrue(HookInstaller.installAntigravityHooks(home: home))
        XCTAssertEqual(try Data(contentsOf: config), before, "second install rewrites nothing")
    }

    func testAntigravityHookStampsTheEventNameItWasCalledWith() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-agy-hook-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertTrue(HookInstaller.installAntigravityHooks(home: home))
        let events = home.appendingPathComponent("events.jsonl")
        let hook = home.appendingPathComponent(".sich/hooks/sich-antigravity.sh")
        let payload = #"{"conversationId":"agy-conv","workspacePaths":["/repo"],"modelName":"gemini-3-pro"}"#

        func fire(cardID: String?) throws {
            let process = Process()
            process.executableURL = hook
            process.arguments = ["Stop"]
            var env = ["PATH": "/usr/bin:/bin", "SICH_EVENTS_FILE": events.path, "HOME": home.path]
            env["SICH_CARD_ID"] = cardID
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(Data(payload.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }

        try fire(cardID: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: events.path), "unbound agy runs emit nothing")

        try fire(cardID: "card-9")
        let line = try String(contentsOf: events, encoding: .utf8).split(separator: "\n").first
        let object = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(line).utf8)) as? [String: Any]
        XCTAssertEqual(object?["hook_event_name"] as? String, "Stop", "the payload has no name — the script stamps $1")
        XCTAssertEqual(object?["sich_agent"] as? String, "antigravity")
        XCTAssertEqual(object?["sich_card_id"] as? String, "card-9")
        XCTAssertEqual(object?["conversationId"] as? String, "agy-conv")
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
