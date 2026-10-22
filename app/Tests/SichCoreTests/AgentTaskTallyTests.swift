import Foundation
import Testing

@testable import SichCore

/// The per-harness load readout the quota panel renders: cards bucket under
/// their agent as working (running/runningTests) vs waiting (waiting/blocked);
/// at-rest cards are not "in progress" and must not inflate either count.
@Suite("Per-harness task tally")
struct AgentTaskTallyTests {

    private func card(_ agent: CardAgent, _ state: CardState) -> BoardCard {
        BoardCard(sessionID: UUID().uuidString, projectDir: "/tmp/p",
                  agent: agent, flow: .b, state: state)
    }

    @Test("cards split per agent into working vs waiting; at-rest states don't count")
    func splitsPerAgent() {
        let tallies = AgentTaskTally.tally([
            card(.claude, .running),
            card(.claude, .runningTests),
            card(.claude, .waitingForInput),
            card(.claude, .done),          // at rest — not in progress
            card(.claude, .idle),          // at rest
            card(.codex, .waitingForInput),
            card(.codex, .blocked),        // external block — not waiting on you
            card(.codex, .unknown),        // not positively determined — not counted
        ])
        #expect(tallies[.claude] == AgentTaskTally(working: 2, waiting: 1))
        #expect(tallies[.codex] == AgentTaskTally(working: 0, waiting: 1))
        #expect(tallies[.gemini] == nil, "a harness with no cards has no tally at all")
    }

    @Test("an all-at-rest board tallies to nothing")
    func atRestBoardIsEmpty() {
        let tallies = AgentTaskTally.tally([card(.claude, .done), card(.codex, .idle)])
        #expect(tallies.isEmpty)
        #expect(AgentTaskTally(working: 0, waiting: 0).isEmpty)
    }
}
