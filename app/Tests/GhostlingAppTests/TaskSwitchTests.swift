import AppKit
import GhostlingCore
import Testing

@testable import GhostlingApp

/// Ctrl+Tab task switcher: jump between focused task terminals without bouncing off
/// the board. Two halves, per the Interaction-AC Binding Rule: `switchDirection`
/// decodes a REAL Ctrl+Tab `NSEvent` (the input the monitor actually receives), and
/// `cycleDrill` drives the real `BoardShell` drill state end to end.
@MainActor
@Suite("Ctrl+Tab task switcher")
struct TaskSwitchTests {

    /// Two firewall-clean demo seeds → two owned `cat` stubs, so there's something to
    /// switch between (a single card is a no-op).
    private func twoSeeds() -> [BoardSeed] {
        [
            BoardSeed(sessionID: "demo/one", projectDir: "~/one",
                      agent: .claude, flow: .a, state: .waitingForInput, scrollback: "one"),
            BoardSeed(sessionID: "demo/two", projectDir: "~/two",
                      agent: .claude, flow: .a, state: .running, scrollback: "two"),
        ]
    }

    /// The keyCode-48 + Control decode the monitor closes over. Built from real
    /// `NSEvent`s so a wrong keyCode or modifier check fails RED here, not silently.
    @Test("Ctrl+Tab decodes to a switch direction; ⌘Tab and plain Tab do not")
    func switchChordDecode() throws {
        func key(_ flags: NSEvent.ModifierFlags, _ keyCode: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\t",
                charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: keyCode))
        }
        #expect(BoardShell.switchDirection(for: try key(.control, 48)) == false)         // next
        #expect(BoardShell.switchDirection(for: try key([.control, .shift], 48)) == true) // prev
        #expect(BoardShell.switchDirection(for: try key(.command, 48)) == nil)   // ⌘Tab = OS switcher
        #expect(BoardShell.switchDirection(for: try key([], 48)) == nil)         // plain Tab → child
        #expect(BoardShell.switchDirection(for: try key(.control, 36)) == nil)   // Ctrl+Enter → child
    }

    @Test("Ctrl+Tab cycles to the next task without returning to the board, wrapping around")
    func cycleForwardWraps() throws {
        let shell = BoardShell(seeds: twoSeeds())
        shell.buildContentForTesting()
        let first = try #require(shell.cards.first)
        let second = try #require(shell.cards.last)
        #expect(first.id != second.id)

        shell.drill(into: first)
        #expect(shell.drilledInCardID == first.id)

        shell.cycleDrill(reverse: false)
        #expect(shell.drilledInCardID == second.id)
        #expect(shell.boardView.isHidden == true, "the switch must NOT flash the board")
        #expect(shell.drillIn.isHidden == false)

        shell.cycleDrill(reverse: false)   // wraps back to the first
        #expect(shell.drilledInCardID == first.id)
    }

    @Test("Ctrl+Shift+Tab cycles to the previous task")
    func cycleReverse() throws {
        let shell = BoardShell(seeds: twoSeeds())
        shell.buildContentForTesting()
        let first = try #require(shell.cards.first)
        let second = try #require(shell.cards.last)

        shell.drill(into: first)
        shell.cycleDrill(reverse: true)    // wraps backward to the last
        #expect(shell.drilledInCardID == second.id)
    }

    @Test("from the board, Ctrl+Tab drills into a task; a lone card cycles to a no-op")
    func fromBoardAndSingleCard() throws {
        let shell = BoardShell(seeds: twoSeeds())
        shell.buildContentForTesting()
        let first = try #require(shell.cards.first)

        // On the board, nothing focused → the chord jumps into the first task.
        #expect(shell.drilledInCardID == nil)
        shell.cycleDrill(reverse: false)
        #expect(shell.drilledInCardID == first.id)
        #expect(shell.boardView.isHidden == true)

        // Ordering helper: a lone card cycling to itself is a no-op (guarded).
        #expect(BoardShell.nextCard(in: shell.cards, after: nil, reverse: false)?.id == first.id)
    }
}
