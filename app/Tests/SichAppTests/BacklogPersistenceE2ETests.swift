import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// E2E for the persistence inversion: the durable TASK (title + description +
/// placement) is the root entity, written through ``BoardTaskStore`` on EVERY
/// mutation — so a crash between mutations can no longer lose the work list the
/// way the old quit-only session snapshot could. Every case drives the REAL
/// seams: `addBacklogTask`/`createSession`/`promoteBacklogTask` on one shell,
/// then `hydrateForTesting` on a fresh shell against the same stores.
@MainActor
@Suite(.serialized)
struct BacklogPersistenceE2ETests {

    // MARK: - Fixtures

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-backlog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    /// Collects everything the shell types into a stubbed pty (the promote test's
    /// "did it actually start claude" evidence).
    @MainActor
    private final class TypedInput {
        var text = ""
    }

    /// A shell whose launches are firewall-clean `/bin/cat` stubs — no real agent,
    /// no login shell — with the typed pty input captured.
    private func makeShell(taskDir: URL, typed: TypedInput? = nil) -> BoardShell {
        let shell = BoardShell(seeds: [])
        shell.taskStore = BoardTaskStore(directory: taskDir)
        shell.launchOverrideForTesting = { seed in
            let pty = try! PTYSession(command: ["/bin/cat"])
            try! pty.start()
            if let typed {
                pty.onInput = { bytes in
                    MainActor.assumeIsolated {
                        typed.text += String(decoding: bytes, as: UTF8.self)
                    }
                }
            }
            return Session(
                projectDir: seed.projectDir, agentType: .claude,
                flowTag: .interactive, pty: pty, state: .running
            )
        }
        return shell
    }

    /// The relaunched app: a fresh shell over the same task store, hydrated through
    /// the real launch seam against the given (usually empty) session snapshot dir.
    private func relaunch(taskDir: URL, sessionDir: URL) -> BoardShell {
        let shell = BoardShell(seeds: [])
        shell.taskStore = BoardTaskStore(directory: taskDir)
        shell.hydrateForTesting(sessionStore: SessionSnapshotStore(directory: sessionDir))
        return shell
    }

    // MARK: - Backlog durability (the "important not to lose them" core)

    @Test("a backlog task with its description survives a crash — no quit ever happens")
    func backlogTaskSurvivesACrash() throws {
        let taskDir = makeTempDir()
        let sessionDir = makeTempDir()
        defer { cleanup(taskDir); cleanup(sessionDir) }

        let shell = makeShell(taskDir: taskDir)
        defer { shell.e2eTeardown() }
        shell.addBacklogTask(
            title: "Design the importer",
            details: "CSV first, then the API feed. Talk to Dana about column mapping.",
            projectDir: "/tmp/proj"
        )
        // The write happened NOW, not at quit — the crash-safety property itself.
        #expect(FileManager.default.fileExists(
            atPath: BoardTaskStore(directory: taskDir).currentURL.path))

        // Simulated crash: no persistOnTerminate. The next launch still has the task.
        let relaunched = relaunch(taskDir: taskDir, sessionDir: sessionDir)
        defer { relaunched.e2eTeardown() }
        let task = try #require(relaunched.backlogTasks.first)
        #expect(task.title == "Design the importer")
        #expect(task.details.contains("Talk to Dana"))
        #expect(task.projectDir == "/tmp/proj")
    }

    @Test("edited backlog details survive a relaunch")
    func editedDetailsSurviveRelaunch() throws {
        let taskDir = makeTempDir()
        let sessionDir = makeTempDir()
        defer { cleanup(taskDir); cleanup(sessionDir) }

        let shell = makeShell(taskDir: taskDir)
        defer { shell.e2eTeardown() }
        let record = shell.addBacklogTask(title: "Refine quota copy", details: "v1")
        shell.updateBacklogTask(id: record.id, details: "v2 — mention both pools")

        let relaunched = relaunch(taskDir: taskDir, sessionDir: sessionDir)
        defer { relaunched.e2eTeardown() }
        #expect(relaunched.backlogTasks.first?.details == "v2 — mention both pools")
    }

    @Test("deleting a backlog task and a board card are both durable")
    func deletionsAreDurable() throws {
        let taskDir = makeTempDir()
        let sessionDir = makeTempDir()
        let work = makeTempDir()
        defer { cleanup(taskDir); cleanup(sessionDir); cleanup(work) }

        let shell = makeShell(taskDir: taskDir)
        defer { shell.e2eTeardown() }
        let keep = shell.addBacklogTask(title: "Keep me")
        let drop = shell.addBacklogTask(title: "Drop me")
        let card = try #require(shell.createSession(title: "Doomed card", projectDir: work.path))

        shell.deleteBacklogTask(id: drop.id)
        shell.deleteCard(cardID: card.id)

        let relaunched = relaunch(taskDir: taskDir, sessionDir: sessionDir)
        defer { relaunched.e2eTeardown() }
        #expect(relaunched.backlogTasks.map(\.id) == [keep.id])
        #expect(!relaunched.cards.contains { $0.id == card.id })
    }

    // MARK: - Board tasks outlive their sessions

    @Test("a board card resurrects from the task book when the session snapshot is gone")
    func boardCardResurrectsWithoutItsSession() throws {
        let taskDir = makeTempDir()
        let sessionDir = makeTempDir()
        let work = makeTempDir()
        defer { cleanup(taskDir); cleanup(sessionDir); cleanup(work) }

        let shell = makeShell(taskDir: taskDir)
        defer { shell.e2eTeardown() }
        let card = try #require(shell.createSession(title: "Fix auth flow", projectDir: work.path))

        // Crash: the quit-time session snapshot never happens, so the OLD design
        // would restore an empty board. The task book alone brings the card back.
        let relaunched = relaunch(taskDir: taskDir, sessionDir: sessionDir)
        defer { relaunched.e2eTeardown() }
        let restored = try #require(relaunched.cards.first { $0.id == card.id })
        #expect(restored.title == "Fix auth flow")
        #expect(restored.state == .idle)
    }

    @Test("manual DONE survives via the task book alone")
    func manualDoneSurvivesViaTaskBookAlone() throws {
        let taskDir = makeTempDir()
        let sessionDir = makeTempDir()
        let work = makeTempDir()
        defer { cleanup(taskDir); cleanup(sessionDir); cleanup(work) }

        let shell = makeShell(taskDir: taskDir)
        defer { shell.e2eTeardown() }
        let card = try #require(shell.createSession(title: "Ship it", projectDir: work.path))
        shell.move(cardID: card.id, to: .done)

        let relaunched = relaunch(taskDir: taskDir, sessionDir: sessionDir)
        defer { relaunched.e2eTeardown() }
        #expect(relaunched.cards.first { $0.id == card.id }?.state == .done)
    }

    @Test("cumulative working time survives task-book hydration")
    func workingTimeSurvivesRelaunch() throws {
        let taskDir = makeTempDir()
        let sessionDir = makeTempDir()
        defer { cleanup(taskDir); cleanup(sessionDir) }
        let record = TaskRecord(
            title: "Timed task", placement: .board(.idle), agent: "codex",
            mode: .interactive, projectDir: "/tmp/proj",
            accumulatedWorkingTime: 2 * 3_600 + 7 * 60
        )
        _ = try BoardTaskStore(directory: taskDir).save(tasks: [record])

        let relaunched = relaunch(taskDir: taskDir, sessionDir: sessionDir)
        defer { relaunched.e2eTeardown() }
        let restored = try #require(relaunched.cards.first { $0.id == record.id })
        #expect(restored.accumulatedWorkingTime == 2 * 3_600 + 7 * 60)
        #expect(restored.totalWorkingTime() == restored.accumulatedWorkingTime)
    }

    // MARK: - Promotion (backlog → board with an agent choice)

    @Test("promoting a backlog task launches the agent, keeps its description, and persists")
    func promoteMovesTaskOntoBoardAndPersists() throws {
        let taskDir = makeTempDir()
        let sessionDir = makeTempDir()
        let work = makeTempDir()
        defer { cleanup(taskDir); cleanup(sessionDir); cleanup(work) }

        let typed = TypedInput()
        let shell = makeShell(taskDir: taskDir, typed: typed)
        defer { shell.e2eTeardown() }
        let record = shell.addBacklogTask(
            title: "Build the feature", details: "The long spec.", projectDir: work.path)

        let card = try #require(shell.promoteBacklogTask(
            id: record.id, agent: .claude, mode: .interactive))

        #expect(shell.backlogTasks.isEmpty, "a promoted task leaves the backlog")
        #expect(card.title == "Build the feature")
        // The claude start line was actually typed into the fresh shell's pty —
        // interactive pool, never `claude -p`.
        #expect(typed.text.contains("claude --session-id"))
        #expect(!typed.text.contains("claude -p"))

        let relaunched = relaunch(taskDir: taskDir, sessionDir: sessionDir)
        defer { relaunched.e2eTeardown() }
        #expect(relaunched.backlogTasks.isEmpty)
        let restored = try #require(relaunched.cards.first { $0.id == card.id })
        #expect(restored.title == "Build the feature")
    }

    @Test("a failed promote launch leaves the backlog untouched — the task is never lost")
    func failedPromoteLeavesBacklogIntact() throws {
        let taskDir = makeTempDir()
        defer { cleanup(taskDir) }

        let shell = makeShell(taskDir: taskDir)
        defer { shell.e2eTeardown() }
        shell.launchOverrideForTesting = { _ in nil }   // every spawn fails
        let record = shell.addBacklogTask(title: "Still here")

        #expect(shell.promoteBacklogTask(id: record.id) == nil)
        #expect(shell.backlogTasks.map(\.id) == [record.id])
    }

    // MARK: - Migration (first launch after the upgrade: no task book yet)

    @Test("a nil task book is synthesized from the restored session snapshot")
    func migrationSynthesizesBookFromSessionSnapshot() throws {
        let taskDir = makeTempDir()
        let sessionDir = makeTempDir()
        let work = makeTempDir()
        defer { cleanup(taskDir); cleanup(sessionDir); cleanup(work) }

        // The pre-upgrade app: session snapshot at quit, NO task store at all.
        let cardID = UUID()
        var seed = BoardSeed.liveTerminal(
            projectDir: work.path, sessionID: "migrate-\(cardID.uuidString.prefix(8))",
            title: "Fix login redirect", cardID: cardID.uuidString, agent: .claude)
        seed = BoardSeed(
            sessionID: seed.sessionID, title: seed.title, projectDir: seed.projectDir,
            agent: seed.agent, flow: seed.flow, state: .running, scrollback: seed.scrollback,
            commandOverride: seed.command, cardID: seed.cardID, taskFolder: seed.taskFolder)
        let old = BoardShell(seeds: [seed])
        _ = old.buildContentForTesting()
        defer { old.e2eTeardown() }
        _ = try #require(old.persistOnTerminate(store: SessionSnapshotStore(directory: sessionDir)))

        // First upgraded launch: empty task store + the old session snapshot.
        let upgraded = relaunch(taskDir: taskDir, sessionDir: sessionDir)
        defer { upgraded.e2eTeardown() }
        let book = try #require(BoardTaskStore(directory: taskDir).load())
        let migrated = try #require(book.tasks.first { $0.id == cardID })
        #expect(migrated.title == "Fix login redirect")
        #expect(migrated.placement == .board(.idle))
    }

    // MARK: - Interaction (real dispatched events, per the binding rule)

    @Test("a real double-click on a backlog card fires the promote path")
    func doubleClickOnBacklogCardFiresPromote() throws {
        let page = BacklogPage(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        var promoted: TaskRecord?
        page.onPromote = { promoted = $0 }
        let record = TaskRecord(title: "Start me", details: "spec", placement: .backlog)
        page.render([record])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = page
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        page.layoutSubtreeIfNeeded()

        let card = try #require(page.cardsForTesting().first)
        // Aim at the card's padding strip (below the labels) so the hit view is the
        // card's own chrome, then let the responder chain carry the event.
        let point = card.convert(NSPoint(x: card.bounds.midX, y: 4), to: nil)
        let hit = try #require(page.hitTest(point))
        #expect(hit.isDescendant(of: card), "the click point must land inside the backlog card")
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 2, pressure: 1))
        window.sendEvent(event)

        #expect(promoted?.id == record.id)
    }

    @Test("the + backlog task affordance is wired to the add callback")
    func backlogAddButtonFiresAddCallback() throws {
        let page = BacklogPage(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        var added = false
        page.onAdd = { added = true }
        page.render([])
        page.layoutSubtreeIfNeeded()

        // A stock NSButton's mouseDown enters its own tracking loop (it would hang a
        // headless test waiting for the mouseUp), so the action-firing seam is
        // performClick — the same target-action path a real click completes through.
        let button = try #require(page.addButtonForTesting())
        button.performClick(nil)

        #expect(added)
    }

    @Test("a real Esc keyDown on the backlog page fires the return path")
    func escKeyOnBacklogPageFiresReturn() throws {
        let page = BacklogPage(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        var returned = false
        page.onReturn = { returned = true }
        page.render([])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = page
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.makeFirstResponder(page)

        // A REAL key event through the window, per the interaction-AC binding rule
        // (calling keyDown(with:) directly would not prove the responder route).
        let esc = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        window.sendEvent(esc)

        #expect(returned)
    }

    // MARK: - Session-less card revival (the task outlives its shell — and comes back)

    @Test("drilling into a session-less board task revives its shell and resumes the pinned conversation")
    func sessionlessCardRevivesOnDrillIn() throws {
        let taskDir = makeTempDir()
        let sessionDir = makeTempDir()
        let work = makeTempDir()
        defer { cleanup(taskDir); cleanup(sessionDir); cleanup(work) }

        // A task book whose only record has no surviving pane — exactly what an
        // app-name migration (or a crash before the snapshot) leaves behind.
        let resumeID = UUID()
        let record = TaskRecord(
            title: "Migrated task", placement: .board(.idle), agent: "claude",
            mode: .interactive, projectDir: work.path,
            sessionRef: TaskSessionRef(claudeSessionID: resumeID, lastCwd: work.path))
        _ = try BoardTaskStore(directory: taskDir).save(tasks: [record])

        let typed = TypedInput()
        let shell = makeShell(taskDir: taskDir, typed: typed)
        defer { shell.e2eTeardown() }
        shell.hydrateForTesting(sessionStore: SessionSnapshotStore(directory: sessionDir))
        let card = try #require(shell.cards.first { $0.id == record.id },
                                "the session-less record comes back as a board card")

        shell.drill(into: card)

        #expect(!shell.drillIn.isHidden, "the click lands in the drill-in, not a silent no-op")
        #expect(typed.text.contains("claude --resume \(resumeID.uuidString.lowercased())"),
                "the pinned conversation resumes rather than restarting")
        #expect(!typed.text.contains("claude -p"))
    }

    @Test("a save cycle before revival keeps the session-less card's resume token")
    func saveCycleKeepsResumeHintForSessionlessCard() throws {
        let taskDir = makeTempDir()
        let sessionDir = makeTempDir()
        let work = makeTempDir()
        defer { cleanup(taskDir); cleanup(sessionDir); cleanup(work) }

        let resumeID = UUID()
        let record = TaskRecord(
            title: "Migrated task", placement: .board(.idle), agent: "claude",
            mode: .interactive, projectDir: work.path,
            sessionRef: TaskSessionRef(claudeSessionID: resumeID, lastCwd: work.path))
        _ = try BoardTaskStore(directory: taskDir).save(tasks: [record])

        // Hydration itself persists the adopted book — the exact write that used to
        // re-derive sessionRef from (absent) live sessions and wipe the id.
        let shell = makeShell(taskDir: taskDir)
        defer { shell.e2eTeardown() }
        shell.hydrateForTesting(sessionStore: SessionSnapshotStore(directory: sessionDir))

        let reloaded = try #require(BoardTaskStore(directory: taskDir).load())
        let saved = try #require(reloaded.tasks.first { $0.id == record.id })
        #expect(saved.sessionRef?.claudeSessionID == resumeID,
                "the resume token survives the adoption save cycle")
    }
}
