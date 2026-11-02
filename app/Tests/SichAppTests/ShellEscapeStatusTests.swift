import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// "Statuses don't move for `! command`": Claude Code runs a bash-mode line (and the
/// model turn answering its output) with NO `UserPromptSubmit` and no tool hooks —
/// only the closing `Stop` (measured on 2.1.311). The card's own terminal sees the
/// Enter, so that keystroke stands in for the missing prompt submit.
@MainActor
@Suite("`!` bash-mode submit moves the card to WORKING")
struct ShellEscapeStatusTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func event(
        _ kind: SignalKind, card: UUID, agent: CardAgent = .claude, at offset: TimeInterval
    ) -> SignalEvent {
        SignalEvent(kind: kind, source: .hook, agent: agent, sessionID: "s1",
                    timestamp: base.addingTimeInterval(offset), cardID: card.uuidString)
    }

    // MARK: - Store rules

    @Test func submitAfterStopPutsTheSessionToWork() {
        let card = UUID()
        let store = HookSessionStore()
        store.ingest([event(.userInput, card: card, at: 0)])
        store.ingest([event(.stop, card: card, at: 10)])

        store.noteOperatorSubmit(cardID: card, at: base.addingTimeInterval(20))
        #expect(store.entry(for: "s1")?.state == .running)

        // The Stop closing the bash-mode turn routes NEEDS YOU again.
        store.ingest([event(.stop, card: card, at: 30)])
        #expect(store.entry(for: "s1")?.state == .waitingForInput)
    }

    @Test func submitReleasesTheTurnLatchForToolCalls() {
        let card = UUID()
        let store = HookSessionStore()
        store.ingest([event(.stop, card: card, at: 0)])
        store.noteOperatorSubmit(cardID: card, at: base.addingTimeInterval(10))
        store.ingest([event(.toolUse, card: card, at: 20)])
        #expect(store.entry(for: "s1")?.state == .running)
    }

    @Test func freshSessionBeforeItsFirstPromptGoesToWork() {
        let card = UUID()
        let store = HookSessionStore()
        store.ingest([event(.sessionStart, card: card, at: 0)])
        store.noteOperatorSubmit(cardID: card, at: base.addingTimeInterval(5))
        #expect(store.entry(for: "s1")?.state == .running)
    }

    @Test func exitedSessionIsAPlainShellAndStaysPut() {
        let card = UUID()
        let store = HookSessionStore()
        store.ingest([event(.stop, card: card, at: 0)])
        store.ingest([event(.sessionEnd, card: card, at: 10)])
        store.noteOperatorSubmit(cardID: card, at: base.addingTimeInterval(20))
        #expect(store.entry(for: "s1")?.state == .idle)
    }

    @Test func otherCardsAndOtherAgentsAreUntouched() {
        let card = UUID()
        let store = HookSessionStore()
        store.ingest([event(.stop, card: card, agent: .codex, at: 0)])
        store.noteOperatorSubmit(cardID: card, at: base.addingTimeInterval(10))
        store.noteOperatorSubmit(cardID: UUID(), at: base.addingTimeInterval(10))
        #expect(store.entry(for: "s1")?.state == .waitingForInput)
    }

    @Test func onlyAnExclamationWithACommandCounts() {
        #expect(TerminalSurface.isShellEscapeLine("!ls"))
        #expect(TerminalSurface.isShellEscapeLine("! git status"))
        #expect(!TerminalSurface.isShellEscapeLine("!"))
        #expect(!TerminalSurface.isShellEscapeLine("!  "))
        #expect(!TerminalSurface.isShellEscapeLine("fix the build!"))
    }

    // MARK: - Real dispatched keystrokes, end to end

    private func key(_ chars: String, code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: code
        ))
    }

    private func type(_ text: String, into responder: NSResponder) throws {
        for ch in text { responder.keyDown(with: try key(String(ch), code: 0)) }
        responder.keyDown(with: try key("\r", code: 36))
    }

    @Test func bangLineTypedInTheDrilledTerminalMovesTheCard() async throws {
        let events = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-bang-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: events) }
        let cardID = UUID()
        let stop = try JSONSerialization.data(withJSONObject: [
            "session_id": "claude-live", "cwd": "/repo", "hook_event_name": "Stop",
            "sich_card_id": cardID.uuidString,
        ])
        FileManager.default.createFile(atPath: events.path, contents: stop + Data("\n".utf8))

        let shell = BoardShell(seeds: [BoardSeed(
            sessionID: "task", projectDir: "/repo", agent: .claude, state: .idle,
            scrollback: "", cardID: cardID.uuidString
        )])
        let root = shell.buildContentForTesting()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = root
        root.layoutSubtreeIfNeeded()

        let poller = SessionsPoller(eventsFile: events, interval: 9999) { shell.applySessions($0) }
        shell.adoptSessionsPoller(poller)
        defer { poller.stop() }
        await poller.drainForTesting()
        #expect(shell.cards.first { $0.id == cardID }?.state == .waitingForInput)

        let card = try #require(shell.cards.first { $0.id == cardID })
        shell.drill(into: card)
        let responder = try #require(window.firstResponder as? TerminalSurface)

        // An empty Enter at the prompt is not work.
        responder.keyDown(with: try key("\r", code: 36))
        #expect(shell.cards.first { $0.id == cardID }?.state == .waitingForInput)

        try type("!ls", into: responder)
        #expect(shell.cards.first { $0.id == cardID }?.state == .running,
                "a submitted `!` line must move the card to WORKING")
    }
}
