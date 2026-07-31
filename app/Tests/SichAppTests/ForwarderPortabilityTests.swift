import XCTest

@testable import SichApp

/// ts-int-01 / US-002.AC-1 — the hook forwarder must produce turn diffs on a
/// GNU/Linux host, not only on macOS.
///
/// Two halves, and they are load-bearing together:
///
///  1. **Structural** — the script may name no macOS-only tool (`plutil`) and no
///     absolute `/usr/bin/…` tool path. An absolute path cannot be jailed by a
///     test on macOS (it resolves whatever PATH says), so this is the only way to
///     prove the script does not depend on the host being a Mac.
///  2. **Behavioural** — given (1), running the script with a PATH that contains
///     only GNU-semantics tools IS running it under GNU userland. The jail
///     supplies a `base64` that wraps at 76 columns (GNU's default, which macOS'
///     does not do) and records that it was invoked, and a `plutil` that must
///     never be invoked.
///
/// RED FIRST: today three `/usr/bin/plutil -extract` calls gate the entire
/// turn-diff block, so under GNU they fail, `session`/`cwd` come back empty and
/// diffs are SILENTLY skipped while the raw append still succeeds.
final class ForwarderPortabilityTests: XCTestCase {

    func testForwarderNamesNoMacOnlyTool() {
        let body = HookInstaller.forwarderBody
        XCTAssertFalse(
            body.contains("plutil"),
            "plutil does not exist under GNU userland — it would silently skip every turn diff")
        let absolute = body.split(separator: "\n").filter {
            $0.contains("/usr/bin/") && !$0.contains("/usr/bin/env")
        }
        XCTAssertTrue(
            absolute.isEmpty,
            "absolute macOS tool paths do not resolve on a Linux host: \(absolute)")
    }

    /// The whole point: a real POSIX shell runs the REAL forwarder over real hook
    /// payloads, and the emitted line is asserted field by field.
    func testTurnDiffIsWellFormedUnderGnuUserland() throws {
        let jail = try Jail()
        defer { jail.tearDown() }

        try jail.runForwarder(event: "UserPromptSubmit")
        try "hello from the turn\n".write(
            to: jail.repo.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)
        try jail.runForwarder(event: "Stop")

        let diff = try XCTUnwrap(jail.turnDiffLine(), """
            no turn_diff line was emitted under GNU userland — the parse gate skipped it
            """)
        XCTAssertEqual(diff["session_id"] as? String, jail.session)
        XCTAssertEqual((diff["iteration"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(try decoded(diff, "cwd_base64"), jail.repo.path)
        XCTAssertTrue(
            try decoded(diff, "diff_base64").contains("hello from the turn"),
            "the unified diff must carry the turn's edit")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: jail.base64Marker.path),
            "base64 was not resolved through PATH — an absolute macOS path bypassed the jail")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: jail.plutilMarker.path),
            "the forwarder invoked plutil, which no Linux host has")
    }

    private func decoded(_ line: [String: Any], _ key: String) throws -> String {
        let raw = try XCTUnwrap(line[key] as? String, "\(key) missing")
        let data = try XCTUnwrap(Data(base64Encoded: raw), "\(key) is not valid base64")
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    // MARK: - the GNU jail

    /// A temp tree whose PATH contains ONLY the tools a GNU host would offer, with
    /// `base64` wrapping at 76 columns the way GNU coreutils does.
    private struct Jail {
        let root: URL
        let home: URL
        let repo: URL
        let bin: URL
        let script: URL
        let session = "ab12-cd34-ef56"

        var events: URL { home.appendingPathComponent(".sich/events.jsonl") }
        var base64Marker: URL { root.appendingPathComponent("base64.used") }
        var plutilMarker: URL { root.appendingPathComponent("plutil.used") }

        /// Everything the forwarder (and the fixture shims) may reach. `plutil` is
        /// deliberately absent — that is the GNU userland fact under test.
        private static let tools = [
            "sh", "bash", "cat", "cp", "date", "dirname", "fold", "git", "head",
            "mkdir", "mv", "printf", "rm", "sed", "tr", "wc",
        ]

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sich-gnu-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            repo = root.appendingPathComponent("repo", isDirectory: true)
            bin = root.appendingPathComponent("bin", isDirectory: true)
            script = root.appendingPathComponent("sich-forward.sh")
            for dir in [home, repo, bin] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try HookInstaller.forwarderBody.write(to: script, atomically: true, encoding: .utf8)
            try linkTools()
            try writeShims()
            try seedRepo()
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }

        private func linkTools() throws {
            for tool in Self.tools {
                guard let source = Self.locate(tool) else {
                    throw Failure.missingTool(tool)
                }
                try FileManager.default.createSymbolicLink(
                    at: bin.appendingPathComponent(tool), withDestinationURL: source)
            }
        }

        private static func locate(_ tool: String) -> URL? {
            ["/bin", "/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"]
                .map { URL(fileURLWithPath: $0).appendingPathComponent(tool) }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }

        /// `base64` wraps at 76 columns (GNU's default) and records its use; `plutil`
        /// records its use and fails, the way a missing tool would.
        private func writeShims() throws {
            try write(shim: "base64", body: """
                /usr/bin/touch "\(base64Marker.path)"
                /usr/bin/base64 "$@" | /usr/bin/fold -w 76
                """)
            try write(shim: "plutil", body: """
                /usr/bin/touch "\(plutilMarker.path)"
                exit 1
                """)
        }

        private func write(shim name: String, body: String) throws {
            let path = bin.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path.path)
        }

        private func seedRepo() throws {
            try "start\n".write(
                to: repo.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)
            try git(["init", "-q"])
            try git(["config", "user.email", "test@sich.local"])
            try git(["config", "user.name", "Sich Test"])
            try git(["add", "-A"])
            try git(["commit", "-q", "-m", "seed"])
        }

        private func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo.path] + args
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw Failure.gitFailed(args.joined(separator: " "), process.terminationStatus)
            }
        }

        /// Run the real forwarder with a real hook payload on stdin, under the jail.
        func runForwarder(event: String) throws {
            let process = Process()
            process.executableURL = bin.appendingPathComponent("bash")
            process.arguments = [script.path]
            process.environment = environment
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(Data(payload(event: event).utf8))
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
        }

        /// Only PATH and HOME — no inherited tool locations, so the jail is the
        /// script's whole world. DEVELOPER_DIR is kept because macOS' `git` is an
        /// xcrun shim; it points at a toolchain, not at extra userland tools.
        private var environment: [String: String] {
            var env = ["PATH": bin.path, "HOME": home.path]
            if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
                env["DEVELOPER_DIR"] = developer
            }
            return env
        }

        private func payload(event: String) -> String {
            """
            {"session_id":"\(session)","transcript_path":"/tmp/t.jsonl",\
            "cwd":"\(repo.path)","hook_event_name":"\(event)","prompt":"make the edit"}
            """
        }

        func turnDiffLine() -> [String: Any]? {
            guard let body = try? String(contentsOf: events, encoding: .utf8) else { return nil }
            return body.split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                .compactMap { $0 as? [String: Any] }
                .last { $0["sich_event_type"] as? String == "turn_diff" }
        }

        enum Failure: Error {
            case missingTool(String)
            case gitFailed(String, Int32)
        }
    }
}
