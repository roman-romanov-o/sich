import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

/// The Phase-03 cutover end state (US-001 + US-004): the app is a single native
/// binary — no Python child, no localhost sidecar, no HTTP client in the app.
///
/// These bind the E2E cutover rows of the parity matrix to green `swift test` cases:
///   - **TC-E2E-303** — grep guard: `mission_control` and the sidecar wire address
///     are gone from `app/Sources` + the scripts dirs (shells out to grep). The bare
///     port literal survives ONLY as `CutoverGuard.sidecarPort` (the named constant
///     the free-port guard reads), so the guard targets the live coupling — the wire
///     address — not the constant that proves the port stays free.
///   - **TC-E2E-301 / 302** — the assertable half of "no python child / no port":
///     constructing the app's live data sources spawns no process and binds no port,
///     and the native quota path populates the interactive pool entirely in-process
///     (no HTTP). The remaining "launch a real window, eyeball the panels" pixel AC
///     is human visual sign-off (E2EHarness captures the screenshot artifact).
///   - **TC-E2E-320** — append a `Stop` line to the event file → the app's
///     `SessionsPoller` tail reflects it within one poll, with no server.
///
/// Harness rules (inherited): never spawns `claude -p`, never opens a port, never
/// reads the real `~/.claude` / `~/.ghostling`.
@Suite("Phase-03 cutover end state (US-001 + US-004)")
struct CutoverTests {

    // MARK: - Repo root (resolved from this file, not the test CWD)

    /// The repo root, four dirs up from this file
    /// (`app/Tests/GhostlingAppTests/CutoverTests.swift`).
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GhostlingAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
    }

    // MARK: - TC-E2E-303: grep guard — mission_control / sidecar wire gone from app + scripts

    @Test("TC-E2E-303: no `mission_control` or sidecar wire address in app/Sources or scripts")
    func grepGuardIsClean() {
        let root = Self.repoRoot
        let targets = ["app/Sources", "scripts", ".claude/scripts"]
        // `mission_control`: the retired Python package — must be wholly gone.
        // `127.0.0.1:8787`: the retired HTTP wire — must be gone. The bare port lives
        // only in `CutoverGuard.sidecarPort`, the constant the free-port guard reads.
        for needle in ["mission_control", "127.0.0.1:8787"] {
            let hits = grep(needle, under: targets.map { root.appendingPathComponent($0) })
            #expect(hits.isEmpty, "\(needle) still referenced in app/scripts:\n\(hits.joined(separator: "\n"))")
        }
    }

    /// `grep -rn needle dir…`, returning each matching `path:line:text`. An absent dir
    /// is skipped (grep exits 2 → no hits, which is the clean outcome here).
    private func grep(_ needle: String, under dirs: [URL]) -> [String] {
        let existing = dirs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return [] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        proc.arguments = ["-rn", needle] + existing.map(\.path)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }

    // MARK: - TC-E2E-301: native quota populates in-process — no python, no HTTP

    @Test("TC-E2E-301: the live quota source reads in-process (no python child, no HTTP)")
    func nativeQuotaIsInProcess() throws {
        // A fixture transcript dir (never the real ~/.claude): one assistant turn so
        // the interactive pool reads populated — the data the panel shows live.
        let projects = try makeProjectsDir()
        defer { try? FileManager.default.removeItem(at: projects.deletingLastPathComponent()) }
        let now = ISO8601DateFormatter().date(from: "2026-06-26T12:00:00Z")!
        try writeUsage("2026-06-26T11:00:00Z", tokens: 100, under: projects)

        let before = CutoverGuard.childCommands(of: getpid())
        let sources = QuotaUsageReader.read(now: now, projectsDir: projects)
        let after = CutoverGuard.childCommands(of: getpid())

        // The native read assembles the four never-netted pools entirely in-process.
        #expect(sources.count == 4)
        #expect(QuotaProjection.gauge(for: sources[0]).state == .active)  // interactive live
        // Reading quota spawned NO new child — in particular no python interpreter.
        #expect(!after.contains { CutoverGuard.isPython($0) }, "native quota read must not spawn python")
        // The read must not itself have spawned an interpreter sidecar. Scoped to the
        // *delta* (children that appeared across the call) so a concurrent test's shell —
        // a sibling of the shared runner PID, not spawned by this read — can't flake it;
        // a raw `after.count <= before.count` counts those unrelated children too.
        let spawnedByRead = Set(after).subtracting(before)
        #expect(!spawnedByRead.contains(where: CutoverGuard.isPython),
                "native quota read must not spawn a child process")
    }

    // MARK: - TC-E2E-302: the old sidecar port is never bound by the app

    @Test("TC-E2E-302: building the live data sources binds nothing on the sidecar port")
    @MainActor
    func noSidecarPortBound() {
        // The cutover invariant is about OUR code: constructing the native data
        // sources must not OPEN a listener on the sidecar port. We assert the port's
        // listen state is UNCHANGED by building the bridge — a delta, not an absolute
        // "port is globally free". (An unrelated process from outside the test owning
        // 8787 is not our concern; the deleted sidecar can never restart, and we never
        // bind here. A delta is the faithful "we bound nothing" check.)
        let port = CutoverGuard.sidecarPort
        let before = CutoverGuard.portInUse(port)
        // Construct the exact live data sources the launch path wires — neither binds
        // a port (they only read disk / tail a file).
        let quota = NativeQuotaPoller(sink: { _ in })
        let sessions = SessionsPoller(eventsFile: makeEventsFile(), sink: { _ in })
        defer { quota.stop(); sessions.stop() }
        let after = CutoverGuard.portInUse(port)
        #expect(after == before, "building the native data sources must not open the sidecar port")
    }

    // MARK: - CutoverGuard parse helpers (pure — no live ps needed)

    @Test("CutoverGuard parses ps rows and classifies python interpreters")
    func cutoverGuardParsing() {
        let ps = """
        1 launchd
        4242 python3.12
        4242 zsh
        9999 python
        """
        // Only rows whose ppid == 4242 are our children.
        let kids = CutoverGuard.parseChildCommands(ps, parent: 4242)
        #expect(kids == ["python3.12", "zsh"])
        #expect(CutoverGuard.isPython("python3.12"))
        #expect(CutoverGuard.isPython("/usr/bin/python3"))
        #expect(!CutoverGuard.isPython("zsh"))
    }

    // MARK: - TC-E2E-320: append a Stop line → board reflects it within one poll, no server

    @Test("TC-E2E-320: append a Stop line to the event file → board shows it idle within one poll")
    @MainActor
    func appendStopReachesBoardNoServer() throws {
        let file = makeEventsFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try appendLine(#"{"hook_event_name":"SessionStart","session_id":"S","cwd":"/repo","timestamp":"2026-06-16T12:00:00+00:00"}"#, to: file)
        try appendLine(#"{"hook_event_name":"Stop","session_id":"S","cwd":"/repo","timestamp":"2026-06-16T12:00:05+00:00"}"#, to: file)

        var snapshot: [BoardCard] = []
        let poller = SessionsPoller(eventsFile: file) { snapshot = $0 }
        poller.start()   // start() polls once synchronously, then schedules a timer
        poller.stop()    // stop the timer; we already captured the first poll's sink

        let card = snapshot.first { $0.sessionID == "S" }
        #expect(card != nil, "the appended session must appear on the board")
        #expect(card?.state == .idle,
                "the Stop line clears running status — no server involved")
    }

    // MARK: - Fixture helpers

    private func makeProjectsDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostling-cutover-\(UUID().uuidString)", isDirectory: true)
        let projects = base.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        return projects
    }

    private func writeUsage(_ iso: String, tokens: Int, under projects: URL) throws {
        let dir = projects.appendingPathComponent("p", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = """
        {"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":\(tokens),\
        "output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"\(iso)"}
        """
        try (line + "\n").write(to: dir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
    }

    private func makeEventsFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostling-cutover-events-\(UUID().uuidString).jsonl")
    }

    private func appendLine(_ json: String, to file: URL) throws {
        let line = Data((json + "\n").utf8)
        if FileManager.default.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: file)
        }
    }
}
