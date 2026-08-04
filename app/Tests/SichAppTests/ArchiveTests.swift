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
                           flowTag: .interactive, pty: pty, state: .running)
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
