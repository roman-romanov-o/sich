import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// A pane restored as a bare login shell (no agent command to resume) is drilled into
/// and the surface must paint what the shell already wrote — never a blank screen.
/// Spawns only `$SHELL -il`, no agent.
@MainActor
struct RestoredShellPaneDrillInTests {
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

    @Test func restoredShellPaneDrillInPaintsThePrompt() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-shell-pane-\(UUID().uuidString)", isDirectory: true)
        let storeDir = base.appendingPathComponent("store"), work = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let cardID = UUID()
        let store = SessionSnapshotStore(directory: storeDir)
        _ = try store.save(windows: [WindowSnapshot(panes: [PaneSnapshot(
            sessionID: UUID(), cwd: work.path, agentType: .shell, childPID: nil, title: "Test Cursor", cardID: cardID, cardState: .idle, wasAlive: true)])])

        let shell = BoardShell()
        let root = shell.buildContentForTesting()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = root
        window.orderFront(nil)
        defer { shell.e2eTeardown(); window.orderOut(nil) }

        let card = try #require(shell.restoreCardsForTesting(store: store).first { $0.id == cardID })
        let pty = try #require(shell.ptyForTesting(card: card))
        shell.startSessionPump()
        _ = pty.send(Array("echo RESTORED_SHELL_MARKER\n".utf8))
        spin(4)   // the board pump drains the prompt with no surface attached

        shell.drill(into: card)
        root.layoutSubtreeIfNeeded()
        spin(3)
        let surface = try #require(shell.drillIn.surfaceForTesting)
        let painted = surface.gridForTesting
        #expect(nonBlankRows(painted) > 0, "the drilled-in surface painted a blank screen")
        #expect(((try? pty.terminal.plainText()) ?? "").contains("RESTORED_SHELL_MARKER"))
    }
}
