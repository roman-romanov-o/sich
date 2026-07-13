import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

/// US-003 — resume the open window/pane tree after a quit/restart, driven through the
/// **real `BoardShell` lifecycle seams** the delegate calls (`persistOnTerminate` on
/// `applicationWillTerminate`, `restoreOnLaunch` on `applicationDidFinishLaunching`) —
/// never the store/restorer leaves directly (this repo's interaction-AC-binding rule).
/// It holds the **watcher-not-spawner** line: a restore re-opens the shell/pane only, it
/// never auto-launches `claude -p`. Every case is deterministic: an injected temp store
/// (never the real Application Support), an injected clock for `createdAt`, direct file
/// corruption for the fallback, and a spawn spy + injected liveness/cwd state for the
/// restore invariants — no wall-clock, no real agent.
///
/// - **TC-INT-020** — quit (`persistOnTerminate`) writes a versioned snapshot of the live
///   registry; launch (`restoreOnLaunch`) restores cwd + session identity for every pane.
/// - **TC-UNIT-021** — corrupt `current` → `-previous` last-known-good, never blank.
/// - **TC-UNIT-022** — the wired restore never spawns a headless agent (the spawn spy
///   proves only a plain shell is re-opened).
/// - **TC-UNIT-025** — schema version mismatch → ignore & start clean, never crash.
/// - **TC-UNIT-026** — dead process → pane restored closed; cwd gone → home fallback.
@MainActor
@Suite(.serialized)
struct SessionResumeTests {

    // MARK: - Fixtures

    /// A per-case temp directory standing in for Application Support — tests never
    /// write to the real store.
    private func makeSnapshotDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostling-resume-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func pane(
        cwd: String, agent: AgentType = .shell, pid: Int32? = 100
    ) -> PaneSnapshot {
        PaneSnapshot(
            sessionID: UUID(), cwd: cwd, agentType: agent, flowTag: .interactive, childPID: pid
        )
    }

    /// A restorer that records every re-open request instead of launching, so an
    /// assertion can prove exactly what the wired path would spawn.
    private func spyingRestorer(
        spy: @escaping (RestoredPane, [String]) -> Void,
        isAlive: @escaping (Int32) -> Bool = { _ in true },
        directoryExists: @escaping (String) -> Bool = { _ in true },
        home: String = "/Users/tester"
    ) -> SessionRestorer {
        SessionRestorer(
            isAlive: isAlive, directoryExists: directoryExists,
            homeDirectory: home, shellPath: "/bin/zsh", reopen: spy
        )
    }

    /// A demo-stub seed (prints a banner then idles on `cat`, so the PTY stays live for
    /// the snapshot) rooted in a real temp working dir — never `claude -p`.
    private func demoSeed(id: String, dir: URL, agent: CardAgent, flow: CardFlow) -> BoardSeed {
        BoardSeed(
            sessionID: id, projectDir: dir.path, agent: agent,
            flow: flow, state: .idle, scrollback: ""
        )
    }

    // MARK: - TC-INT-020: quit writes a snapshot, launch restores it

    @Test func quitWritesSnapshot_launchRestores() throws {
        let storeDir = makeSnapshotDir()
        let workA = makeSnapshotDir()
        let workB = makeSnapshotDir()
        defer { cleanup(storeDir); cleanup(workA); cleanup(workB) }

        // A running board with two live panes in distinct dirs (varied agent + flow).
        let shell = BoardShell(seeds: [
            demoSeed(id: "resume-a", dir: workA, agent: .claude, flow: .b),
            demoSeed(id: "resume-b", dir: workB, agent: .codex, flow: .a),
        ])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }  // SIGTERM the forked demo shells — no leak

        // Quit: drive the real `applicationWillTerminate` seam into the injected store.
        let store = SessionSnapshotStore(directory: storeDir, now: { self.fixedDate })
        let saved = try #require(shell.persistOnTerminate(store: store))
        #expect(saved.version == SessionSnapshot.currentVersion)
        #expect(saved.createdAt == fixedDate)
        let savedIDs = Set(saved.windows.flatMap { $0.panes.map(\.sessionID) })
        #expect(savedIDs.count == 2)

        // Launch: drive the real `applicationDidFinishLaunching` restore seam on a fresh
        // board — every pre-quit pane comes back (cwd + session identity), re-opened live.
        var reopened: [(RestoredPane, [String])] = []
        let relaunched = BoardShell()
        let restored = relaunched.restoreOnLaunch(
            store: SessionSnapshotStore(directory: storeDir),
            restorer: spyingRestorer(spy: { reopened.append(($0, $1)) })
        )

        #expect(restored.count == 2)
        // The registry is a dictionary (no stable pane order), so assert the set of the
        // pre-quit cwds + identities survives the round-trip, not a positional layout.
        #expect(Set(restored.map(\.snapshot.cwd)) == Set([workA.path, workB.path]))
        #expect(Set(restored.map(\.snapshot.sessionID)) == savedIDs)
        #expect(restored.allSatisfy { $0.liveness == .reopened })
        #expect(restored.allSatisfy { !$0.cwdFellBackToHome })
        #expect(reopened.count == 2)  // both panes re-opened as live shells
    }

    // MARK: - TC-UNIT-021: corrupt current → -previous fallback (via the launch seam)

    @Test func corruptCurrent_fallsBackToPrevious() throws {
        let dir = makeSnapshotDir()
        defer { cleanup(dir) }
        let store = SessionSnapshotStore(directory: dir, now: { self.fixedDate })
        let shell = BoardShell()

        let good = [WindowSnapshot(panes: [pane(cwd: "/tmp/good")])]
        _ = try store.save(windows: good)
        // A first launch reads the good current and promotes it to -previous.
        var firstReopen: [[String]] = []
        _ = shell.restoreOnLaunch(store: store, restorer: spyingRestorer(spy: { firstReopen.append($1) }))
        #expect(firstReopen.count == 1)

        // A later quit half-writes / a bit-rots the current file.
        try Data("{ not valid json".utf8).write(to: store.currentURL)

        // Next launch through the seam falls back to the last-known-good — not blank, no crash.
        var recovered: [RestoredPane] = []
        recovered = shell.restoreOnLaunch(store: store, restorer: spyingRestorer(spy: { _, _ in }))
        #expect(recovered.map(\.snapshot.cwd) == ["/tmp/good"])
    }

    // MARK: - TC-UNIT-022: the wired restore never spawns a headless agent (the invariant)

    @Test func restore_neverSpawnsHeadless() throws {
        let dir = makeSnapshotDir()
        defer { cleanup(dir) }
        let store = SessionSnapshotStore(directory: dir)
        let shell = BoardShell()

        // The pane HAD an agent (claude) running and its process is still alive.
        let agentPane = pane(cwd: "/tmp/agent", agent: .claude, pid: 4242)
        _ = try store.save(windows: [WindowSnapshot(panes: [agentPane])])

        var spawned: [[String]] = []
        let restored = shell.restoreOnLaunch(
            store: store,
            restorer: spyingRestorer(spy: { spawned.append($1) }, isAlive: { _ in true })
        )

        // The pane is re-opened as a shell/pane — the agent is the operator's to resume.
        #expect(restored.count == 1)
        #expect(restored[0].liveness == .reopened)
        #expect(!spawned.isEmpty)

        // Not one re-open is a headless agent: no `claude`, no `-p`/`--print`.
        for command in spawned {
            let joined = command.joined(separator: " ")
            #expect(!joined.contains("claude -p"))
            #expect(!command.contains("-p"))
            #expect(!command.contains("--print"))
            #expect((command.first.map { ($0 as NSString).lastPathComponent }) != "claude")
        }
    }

    // MARK: - TC-UNIT-025: schema version mismatch → ignore & start clean

    @Test func versionMismatch_ignoredNotCrash() throws {
        let dir = makeSnapshotDir()
        defer { cleanup(dir) }
        let store = SessionSnapshotStore(directory: dir)
        let shell = BoardShell()

        // A snapshot written by an older/newer build — parses fine, wrong version.
        let stale = SessionSnapshot(
            createdAt: fixedDate, version: SessionSnapshot.currentVersion + 99,
            windows: [WindowSnapshot(panes: [pane(cwd: "/tmp/stale")])]
        )
        try store.save(stale)

        // Ignored (no -previous to fall back to) → start clean through the seam, never crash.
        var spawned: [[String]] = []
        let restored = shell.restoreOnLaunch(store: store, restorer: spyingRestorer(spy: { spawned.append($1) }))
        #expect(restored.isEmpty)
        #expect(spawned.isEmpty)
    }

    // MARK: - TC-UNIT-026: dead process restores closed; cwd gone → home fallback

    @Test func deadProcess_restoresAsClosed() throws {
        let dir = makeSnapshotDir()
        defer { cleanup(dir) }

        // Edge case 3: the recorded process didn't survive → restore as closed/dead,
        // and re-open nothing for it (not a live-but-frozen terminal).
        let deadStore = SessionSnapshotStore(directory: dir.appendingPathComponent("dead"))
        _ = try deadStore.save(windows: [WindowSnapshot(panes: [pane(cwd: "/tmp/existing", agent: .claude, pid: 9999)])])
        let deadShell = BoardShell()
        var deadSpawns: [[String]] = []
        let deadRestored = deadShell.restoreOnLaunch(
            store: deadStore,
            restorer: spyingRestorer(spy: { deadSpawns.append($1) }, isAlive: { _ in false })
        )
        #expect(deadRestored[0].liveness == .dead)
        #expect(deadSpawns.isEmpty)  // closed → nothing re-opened

        // Edge case 2: the pane's cwd was deleted between sessions → point it at a
        // safe home fallback, flagged, and still re-open (alive process).
        let goneStore = SessionSnapshotStore(directory: dir.appendingPathComponent("gone"))
        _ = try goneStore.save(windows: [WindowSnapshot(panes: [pane(cwd: "/was/deleted", agent: .shell, pid: 7)])])
        let goneShell = BoardShell()
        var liveSpawns: [[String]] = []
        let goneRestored = goneShell.restoreOnLaunch(
            store: goneStore,
            restorer: spyingRestorer(
                spy: { liveSpawns.append($1) }, isAlive: { _ in true },
                directoryExists: { $0 != "/was/deleted" }, home: "/Users/tester"
            )
        )
        #expect(goneRestored[0].liveness == .reopened)
        #expect(goneRestored[0].cwdFellBackToHome)
        #expect(goneRestored[0].cwd == "/Users/tester")
        #expect(liveSpawns.count == 1)
    }

    // MARK: - TC-UNIT-027 — deterministic Claude conversation resume

    /// The start command PINS our own id (so we own it up front, no hook-scraping),
    /// and the restart command replays that EXACT id with a fresh-claude fallback — the
    /// round-trip that makes restart-resume deterministic. Neither is print-mode headless.
    @Test("start pins --session-id; restart resumes the same id, lowercased, with fallback")
    func claudeResumeCommandsArePinnedAndReversible() {
        let id = UUID(uuidString: "AABBCCDD-1122-3344-5566-778899AABBCC")!
        let lower = id.uuidString.lowercased()
        let start = BoardShell.startClaudeCommand(sessionID: id)
        let resume = BoardShell.resumeClaudeCommand(sessionID: id)
        #expect(start == "claude --session-id \(lower)\n")
        #expect(resume == "claude --resume \(lower) 2>/dev/null || claude\n")
        // Firewall stays clean: we never auto-spawn a headless print-mode agent.
        #expect(!start.contains("--print") && !start.contains(" -p"))
        #expect(!resume.contains("--print") && !resume.contains(" -p"))
    }

    /// A pane's pinned Claude id survives the persist→restore JSON round-trip (so a
    /// restart CAN resume it); a bare-shell pane persists nil. And a pre-resume snapshot
    /// with no such key still decodes (→ nil) — the back-compat that skips a version bump.
    @Test("claudeSessionID round-trips through the store; a legacy snapshot decodes it nil")
    func claudeSessionIDRoundTripsAndBackCompatDecodesNil() throws {
        let claudeID = UUID()
        let dir = try makeSnapshotDir()
        let store = SessionSnapshotStore(directory: dir, now: { self.fixedDate })
        _ = try store.save(windows: [WindowSnapshot(panes: [
            PaneSnapshot(sessionID: UUID(), cwd: "/w", agentType: .claude,
                         flowTag: .interactive, childPID: 1, claudeSessionID: claudeID),
            pane(cwd: "/bare", agent: .shell, pid: 2), // no claudeSessionID → nil
        ])])
        let back = try #require(store.load())
        let panes = try #require(back.windows.first?.panes)
        #expect(panes[0].claudeSessionID == claudeID)
        #expect(panes[1].claudeSessionID == nil)

        // A pre-resume v1 snapshot: the JSON has no claudeSessionID key at all → nil.
        let legacy = #"{"createdAt":0,"version":1,"windows":[{"panes":[{"agentType":"claude","childPID":1,"cwd":"/w","flowTag":"interactive","sessionID":"\#(UUID().uuidString)"}]}]}"#
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.windows.first?.panes.first?.claudeSessionID == nil)
    }
}
