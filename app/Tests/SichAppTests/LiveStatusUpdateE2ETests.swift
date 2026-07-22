import Foundation
import SichCore
import Testing

@testable import SichApp

/// End-to-end repro for "when claude is working, the task card stays in the same
/// column": real hook JSON lines → HookEventTail → SessionsFeed.normalize →
/// HookSessionStore → SessionsPoller sink → BoardShell.applySessions → the card's
/// state. This is the whole live wiring minus only the kernel FS watch (polls are
/// driven explicitly).
@MainActor
struct LiveStatusUpdateE2ETests {

    private func tempEventsFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-e2e-\(UUID().uuidString).jsonl")
    }

    private func hookLine(_ event: String, session: String, dir: String, cardID: String?) -> String {
        var payload: [String: Any] = [
            "session_id": session, "cwd": dir, "hook_event_name": event,
        ]
        if let cardID { payload["sich_card_id"] = cardID }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)! + "\n"
    }

    @Test func boundClaudeSessionMovesTheOwnedCardToRunning() async throws {
        let events = tempEventsFile()
        defer { try? FileManager.default.removeItem(at: events) }
        FileManager.default.createFile(atPath: events.path, contents: nil)

        // Two owned cards SHARING one repo dir (the real board shape) — the dir
        // join is suppressed, so only the SICH_CARD_ID binding can move them.
        let cardA = UUID(), cardB = UUID()
        func seed(_ n: String, _ id: UUID) -> BoardSeed {
            BoardSeed(sessionID: n, projectDir: "/repo", agent: .claude, flow: .b,
                      state: .idle, scrollback: "", cardID: id.uuidString)
        }
        let shell = BoardShell(seeds: [seed("task-a", cardA), seed("task-b", cardB)])
        shell.buildContentForTesting()

        var latest: [BoardCard] = []
        let poller = SessionsPoller(eventsFile: events, interval: 9999) { cards in
            latest = cards
            shell.applySessions(cards)
        }
        poller.start()
        defer { poller.stop() }
        await poller.drainForTesting()   // the cold-start drain parses off-main

        func append(_ event: String) async {
            let line = hookLine(event, session: "claude-live", dir: "/repo",
                                cardID: cardA.uuidString)
            let handle = try! FileHandle(forWritingTo: events)
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try! handle.close()
            poller.fireWatchForTesting()
            await poller.drainForTesting()   // deterministic: apply lands before asserts
        }

        await append("SessionStart")
        await append("UserPromptSubmit")   // idle → running: claude is working
        await append("PreToolUse")

        #expect(latest.first?.state == .running, "store must detect running")
        let a = shell.cards.first { $0.id == cardA }
        let b = shell.cards.first { $0.id == cardB }
        #expect(a?.state == .running, "bound owned card must adopt running")
        #expect(b?.state == .idle, "the sibling card in the same dir must not move")
    }
}
