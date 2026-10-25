import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// The user's report, end to end: a card restored on launch (`claude --resume <id>`
/// typed into the re-opened login shell) is drilled into and the terminal is blank.
/// Drives the REAL launch restorer + `drill(into:)` in a real on-screen window and
/// reads the grid the drilled-in surface actually painted. Never `claude -p`.
///
/// Opt in with `SICH_REAL_AGENT_E2E=1` (needs the claude shim on PATH); ~1–2 min.
private let realAgentOptedIn = ProcessInfo.processInfo.environment["SICH_REAL_AGENT_E2E"] == "1"

@MainActor
struct RestoredCardDrillInRealAgentE2ETests {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func nonBlankRows(_ grid: TerminalGrid) -> Int {
        (0..<grid.rows).filter { row in
            (0..<grid.cols).contains { col in
                grid.cells[row * grid.cols + col].scalar.map { $0 != " " } ?? false
            }
        }.count
    }

    private func tempDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Hold a real conversation under a pinned id so `--resume` has history to replay.
    private func recordConversation(id: UUID, in cwd: URL) throws {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let pty = try PTYSession(command: [shell, "-il"], rows: 32, cols: 84)
        try pty.start(); pty.setNonBlocking()
        defer { pty.terminate() }
        _ = pty.send(Array("cd '\(cwd.path)'\n".utf8))
        _ = pty.send(Array(BoardShell.startClaudeCommand(sessionID: id, via: .localShim).utf8))
        var deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !((try? pty.terminal.plainText()) ?? "").contains("?") {
            _ = pty.pumpAvailable(); spin(0.1)
        }
        spin(2); _ = pty.pumpAvailable()
        _ = pty.send(Array("Reply with exactly the word HELLO_RESUME and nothing else.".utf8))
        spin(0.5); _ = pty.pumpAvailable()
        _ = pty.send([0x0D])   // Enter — the TUI submits on CR, not on a trailing newline
        deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            _ = pty.pumpAvailable(); spin(0.1)
            let text = (try? pty.terminal.plainText()) ?? ""
            if text.components(separatedBy: "HELLO_RESUME").count >= 3 { break }
        }
        spin(2); _ = pty.pumpAvailable()
        try? ((try? pty.terminal.plainText()) ?? "").write(toFile: "/tmp/restore-e2e-record.txt", atomically: true, encoding: .utf8)
        _ = pty.send(Array("/exit".utf8))
        spin(0.5); _ = pty.pumpAvailable()
        _ = pty.send([0x0D])
        for _ in 0..<30 { _ = pty.pumpAvailable(); spin(0.1) }
    }

    @Test(.enabled(if: realAgentOptedIn))
    func restoredClaudeCardDrillInShowsTheResumedConversation() throws {
        // The repo root: a directory the operator's claude already trusts, so the real
        // TUI opens straight into the conversation instead of a trust prompt.
        let work = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let storeDir = tempDir("resume-store")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        // Under a Claude Code harness the child inherits this mark and stops saving
        // transcripts, which leaves `--resume` nothing to replay.
        unsetenv("CLAUDE_CODE_CHILD_SESSION")
        let conversation = UUID()
        try recordConversation(id: conversation, in: work)

        let cardID = UUID()
        let store = SessionSnapshotStore(directory: storeDir)
        _ = try store.save(windows: [WindowSnapshot(panes: [PaneSnapshot(
            sessionID: UUID(), cwd: work.path, agentType: .claude, childPID: nil, claudeSessionID: conversation, title: "Resume me",
            cardID: cardID, cardState: .waitingForInput, wasAlive: true)])])

        let shell = BoardShell()
        let root = shell.buildContentForTesting()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = root
        window.orderFront(nil)
        defer { shell.e2eTeardown(); window.orderOut(nil) }

        let cards = shell.restoreCardsForTesting(store: store)
        let card = try #require(cards.first { $0.id == cardID })
        let pty = try #require(shell.ptyForTesting(card: card))
        shell.startSessionPump()
        spin(12)   // the board pump drains the resumed conversation with no surface attached
        let emulatorBefore = nonBlankRows(pty.terminal.snapshot())
        print("[restore-e2e] before drill: emulator nonblank=\(emulatorBefore) size=\(pty.terminal.size) history=\(pty.terminal.scrollbackRows)")

        shell.drill(into: card)
        root.layoutSubtreeIfNeeded()
        spin(6)
        let surface = try #require(shell.drillIn.surfaceForTesting)
        let painted = surface.gridForTesting
        let emulatorAfter = pty.terminal.snapshot()
        print("[restore-e2e] after drill: painted=\(nonBlankRows(painted))/\(painted.rows)x\(painted.cols) emulator=\(nonBlankRows(emulatorAfter))/\(emulatorAfter.rows) size=\(pty.terminal.size) history=\(pty.terminal.scrollbackRows) viewingScrollback=\(surface.isViewingScrollback) frame=\(surface.frame) window=\(surface.window != nil)")
        print((try? pty.terminal.plainText())?.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(12).joined(separator: "\n") ?? "")

        #expect(emulatorBefore > 0, "the resumed conversation never reached the emulator")
        #expect(nonBlankRows(painted) > 0, "the drilled-in surface painted a blank screen")
        #expect(((try? pty.terminal.plainText()) ?? "").contains("HELLO_RESUME"),
                "the resumed transcript is not on screen")
    }
}
