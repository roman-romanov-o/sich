import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// Checklist 18.08, item 3: the "Terminal − +" pill is gone; ⌘+/⌘− is the ONE
/// zoom gesture everywhere, and it routes by context — board scale on the board,
/// terminal points while a terminal fills the window (drill-in or planning mode).
@MainActor
@Suite(.serialized)
struct FontZoomRoutingTests {

    private func makeTempDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-zoom-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeShell(bookDir: URL) -> BoardShell {
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        shell.taskStore = BoardTaskStore(directory: bookDir)
        shell.launchOverrideForTesting = { seed in
            let pty = try! PTYSession(command: ["/bin/cat"])
            try! pty.start()
            return Session(projectDir: seed.projectDir, agentType: .claude,
                           flowTag: .interactive, pty: pty, state: .running)
        }
        return shell
    }

    @Test("on the board, ⌘+ zooms the BOARD and leaves the terminal font alone")
    func boardContextZoomsTheBoard() throws {
        let bookDir = makeTempDir("board")
        defer { try? FileManager.default.removeItem(at: bookDir) }
        let shell = makeShell(bookDir: bookDir)
        defer { shell.e2eTeardown() }
        let savedScale = BoardTheme.boardFontScale
        defer { BoardTheme.boardFontScale = savedScale }
        BoardTheme.boardFontScale = 1.2
        let terminalBefore = shell.terminalFontSize

        shell.zoomFont(direction: 1)

        #expect(abs(BoardTheme.boardFontScale - 1.3) < 0.001, "board scale steps up")
        #expect(shell.terminalFontSize == terminalBefore, "terminal font untouched")
    }

    @Test("drilled into a terminal, ⌘+/⌘− zoom the TERMINAL and leave the board alone")
    func drillInContextZoomsTheTerminal() throws {
        let bookDir = makeTempDir("drill")
        let projectDir = makeTempDir("proj")
        defer {
            try? FileManager.default.removeItem(at: bookDir)
            try? FileManager.default.removeItem(at: projectDir)
        }
        let shell = makeShell(bookDir: bookDir)
        defer { shell.e2eTeardown() }
        let savedScale = BoardTheme.boardFontScale
        defer { BoardTheme.boardFontScale = savedScale }
        BoardTheme.boardFontScale = 1.2

        let card = try #require(
            shell.createSession(title: "zoom me", projectDir: projectDir.path))
        shell.drill(into: card)
        #expect(shell.drilledInCardID == card.id, "precondition: the terminal owns the window")
        let terminalBefore = shell.terminalFontSize

        shell.zoomFont(direction: 1)
        #expect(shell.terminalFontSize == terminalBefore + 1, "terminal font steps up")
        #expect(abs(BoardTheme.boardFontScale - 1.2) < 0.001, "board scale untouched")

        shell.zoomFont(direction: -1)
        #expect(shell.terminalFontSize == terminalBefore, "⌘− steps back down")
    }
}
