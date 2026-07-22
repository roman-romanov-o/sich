import AppKit
import GhostlingCore
import Testing

@testable import GhostlingApp

/// Ctrl+Tab task switcher (VS Code style): first press opens a preview, further
/// presses while ⌃ is held step the highlight, releasing ⌃ commits, Esc cancels.
/// Per the Interaction-AC Binding Rule every interactive test dispatches REAL
/// `NSEvent`s through `handleTaskSwitchEvent` — the exact callback the local
/// monitor uses — never behavior handlers directly.
@MainActor
@Suite("Ctrl+Tab task switcher")
struct TaskSwitchTests {

    /// Firewall-clean demo seeds → owned `cat` stubs, one per requested state,
    /// so there's something to switch between. Board order = seed order.
    private func seeds(_ states: [CardState]) -> [BoardSeed] {
        states.enumerated().map { index, state in
            BoardSeed(sessionID: "demo/\(index)", projectDir: "~/p\(index)",
                      agent: .claude, flow: .a, state: state, scrollback: "s\(index)")
        }
    }

    /// A real keyDown event, the same shape the monitor receives.
    private func chord(_ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 48,
                       characters: String = "\t") throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    /// A real `.flagsChanged` event. `NSEvent.keyEvent` refuses this type, so it's
    /// built from a CGEvent — the same backing a monitor-delivered one carries.
    private func flagsChanged(_ flags: CGEventFlags) throws -> NSEvent {
        let backing = try #require(
            CGEvent(keyboardEventSource: nil, virtualKey: 0x3B, keyDown: false))
        backing.type = .flagsChanged
        backing.flags = flags
        return try #require(NSEvent(cgEvent: backing))
    }

    /// A pure `BoardCard` for the ordering tests (no PTY needed).
    private func card(_ name: String, _ state: CardState) -> BoardCard {
        BoardCard(sessionID: name, projectDir: "~/\(name)",
                  agent: .claude, flow: .b, state: state)
    }

    // MARK: - Decodes (real NSEvents through the monitor's own predicates)

    @Test("Ctrl+Tab decodes to a switch direction; ⌘Tab and plain Tab do not")
    func switchChordDecode() throws {
        #expect(BoardShell.switchDirection(for: try chord(.control)) == false)          // next
        #expect(BoardShell.switchDirection(for: try chord([.control, .shift])) == true)  // prev
        #expect(BoardShell.switchDirection(for: try chord(.command)) == nil)    // ⌘Tab = OS switcher
        #expect(BoardShell.switchDirection(for: try chord([])) == nil)          // plain Tab → child
        #expect(BoardShell.switchDirection(for: try chord(.control, keyCode: 36)) == nil) // Ctrl+Enter
    }

    @Test("⌃ release is a flagsChanged without Control — keyDowns never qualify")
    func controlReleaseDecode() throws {
        #expect(BoardShell.isControlRelease(try flagsChanged([])) == true)
        #expect(BoardShell.isControlRelease(try flagsChanged(.maskControl)) == false)
        #expect(BoardShell.isControlRelease(try chord(.control)) == false)
    }

    // MARK: - Ordering (pure)

    @Test("NEEDS YOU cards lead, each tier most-recently-focused first")
    func orderedTiersAndMRU() {
        let calm = card("a", .running), waiting = card("b", .waitingForInput)
        let blocked = card("c", .blocked), recent = card("d", .running)
        let ordered = TaskSwitcherOverlay.ordered(
            cards: [calm, waiting, blocked, recent], mru: [recent.id, blocked.id])
        #expect(ordered.map(\.sessionID) == ["c", "b", "d", "a"])
    }

    @Test("the highlight starts on the first entry that is not the current card")
    func initialHighlightSkipsCurrent() {
        let one = card("a", .running), two = card("b", .running)
        #expect(TaskSwitcherOverlay.initialHighlight(
            in: [one, two], current: nil, reverse: false) == 0)
        #expect(TaskSwitcherOverlay.initialHighlight(
            in: [one, two], current: one.id, reverse: false) == 1)
        #expect(TaskSwitcherOverlay.initialHighlight(
            in: [one, two], current: two.id, reverse: true) == 0)
        #expect(TaskSwitcherOverlay.initialHighlight(
            in: [one], current: one.id, reverse: false) == 0)
    }

    // MARK: - The hold-⌃ state machine, driven by real events

    @Test("Ctrl+Tab opens the preview without switching; releasing ⌃ commits")
    func holdPreviewThenReleaseCommits() throws {
        let shell = BoardShell(seeds: seeds([.waitingForInput, .running]))
        shell.buildContentForTesting()
        let first = try #require(shell.cards.first)
        let second = try #require(shell.cards.last)
        shell.drill(into: first)

        // First press: consumed, preview up, NOTHING switched yet.
        #expect(shell.handleTaskSwitchEvent(try chord(.control)) == nil)
        #expect(shell.switcherIsOpen == true)
        #expect(shell.taskSwitcher.isHidden == false)
        #expect(shell.drilledInCardID == first.id)

        // ⌃ release: commits the highlighted (next) task; modifier events pass through.
        #expect(shell.handleTaskSwitchEvent(try flagsChanged([])) != nil)
        #expect(shell.drilledInCardID == second.id)
        #expect(shell.switcherIsOpen == false)
        #expect(shell.taskSwitcher.isHidden == true)
        #expect(shell.boardView.isHidden == true, "the switch must NOT flash the board")
        #expect(shell.drillIn.isHidden == false)
    }

    @Test("held-⌃ presses step the highlight with wraparound; ⇧⇥ steps back")
    func steppingWrapsAndShiftReverses() throws {
        let shell = BoardShell(seeds: seeds([.running, .running, .running]))
        shell.buildContentForTesting()
        shell.drill(into: try #require(shell.cards.first))

        _ = shell.handleTaskSwitchEvent(try chord(.control))            // open → highlight 1
        #expect(shell.switcherIndex == 1)
        _ = shell.handleTaskSwitchEvent(try chord(.control))            // → 2
        #expect(shell.switcherIndex == 2)
        _ = shell.handleTaskSwitchEvent(try chord(.control))            // wraps → 0
        #expect(shell.switcherIndex == 0)
        _ = shell.handleTaskSwitchEvent(try chord([.control, .shift]))  // back → 2
        #expect(shell.switcherIndex == 2)
        _ = shell.handleTaskSwitchEvent(try flagsChanged([]))
        #expect(shell.drilledInCardID == shell.cards[2].id)
    }

    @Test("a quick tap jumps to the most recently focused task, not board order")
    func quickTapGoesToMostRecent() throws {
        let shell = BoardShell(seeds: seeds([.running, .running, .running]))
        shell.buildContentForTesting()
        shell.drill(into: shell.cards[2])
        shell.drill(into: shell.cards[0])   // MRU is now [0, 2]

        _ = shell.handleTaskSwitchEvent(try chord(.control))
        _ = shell.handleTaskSwitchEvent(try flagsChanged([]))
        #expect(shell.drilledInCardID == shell.cards[2].id,
                "MRU must beat board order (blind cycling would pick cards[1])")
    }

    @Test("from the board, a quick tap lands on the task that NEEDS YOU")
    func needsYouWinsFromBoard() throws {
        let shell = BoardShell(seeds: seeds([.running, .running, .waitingForInput]))
        shell.buildContentForTesting()
        #expect(shell.drilledInCardID == nil)

        _ = shell.handleTaskSwitchEvent(try chord(.control))
        _ = shell.handleTaskSwitchEvent(try flagsChanged([]))
        #expect(shell.drilledInCardID == shell.cards[2].id,
                "the waiting card outranks earlier board positions")
    }

    @Test("Esc closes the preview without switching; a closed switcher passes Esc on")
    func escCancels() throws {
        let shell = BoardShell(seeds: seeds([.running, .running]))
        shell.buildContentForTesting()
        let first = try #require(shell.cards.first)
        shell.drill(into: first)

        _ = shell.handleTaskSwitchEvent(try chord(.control))
        #expect(shell.switcherIsOpen == true)
        #expect(shell.handleTaskSwitchEvent(
            try chord([], keyCode: 53, characters: "\u{1B}")) == nil)   // consumed
        #expect(shell.switcherIsOpen == false)
        #expect(shell.taskSwitcher.isHidden == true)
        #expect(shell.drilledInCardID == first.id, "cancel must not switch")

        // With the switcher closed, Esc belongs to whoever else wants it.
        #expect(shell.handleTaskSwitchEvent(
            try chord([], keyCode: 53, characters: "\u{1B}")) != nil)
    }

    @Test("drilled into the only task, the chord is a quiet no-op")
    func loneFocusedCardNoOp() throws {
        let shell = BoardShell(seeds: seeds([.running]))
        shell.buildContentForTesting()
        let only = try #require(shell.cards.first)
        shell.drill(into: only)

        #expect(shell.handleTaskSwitchEvent(try chord(.control)) == nil)
        #expect(shell.switcherIsOpen == false, "nowhere to go → the preview never opens")
        #expect(shell.taskSwitcher.isHidden == true)
        #expect(shell.drilledInCardID == only.id)
    }
}
