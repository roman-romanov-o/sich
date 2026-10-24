import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// Checklist: "DONE column need to be archived time to time (so you can view it
/// in some dedicated view, and keep data lean)". The policy under test:
///
///  * a task finished in a PREVIOUS app session sweeps into the archive on the
///    next launch — the record stays durable (`archivedAt` stamped), the board
///    stops renting it a card;
///  * work finished in THIS session stays visible in DONE until the next launch;
///  * the archive is reachable from the board (the icon beside DONE), because
///    green-but-unreachable is this repo's classic false pass.
///
/// Launches are `/bin/cat` stubs through `launchOverrideForTesting` — no real
/// agent, firewall-clean.
@MainActor
@Suite(.serialized)
struct ArchiveTests {

    // MARK: - Fixtures

    private func makeTempDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-archive-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func stubLaunches(on shell: BoardShell) {
        shell.launchOverrideForTesting = { seed in
            let pty = try! PTYSession(command: ["/bin/cat"])
            try! pty.start()
            return Session(projectDir: seed.projectDir, agentType: .claude,
                           pty: pty, state: .running)
        }
    }

    private func makeShell(taskDir: URL) -> BoardShell {
        let shell = BoardShell(seeds: [])
        shell.taskStore = BoardTaskStore(directory: taskDir)
        stubLaunches(on: shell)
        return shell
    }

    private func relaunch(taskDir: URL, sessionDir: URL) -> BoardShell {
        let shell = makeShell(taskDir: taskDir)
        shell.hydrateForTesting(sessionStore: SessionSnapshotStore(directory: sessionDir))
        return shell
    }

    // MARK: - The archive-on-launch sweep

    @Test("a task done last session archives on relaunch — durable, off the board, idempotent")
    func doneTaskArchivesOnRelaunch() throws {
        let taskDir = makeTempDir("book")
        let sessionDir = makeTempDir("snap")
        let work = makeTempDir("work")
        defer {
            try? FileManager.default.removeItem(at: taskDir)
            try? FileManager.default.removeItem(at: sessionDir)
            try? FileManager.default.removeItem(at: work)
        }

        // Session 1: finish a task.
        let shell = makeShell(taskDir: taskDir)
        _ = shell.buildContentForTesting()
        let card = try #require(shell.createSession(title: "Ship the importer",
                                                    projectDir: work.path))
        shell.move(cardID: card.id, to: .done)
        shell.e2eTeardown()

        // Session 2: the DONE column is lean again — the task lives in the archive.
        let relaunched = relaunch(taskDir: taskDir, sessionDir: sessionDir)
        defer { relaunched.e2eTeardown() }
        #expect(!relaunched.cards.contains { $0.id == card.id })
        let archived = try #require(relaunched.archivedTasks.first { $0.id == card.id })
        #expect(archived.archivedAt != nil)

        // The stamped record is on disk, so the archive survives the NEXT crash too.
        let onDisk = try #require(
            BoardTaskStore(directory: taskDir).load()?.tasks.first { $0.id == card.id })
        #expect(onDisk.archivedAt != nil)

        // Session 3: idempotent — exactly one archived copy, never a duplicate.
        let third = relaunch(taskDir: taskDir, sessionDir: sessionDir)
        defer { third.e2eTeardown() }
        #expect(third.archivedTasks.filter { $0.id == card.id }.count == 1)
        #expect(!third.cards.contains { $0.id == card.id })
    }

    @Test("unfinished tasks survive relaunch unarchived")
    func unfinishedTasksAreNeverArchived() throws {
        let taskDir = makeTempDir("keep")
        let sessionDir = makeTempDir("keep-snap")
        let work = makeTempDir("keep-work")
        defer {
            try? FileManager.default.removeItem(at: taskDir)
            try? FileManager.default.removeItem(at: sessionDir)
            try? FileManager.default.removeItem(at: work)
        }

        let shell = makeShell(taskDir: taskDir)
        _ = shell.buildContentForTesting()
        let card = try #require(shell.createSession(title: "Still working",
                                                    projectDir: work.path))
        shell.e2eTeardown()

        let relaunched = relaunch(taskDir: taskDir, sessionDir: sessionDir)
        defer { relaunched.e2eTeardown() }
        let kept = try #require(relaunched.cards.first { $0.id == card.id })
        #expect(kept.state != .done)
        #expect(relaunched.archivedTasks.isEmpty)
    }

    // MARK: - Reachability: the dedicated view really opens from the board

    @Test("the DONE header's archive icon opens the dedicated view, Esc returns")
    func archiveIsReachableFromTheDoneColumn() throws {
        let taskDir = makeTempDir("reach")
        let sessionDir = makeTempDir("reach-snap")
        let work = makeTempDir("reach-work")
        defer {
            try? FileManager.default.removeItem(at: taskDir)
            try? FileManager.default.removeItem(at: sessionDir)
            try? FileManager.default.removeItem(at: work)
        }

        // Seed one archived task through the real sweep.
        let first = makeShell(taskDir: taskDir)
        _ = first.buildContentForTesting()
        let card = try #require(first.createSession(title: "Archived work",
                                                    projectDir: work.path))
        first.move(cardID: card.id, to: .done)
        first.e2eTeardown()

        let shell = makeShell(taskDir: taskDir)
        let root = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }
        shell.hydrateForTesting(sessionStore: SessionSnapshotStore(directory: sessionDir))
        root.layoutSubtreeIfNeeded()

        // The affordance exists on the board the shell built…
        let button = try #require(firstButton(in: root, identifier: "show-archive"),
                                  "the DONE header must carry the archive icon")
        // …and clicking it (performClick — the deterministic headless seam for a
        // stock NSButton, see BoardInteractionTests) swaps in the archive page.
        button.performClick(nil)
        #expect(!shell.archivePage.isHidden)
        #expect(shell.boardView.isHidden)
        let row = try #require(shell.archivePage.rowsForTesting().first)
        #expect(row.record.title == "Archived work")

        // Esc leaves — a real dispatched key event, per the interaction-AC rule.
        let esc = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        shell.archivePage.keyDown(with: esc)
        #expect(shell.archivePage.isHidden)
        #expect(!shell.boardView.isHidden)
    }

    // MARK: - Revive: the session comes back, local or remote

    @Test("reviving an archived local task reopens its conversation and stays on the board")
    func reviveLocalArchivedTaskReopensTheConversation() throws {
        let taskDir = makeTempDir("revive-local")
        let sessionDir = makeTempDir("revive-local-snap")
        let work = makeTempDir("revive-local-work")
        defer {
            try? FileManager.default.removeItem(at: taskDir)
            try? FileManager.default.removeItem(at: sessionDir)
            try? FileManager.default.removeItem(at: work)
        }
        let resumeID = UUID()
        let record = TaskRecord(
            title: "Look at the importer",
            placement: .board(.done),
            agent: CardAgent.claude.rawValue,
            projectDir: work.path,
            sessionRef: TaskSessionRef(claudeSessionID: resumeID, lastCwd: work.path),
            archivedAt: Date()
        )
        try BoardTaskStore(directory: taskDir).save(tasks: [record])

        let typed = TypedLaunch()
        let shell = makeShell(taskDir: taskDir)
        let root = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }
        shell.launchOverrideForTesting = capturingLaunch(typed)
        shell.hydrateForTesting(sessionStore: SessionSnapshotStore(directory: sessionDir))
        let window = host(root)
        shell.showArchivePage()
        root.layoutSubtreeIfNeeded()

        try clickRevive(on: shell, in: root, window: window)

        let card = try #require(shell.cards.first { $0.id == record.id })
        #expect(card.state == .idle)
        #expect(shell.archivedTasks.isEmpty)
        #expect(shell.archivePage.isHidden)
        #expect(!shell.drillIn.isHidden)
        #expect(shell.ptyForTesting(card.id) != nil)
        #expect(typed.text.contains(resumeID.uuidString.lowercased()))
        let onDisk = try #require(
            BoardTaskStore(directory: taskDir).load()?.tasks.first { $0.id == record.id })
        #expect(onDisk.archivedAt == nil)
        #expect(onDisk.placement == .board(.idle))

        // Quit and come back: the task is in play, not swept into the archive again.
        shell.e2eTeardown()
        let again = relaunch(taskDir: taskDir, sessionDir: sessionDir)
        defer { again.e2eTeardown() }
        #expect(again.cards.contains { $0.id == record.id })
        #expect(!again.archivedTasks.contains { $0.id == record.id })
        #expect(again.taskMetaForTesting(record.id)?.sessionRef?.claudeSessionID == resumeID)
    }

    @Test("reviving an archived remote task re-attaches over ssh without typing into it")
    func reviveRemoteArchivedTaskReattaches() throws {
        let taskDir = makeTempDir("revive-remote")
        let sessionDir = makeTempDir("revive-remote-snap")
        defer {
            try? FileManager.default.removeItem(at: taskDir)
            try? FileManager.default.removeItem(at: sessionDir)
        }
        let spec = RemoteTmuxSpec(host: "host.invalid", user: "roman", sessionName: "agent")
        let record = TaskRecord(
            title: "Far-side look",
            placement: .board(.done),
            agent: CardAgent.claude.rawValue,
            projectDir: spec.target,
            sessionRef: TaskSessionRef(claudeSessionID: UUID(), lastCwd: "/home/roman/work"),
            remote: RemoteSpecSnapshot(spec: spec),
            archivedAt: Date()
        )
        try BoardTaskStore(directory: taskDir).save(tasks: [record])

        let typed = TypedLaunch()
        let shell = makeShell(taskDir: taskDir)
        let root = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }
        shell.launchOverrideForTesting = capturingLaunch(typed)
        shell.hydrateForTesting(sessionStore: SessionSnapshotStore(directory: sessionDir))
        let window = host(root)
        shell.showArchivePage()
        root.layoutSubtreeIfNeeded()

        try clickRevive(on: shell, in: root, window: window)

        let card = try #require(shell.cards.first { $0.id == record.id })
        #expect(card.state == .idle)
        #expect(card.sessionID == "remote/host.invalid/agent")
        #expect(card.projectDir == "roman@host.invalid")
        #expect(shell.archivedTasks.isEmpty)
        #expect(!shell.drillIn.isHidden)
        #expect(shell.ptyForTesting(card.id) != nil)
        // Attach where the far side was last seen working, not only where the card
        // was created — the same refresh a live remote drill-in already applies.
        var expected = spec
        expected.remoteDir = "/home/roman/work"
        #expect(typed.argv == (try RemoteTmuxCommand.argv(for: expected, cardID: record.id.uuidString)))
        // The far side still has the session (the probe cannot say otherwise under
        // `swift test`), so revival attaches and does not type a resume over it.
        #expect(typed.text.isEmpty)
        #expect(typed.session?.remoteSpec == expected)
    }

    private func capturingLaunch(_ typed: TypedLaunch) -> (BoardSeed) -> Session? {
        { seed in
            let pty = try! PTYSession(command: ["/bin/cat"])
            try! pty.start()
            pty.onInput = { bytes in
                typed.text += String(decoding: bytes, as: UTF8.self)
            }
            typed.argv = seed.command
            let session = Session(
                projectDir: seed.projectDir, agentType: .claude,
                pty: pty, state: .running)
            typed.session = session
            return session
        }
    }

    private func host(_ root: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        return window
    }

    /// A real left-mouse-down on the Revive pill, dispatched to the view hit-testing
    /// resolves — the interaction path, not a direct `reviveArchivedTask` call.
    private func clickRevive(on shell: BoardShell, in root: NSView, window: NSWindow) throws {
        let pill = try #require(shell.archivePage.rowsForTesting().first).revivePillForTesting()
        #expect(pill.bounds.width > 0, "the Revive pill must lay out before it can be clicked")
        let center = pill.convert(NSPoint(x: pill.bounds.midX, y: pill.bounds.midY), to: nil)
        let hit = try #require(root.hitTest(center))
        #expect(hit === pill)
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        hit.mouseDown(with: click)
    }

    private func firstButton(in view: NSView, identifier: String) -> NSButton? {
        if let button = view as? NSButton, button.identifier?.rawValue == identifier {
            return button
        }
        for sub in view.subviews {
            if let found = firstButton(in: sub, identifier: identifier) { return found }
        }
        return nil
    }
}

/// Argv and keystrokes a revived archive task's launch actually produced.
private final class TypedLaunch: @unchecked Sendable {
    var text = ""
    var argv: [String] = []
    var session: Session?
}
