import Foundation

/// Per-harness count of in-progress board cards: `working` (the agent is doing
/// something right now) vs `waiting` (the session is waiting on the operator).
/// Pure board logic — the quota panel renders it next to each provider's gauges
/// so "how loaded is this pool" sits beside "how much of it is left".
public struct AgentTaskTally: Sendable, Equatable {
    public var working: Int
    public var waiting: Int

    public init(working: Int = 0, waiting: Int = 0) {
        self.working = working
        self.waiting = waiting
    }

    public var isEmpty: Bool { working == 0 && waiting == 0 }

    /// Bucket each card under its agent: `running`/`runningTests` count as
    /// working, `waitingForInput`/`blocked` as waiting on you. At-rest states
    /// (idle, done, unknown) are not in progress and are not counted.
    public static func tally(_ cards: [BoardCard]) -> [CardAgent: AgentTaskTally] {
        var result: [CardAgent: AgentTaskTally] = [:]
        for card in cards {
            switch card.state {
            case .running, .runningTests:
                result[card.agent, default: AgentTaskTally()].working += 1
            case .waitingForInput, .blocked:
                result[card.agent, default: AgentTaskTally()].waiting += 1
            case .idle, .done, .unknown:
                break
            }
        }
        return result
    }
}
