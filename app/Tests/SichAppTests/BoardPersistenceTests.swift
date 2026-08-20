import Foundation
import SichCore
import Testing

@testable import SichApp

/// "My kanban tasks don't survive `swift run` → restart." The named-title round-trip
/// is already covered by ``SessionResumeTests``; these cases pin the three gaps that
/// survived it, each driven through the REAL quit→restart seams (`persistOnTerminate`
/// / `restoreOnLaunch`), never the store or restorer leaves directly.
///
/// - **Column state** — a card restored to `.idle` regardless of the column it was in,
///   because `CardState` was never persisted.
/// - **Card identity + binding** — a restored card was minted a FRESH `id` and its shell
///   re-opened with no `SICH_CARD_ID`, so the hook feed could never bind an observed
///   claude session back to it: the card was frozen for the rest of the app's life.
/// - **Liveness across the restart boundary** — liveness was probed from a `childPID`
///   recorded at quit, which is by construction dead on the next launch (we SIGTERM every
///   shell on the way out). Only leaked SIGTERM-ignoring login shells kept restore working
///   at all; once reaped, every pane restored `.dead` and the board came back empty.
@MainActor
@Suite(.serialized)
struct BoardPersistenceTests {

    // MARK: - Fixtures

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-persist-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    /// A restorer that records re-open requests instead of launching, so a case can
    /// assert exactly what the wired path *would* spawn.
    private func spyingRestorer(
        spy: @escaping (RestoredPane, [String]) -> Void,
        isAlive: @escaping (Int32) -> Bool = { _ in true }
    ) -> SessionRestorer {
        SessionRestorer(
            isAlive: isAlive, directoryExists: { _ in true },
            homeDirectory: "/Users/tester", shellPath: "/bin/zsh", reopen: spy
        )
    }

    /// A real login-shell card (the production `liveTerminal` shape: a live PTY carrying
    /// `SICH_CARD_ID`), parked in the given column.
    private func liveSeed(dir: URL, cardID: UUID, state: CardState) -> BoardSeed {
        var seed = BoardSeed.liveTerminal(
            projectDir: dir.path, sessionID: "persist-\(cardID.uuidString.prefix(8))",
            title: "Fix login redirect", cardID: cardID.uuidString, agent: .claude
        )
        seed = BoardSeed(
            sessionID: seed.sessionID, title: seed.title, projectDir: seed.projectDir,
            agent: seed.agent, flow: seed.flow, state: state, scrollback: seed.scrollback,
            commandOverride: seed.command, cardID: seed.cardID, taskFolder: seed.taskFolder
        )
        return seed
    }

    // MARK: - Gap 1: the column a card was in

    @Test("a non-manual WIP card restarts in queue")
    func nonManualWipCardRestartsInQueue() throws {
        let storeDir = makeTempDir()
        let work = makeTempDir()
        defer { cleanup(storeDir); cleanup(work) }

        // A detector/agent state from the previous app run is not durable intent.
        // After restart the task starts in QUEUE until fresh WORKING activity occurs
        // in this app session.
        let cardID = UUID()
        let shell = BoardShell(seeds: [liveSeed(dir: work, cardID: cardID, state: .waitingForInput)])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }

        let store = SessionSnapshotStore(directory: storeDir)
        let saved = try #require(shell.persistOnTerminate(store: store))
        let pane = try #require(saved.windows.flatMap(\.panes).first)
        #expect(pane.cardState == .idle)

        let relaunched = BoardShell()
        defer { relaunched.e2eTeardown() }
        let restored = relaunched.restoreCardsForTesting(
            store: SessionSnapshotStore(directory: storeDir)
        )
        let card = try #require(restored.first)
        #expect(card.state == .idle)
    }

    @Test("a card explicitly moved to DONE survives restart through the book, not a pane")
    func manuallyDoneCardSurvivesRestart() throws {
        let storeDir = makeTempDir()
        let bookDir = makeTempDir()
        let work = makeTempDir()
        defer { cleanup(storeDir); cleanup(bookDir); cleanup(work) }

        // An operator-created card (not a seed — seeds are fixtures the book
        // deliberately ignores), spawned onto a stubbed /bin/cat pty.
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        shell.taskStore = BoardTaskStore(directory: bookDir)
        shell.launchOverrideForTesting = { seed in
            let pty = try! PTYSession(command: ["/bin/cat"])
            try! pty.start()
            return Session(projectDir: seed.projectDir, agentType: .claude,
                           flowTag: .interactive, pty: pty, state: .running)
        }
        defer { shell.e2eTeardown() }
        let card = try #require(
            shell.createSession(title: "Fix login redirect", projectDir: work.path))
        let cardID = card.id
        shell.move(cardID: cardID, to: .done)

        // Checklist 18.08 item 1: DONE closes the terminal, so the quit snapshot
        // rightly carries NO pane for a finished task — nothing left to keep alive
        // or re-spawn. Done-ness survives restart through the durable task book
        // instead, where the next launch archives it
        // (``ArchiveTests/doneTaskArchivesOnRelaunch`` proves that leg).
        let store = SessionSnapshotStore(directory: storeDir)
        let saved = shell.persistOnTerminate(store: store)
        #expect((saved?.windows.flatMap(\.panes) ?? []).isEmpty,
                "a finished task holds no shell at quit and books no pane")

        let record = try #require(
            BoardTaskStore(directory: bookDir).load()?.tasks.first { $0.id == cardID })
        #expect(record.placement == .board(.done),
                "the book still says DONE — restart archives the task instead of losing it")
    }

    // MARK: - Gap 2: card identity + the hook binding

    @Test("a restored card keeps its id, so the hook feed can still bind to it")
    func cardIdentitySurvivesRestart() throws {
        let storeDir = makeTempDir()
        let work = makeTempDir()
        defer { cleanup(storeDir); cleanup(work) }

        let cardID = UUID()
        let shell = BoardShell(seeds: [liveSeed(dir: work, cardID: cardID, state: .running)])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }

        let store = SessionSnapshotStore(directory: storeDir)
        let saved = try #require(shell.persistOnTerminate(store: store))
        #expect(try #require(saved.windows.flatMap(\.panes).first).cardID == cardID)

        let relaunched = BoardShell()
        defer { relaunched.e2eTeardown() }
        let restored = relaunched.restoreCardsForTesting(
            store: SessionSnapshotStore(directory: storeDir)
        )
        // A fresh UUID here is the bug: SICH_CARD_ID in the live hook lines would
        // point at a card that no longer exists.
        #expect(try #require(restored.first).id == cardID)
    }

    @Test("a restored shell carries SICH_CARD_ID, so live status still lands")
    func restoredShellCarriesIdentityBinding() throws {
        let storeDir = makeTempDir()
        let work = makeTempDir()
        defer { cleanup(storeDir); cleanup(work) }

        let cardID = UUID()
        let shell = BoardShell(seeds: [liveSeed(dir: work, cardID: cardID, state: .running)])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }
        _ = try #require(shell.persistOnTerminate(store: SessionSnapshotStore(directory: storeDir)))

        var spawned: [[String]] = []
        let relaunched = BoardShell()
        _ = relaunched.restoreOnLaunch(
            store: SessionSnapshotStore(directory: storeDir),
            restorer: spyingRestorer(spy: { spawned.append($1) })
        )

        let command = try #require(spawned.first).joined(separator: " ")
        // Shell-quoted, the same shape `BoardSeed.liveTerminal` uses when the card is
        // first created — restore and creation must bind identity identically.
        #expect(command.contains("SICH_CARD_ID='\(cardID.uuidString)'"))
        // A PTY does not chdir for us: without an explicit `cd` the restored shell opens
        // wherever the app was launched from, while its card advertises the project dir.
        #expect(command.contains("cd '\(work.path)'"))
        // The watcher line still holds: re-opening a shell, never resurrecting an agent.
        #expect(!command.contains("claude -p"))
        #expect(!command.contains("--print"))
    }

    // MARK: - Gap 3: liveness recorded at quit, not probed from a stale PID

    @Test("a pane alive at quit reopens, even though its PID is dead next launch")
    func aliveAtQuitReopensDespiteDeadPidOnRelaunch() throws {
        let storeDir = makeTempDir()
        let work = makeTempDir()
        defer { cleanup(storeDir); cleanup(work) }

        let shell = BoardShell(seeds: [liveSeed(dir: work, cardID: UUID(), state: .running)])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }

        let store = SessionSnapshotStore(directory: storeDir)
        let saved = try #require(shell.persistOnTerminate(store: store))
        // Liveness is a fact recorded AT QUIT — the shell was alive when we snapshotted it.
        #expect(try #require(saved.windows.flatMap(\.panes).first).wasAlive == true)

        // Next launch: the recorded PID is long gone (we killed it on the way out), which
        // is the normal case, NOT a signal that the card should be dropped.
        var spawned: [[String]] = []
        let relaunched = BoardShell()
        let restored = relaunched.restoreOnLaunch(
            store: SessionSnapshotStore(directory: storeDir),
            restorer: spyingRestorer(spy: { spawned.append($1) }, isAlive: { _ in false })
        )
        #expect(restored.first?.liveness == .reopened)
        #expect(spawned.count == 1)
    }

    /// The complement, so "reopen" can't just be hardcoded: a session that died on its
    /// OWN before the quit (`wasAlive == false`) still restores closed — US-003 edge
    /// case 3's intent, now recorded as a fact instead of inferred from a stale PID.
    @Test("a session that died before the quit still restores closed")
    func deadBeforeQuitStillRestoresClosed() throws {
        let storeDir = makeTempDir()
        defer { cleanup(storeDir) }

        let store = SessionSnapshotStore(directory: storeDir)
        let corpse = PaneSnapshot(
            sessionID: UUID(), cwd: "/tmp", agentType: .claude, flowTag: .interactive,
            childPID: 4242, wasAlive: false
        )
        _ = try store.save(windows: [WindowSnapshot(panes: [corpse])])

        var spawned: [[String]] = []
        let shell = BoardShell()
        let restored = shell.restoreOnLaunch(
            store: store,
            restorer: spyingRestorer(spy: { spawned.append($1) }, isAlive: { _ in true })
        )
        #expect(restored.first?.liveness == .dead)
        #expect(spawned.isEmpty)
    }
}
