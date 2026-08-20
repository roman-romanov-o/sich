import Foundation
import SichCore
import Testing

@testable import SichApp

/// Checklist 18.08, items 1+2: a task moved to DONE must close its terminal (a
/// finished task must not keep eating a shell, an fd, and a pump slot), and a task
/// moved DONE → back-in-play must come back as the SAME Claude conversation —
/// `claude --resume <id>`, never a fresh anonymous shell.
@MainActor
@Suite(.serialized)
struct DoneTerminalLifecycleTests {

    private func makeTempDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-done-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A board whose spawns are stubbed to a `/bin/cat` pty that records everything
    /// typed into it — the same seam every revival suite uses; no real shell, no ssh.
    private func makeShell(bookDir: URL, typed: Revival) -> BoardShell {
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        shell.taskStore = BoardTaskStore(directory: bookDir)
        shell.launchOverrideForTesting = { seed in
            let pty = try! PTYSession(command: ["/bin/cat"])
            try! pty.start()
            pty.onInput = { bytes in
                MainActor.assumeIsolated { typed.text += String(decoding: bytes, as: UTF8.self) }
            }
            let session = Session(projectDir: seed.projectDir, agentType: .claude,
                                  flowTag: .interactive, pty: pty, state: .running)
            MainActor.assumeIsolated {
                typed.argv = seed.command
                typed.session = session
            }
            return session
        }
        return shell
    }

    @Test("moving a card to DONE closes its terminal and frees the session slot")
    func doneClosesTheTerminal() throws {
        let bookDir = makeTempDir("close")
        let projectDir = makeTempDir("proj")
        defer {
            try? FileManager.default.removeItem(at: bookDir)
            try? FileManager.default.removeItem(at: projectDir)
        }
        let typed = Revival()
        let shell = makeShell(bookDir: bookDir, typed: typed)
        defer { shell.e2eTeardown() }

        let card = try #require(
            shell.createSession(title: "ship it", projectDir: projectDir.path))
        let pty = try #require(shell.ptyForTesting(card.id))
        #expect(pty.masterFD >= 0, "precondition: the card owns a live pty")

        shell.move(cardID: card.id, to: .done)

        #expect(shell.ptyForTesting(card.id) == nil, "the card no longer owns a pty")
        #expect(pty.masterFD < 0, "the pty fd is closed, the child reaped")
        #expect(!shell.isRegistered(pty), "the session left the registry — the pump and the quit snapshot forget it")
        let moved = try #require(shell.cards.first { $0.id == card.id })
        #expect(moved.state == .done, "the card itself stays on the board, in DONE")
    }

    @Test("closing on DONE keeps the resume token in the durable task book")
    func doneKeepsTheResumeToken() throws {
        let bookDir = makeTempDir("token")
        let projectDir = makeTempDir("proj")
        defer {
            try? FileManager.default.removeItem(at: bookDir)
            try? FileManager.default.removeItem(at: projectDir)
        }
        let typed = Revival()
        let shell = makeShell(bookDir: bookDir, typed: typed)
        defer { shell.e2eTeardown() }

        let card = try #require(
            shell.createSession(title: "ship it", projectDir: projectDir.path))
        let conversation = UUID()
        typed.session?.recordClaudeSession(conversation)

        shell.move(cardID: card.id, to: .done)

        let record = try #require(
            BoardTaskStore(directory: bookDir).load()?.tasks.first { $0.id == card.id })
        #expect(record.sessionRef?.claudeSessionID == conversation,
                "the conversation id is frozen into the book before the session dies")
    }

    @Test("DONE → back in play revives the terminal on the SAME conversation")
    func leavingDoneResumesTheSameConversation() throws {
        let bookDir = makeTempDir("resume")
        let projectDir = makeTempDir("proj")
        defer {
            try? FileManager.default.removeItem(at: bookDir)
            try? FileManager.default.removeItem(at: projectDir)
        }
        let typed = Revival()
        let shell = makeShell(bookDir: bookDir, typed: typed)
        defer { shell.e2eTeardown() }

        let card = try #require(
            shell.createSession(title: "ship it", projectDir: projectDir.path))
        let conversation = UUID()
        typed.session?.recordClaudeSession(conversation)
        shell.move(cardID: card.id, to: .done)
        typed.text = ""

        shell.move(cardID: card.id, to: .running)

        let pty = try #require(shell.ptyForTesting(card.id), "the terminal is back")
        #expect(pty.masterFD >= 0)
        #expect(typed.text.contains("claude --resume \(conversation.uuidString.lowercased())"),
                "the SAME conversation resumes — typed: \(typed.text)")
        #expect(!typed.text.contains("claude -p"), "interactive pool only, firewall intact")
    }

    @Test("a card that was never in DONE keeps its pty across an ordinary move")
    func ordinaryMoveKeepsThePty() throws {
        let bookDir = makeTempDir("keep")
        let projectDir = makeTempDir("proj")
        defer {
            try? FileManager.default.removeItem(at: bookDir)
            try? FileManager.default.removeItem(at: projectDir)
        }
        let typed = Revival()
        let shell = makeShell(bookDir: bookDir, typed: typed)
        defer { shell.e2eTeardown() }

        let card = try #require(
            shell.createSession(title: "ship it", projectDir: projectDir.path))
        let pty = try #require(shell.ptyForTesting(card.id))

        shell.move(cardID: card.id, to: .blocked)

        #expect(shell.ptyForTesting(card.id) === pty, "only DONE closes the terminal")
        #expect(pty.masterFD >= 0)
    }
}
