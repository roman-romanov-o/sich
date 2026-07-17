import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

/// Reproduces the two terminal-state-reading bugs reported against the live board.
///
///  1. **The task you didn't touch moves too.** Two task cards created in the SAME
///     repo, an agent run started in only ONE of them → BOTH cards jump to
///     running/done. Cause: an owned card adopts an observed session's state by
///     *shared project dir*, and a repo dir is not unique to one task (the hook
///     forwarder is only installed in this repo, so realistically every task shares
///     its dir — the collision is the common case, not the edge case).
///
///  2. **"Done" instead of "idle."** A Claude `Stop` hook fires at the end of a turn.
///     It clears running status; it is not a terminal session end and not the explicit
///     "needs input" signal (that is `Notification`/permission).
///
/// Deterministic: no real `claude`, no wall clock. The reported end-to-end scenario is
/// driven through the exact seams that decide card placement (`BoardShell.applySessions`
/// and `HookSessionStore`) — the same layer `BoardSessionMergeTests` exercises.
@MainActor
struct TerminalStateBugReproTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    /// Two task cards, BOTH created in the same repo dir — the realistic dogfood case.
    private func twoTasksInOneRepo() -> BoardShell {
        func task(_ id: String) -> BoardSeed {
            BoardSeed(sessionID: id, projectDir: "/repo", agent: .claude,
                      flow: .b, state: .idle, scrollback: "ready")
        }
        let shell = BoardShell(seeds: [task("task-a-untouched"), task("task-b-active")])
        _ = shell.buildContentForTesting()
        return shell
    }

    /// The hook-observed Claude run you started in ONE of the two tasks: a fresh
    /// `session_id`, cwd = the shared repo dir.
    private func claudeRun(_ state: CardState) -> BoardCard {
        BoardCard(sessionID: "claude-uuid", projectDir: "/repo", agent: .claude,
                  flow: .b, state: state, updatedAt: base.addingTimeInterval(100))
    }

    // MARK: - Bug 1: the task you never opened must not move

    @Test func untouchedTaskInSameRepoDoesNotMove() throws {
        let shell = twoTasksInOneRepo()

        shell.applySessions([claudeRun(.running)])

        let a = try #require(shell.cards.first { $0.sessionID == "task-a-untouched" })
        #expect(a.state == .idle,
                "a task you never opened must not move to running just because ANOTHER task in the same repo did")
        // The unattributable session is suppressed, NOT surfaced as its own card —
        // in a dir the operator already has task cards, an extra status card reads
        // as an unclickable duplicate (field report 2026-07-04). In-pty runs are
        // attributed by GHOSTLING_CARD_ID binding instead.
        #expect(!shell.cards.contains { $0.sessionID == "claude-uuid" },
                "an unbound session in an owned dir must not surface as a duplicate status card")
    }

    @Test func untouchedTaskInSameRepoIsNotMarkedDone() throws {
        let shell = twoTasksInOneRepo()

        shell.applySessions([claudeRun(.done)])

        let a = try #require(shell.cards.first { $0.sessionID == "task-a-untouched" })
        #expect(a.state != .done,
                "the untouched task must not be marked done when a DIFFERENT task's agent finishes")
    }

    @Test func completedTaskInSameRepoDoesNotReopenToNeedsYou() throws {
        let shell = twoTasksInOneRepo()
        let completed = try #require(shell.cards.first { $0.sessionID == "task-a-untouched" })

        shell.move(cardID: completed.id, to: .done)
        shell.applySessions([
            BoardCard(
                sessionID: "stale-notification", projectDir: "/repo", agent: .claude,
                flow: .b, state: .waitingForInput,
                updatedAt: base.addingTimeInterval(200),
                boundCardID: completed.id.uuidString
            )
        ])

        let actual = try #require(shell.cards.first { $0.id == completed.id })
        #expect(actual.state == .done,
                "a manually completed task must not reopen to NEEDS YOU from a later hook observation")
    }

    // MARK: - Bug 2: after a turn, the agent is IDLE, not DONE or attention

    /// The hook stream a real "wait 20 seconds, then say hello" turn produces, each
    /// event its own coalesce burst (>1s apart) so the whole transition path is applied.
    @Test func agentAwaitingYourResponseIsWaitingNotDone() throws {
        let store = HookSessionStore(staleThreshold: 30)
        func ev(_ name: String, _ offset: TimeInterval) -> SignalEvent {
            HookNormalizer.normalize(
                Data(#"{"hook_event_name":"\#(name)","session_id":"turn","cwd":"/repo"}"#.utf8),
                arrival: base.addingTimeInterval(offset))!
        }
        store.ingest([
            ev("SessionStart", 0),
            ev("UserPromptSubmit", 2),   // you typed "wait 20 seconds, then say hello"
            ev("PreToolUse", 4),         // claude runs `sleep 20`
            ev("PostToolUse", 26),       // …done sleeping
            ev("Stop", 27),              // Claude ended the active turn
        ])

        let state = try #require(store.entry(for: "turn")?.state)
        #expect(state == .idle,
                "a Stop hook clears running; it is not done and not an attention signal")
        #expect(!state.needsAttention)
        #expect(BoardColumn(state: state) == .idle)
    }

    /// And idle must persist — it must NOT decay to `unknown` after the turn has
    /// already stopped.
    @Test func idleAfterStopSurvivesSilence() throws {
        let store = HookSessionStore(staleThreshold: 30)
        store.ingest([
            HookNormalizer.normalize(
                Data(#"{"hook_event_name":"Stop","session_id":"turn","cwd":"/repo"}"#.utf8),
                arrival: base)!,
        ])
        store.sweepStale(now: base.addingTimeInterval(120))   // you stepped away for 2 min
        #expect(store.entry(for: "turn")?.state == .idle,
                "a stopped session should stay idle through silence, not decay to unknown")
    }
}
