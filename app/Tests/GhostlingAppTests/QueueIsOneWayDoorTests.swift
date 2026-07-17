import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

/// Field report 2026-07-16: cards jump OUT of WORKING and back into QUEUE, which is
/// confusing. The fix is not to guess "needs you" from at-rest signals; instead the
/// detector renders explicit idle/unknown unless Claude sends a notification or
/// permission hook.
///
/// Three production paths could rewind a started session, and each gets a test here:
/// a mid-session `SessionStart`, the stale sweep, and an unrecognized hook.
///
/// Deterministic throughout: every timestamp is injected (epoch + offsets), never the
/// wall clock — the anti-flake rule (GridTextTests fromPTY PTY-EOF precedent).
@MainActor
struct QueueIsOneWayDoorTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func normalized(_ json: String, arrival: Date) -> SignalEvent {
        HookNormalizer.normalize(Data(json.utf8), arrival: arrival)!
    }

    /// A working session that receives a fresh `SessionStart` — Claude re-emits one on
    /// `--resume`, `/clear`, and compaction — must not read as never-started.
    private func workingStore() -> HookSessionStore {
        let store = HookSessionStore(staleThreshold: 30)
        store.ingest([
            normalized(#"{"hook_event_name":"SessionStart","session_id":"s"}"#, arrival: base),
            normalized(#"{"hook_event_name":"UserPromptSubmit","session_id":"s"}"#,
                       arrival: base.addingTimeInterval(2)),
        ])
        return store
    }

    @Test func midSessionStartDoesNotRewindWorkingCardToQueue() {
        let store = workingStore()
        #expect(store.entry(for: "s")?.state == .running)

        // /clear mid-task: a second SessionStart on an already-running session.
        store.ingest([normalized(#"{"hook_event_name":"SessionStart","session_id":"s"}"#,
                                 arrival: base.addingTimeInterval(10))])

        #expect(store.entry(for: "s")?.state == .running,
                "a repeated SessionStart keeps cmux-style active status")
    }

    @Test func staleSweepMarksWorkingSessionUnknownInsteadOfGuessingAttention() {
        let store = workingStore()
        store.sweepStale(now: base.addingTimeInterval(60))

        #expect(store.entry(for: "s")?.state == .unknown,
                "silence past the threshold is unknown, not a guessed needs-you state")
        store.sweepStale(now: base.addingTimeInterval(600))
        #expect(store.entry(for: "s")?.state == .unknown)
    }

    @Test func unrecognizedHookMarksWorkingCardUnknown() {
        let store = workingStore()
        store.ingest([normalized(#"{"hook_event_name":"SomeFutureHook","session_id":"s"}"#,
                                 arrival: base.addingTimeInterval(10))])

        #expect(store.entry(for: "s")?.state == .unknown,
                "an undetermined signal must stay explicit, not become attention")
    }

    /// A never-started session is the one case QUEUE is still correct for — the fix must
    /// not swallow it.
    @Test func neverStartedSessionStillSitsInQueue() {
        let store = HookSessionStore(staleThreshold: 30)
        store.ingest([normalized(#"{"hook_event_name":"SessionStart","session_id":"fresh"}"#,
                                 arrival: base)])
        #expect(store.entry(for: "fresh")?.state == .running)
        store.sweepStale(now: base.addingTimeInterval(60))
        #expect(store.entry(for: "fresh")?.state == .unknown,
                "a stale session is unknown until a stronger signal arrives")
    }

    /// A finished card stays finished; an at-rest signal after DONE means nothing.
    @Test func doneSessionStaysDone() {
        let store = workingStore()
        store.ingest([normalized(#"{"hook_event_name":"SessionEnd","session_id":"s"}"#,
                                 arrival: base.addingTimeInterval(5))])
        #expect(store.entry(for: "s")?.state == .done)

        store.ingest([normalized(#"{"hook_event_name":"SomeFutureHook","session_id":"s"}"#,
                                 arrival: base.addingTimeInterval(10))])
        #expect(store.entry(for: "s")?.state == .done)

        store.ingest([normalized(#"{"hook_event_name":"Notification","session_id":"s"}"#,
                                 arrival: base.addingTimeInterval(15))])
        #expect(store.entry(for: "s")?.state == .done,
                "a finished session must not reopen to NEEDS YOU from a later notification")
    }

    // MARK: - The same rule at the board merge

    /// The merge can also adopt state from a session joined by project dir, so it
    /// enforces the rule independently of the store.
    ///
    /// Deliberately drives a card parked in NEEDS YOU, not one mid-run: a running card's
    /// at-rest dip is absorbed by the 15s `idleHoldInterval`, which reads the wall clock
    /// and would make this pass without the rule under test even if the rule were gone
    /// (verified — it did). A waiting card takes the immediate path, so this binds.
    @Test func boardMergeDoesNotRewindStartedCardToQueue() throws {
        let seed = BoardSeed(
            sessionID: "live-terminal", projectDir: "/work",
            agent: .claude, flow: .b, state: .idle, scrollback: "ready"
        )
        let shell = BoardShell(seeds: [seed])
        _ = shell.buildContentForTesting()

        func observe(_ state: CardState, at: Date) {
            shell.applySessions([BoardCard(sessionID: "claude-1", projectDir: "/work",
                                           agent: .claude, flow: .b, state: state, updatedAt: at)])
        }

        // The agent worked, then an explicit notification parked it in NEEDS YOU.
        observe(.running, at: base)
        observe(.waitingForInput, at: base.addingTimeInterval(10))
        #expect(try #require(shell.cards.first { $0.sessionID == "live-terminal" }).state
                == .waitingForInput)

        // Now an at-rest observation arrives for that same started card.
        observe(.idle, at: base.addingTimeInterval(20))

        let owned = try #require(shell.cards.first { $0.sessionID == "live-terminal" })
        #expect(owned.state == .idle,
                "Stop/idle clears attention; only notification/permission hooks put it back")
    }

    /// Manual drag stays exempt — you can always put a card back yourself.
    @Test func manualMoveToQueueStillWorks() throws {
        let seed = BoardSeed(
            sessionID: "live-terminal", projectDir: "/work",
            agent: .claude, flow: .b, state: .running, scrollback: "ready"
        )
        let shell = BoardShell(seeds: [seed])
        _ = shell.buildContentForTesting()
        let card = try #require(shell.cards.first)

        shell.move(cardID: card.id, to: .idle)

        #expect(try #require(shell.cards.first).state == .idle,
                "the one-way door is for AUTOMATIC transitions; you keep manual control")
    }

    @Test func manualMoveOutOfDoneIgnoresStaleDoneUntilFreshWork() throws {
        let seed = BoardSeed(
            sessionID: "live-terminal", projectDir: "/work",
            agent: .claude, flow: .b, state: .done, scrollback: "finished"
        )
        let shell = BoardShell(seeds: [seed])
        _ = shell.buildContentForTesting()
        let card = try #require(shell.cards.first)

        shell.move(cardID: card.id, to: .idle)
        #expect(try #require(shell.cards.first).state == .idle)

        let oldDone = BoardCard(
            sessionID: "claude-old", projectDir: "/work",
            agent: .claude, flow: .b, state: .done,
            updatedAt: base
        )
        shell.applySessions([oldDone])
        #expect(try #require(shell.cards.first).state == .idle,
                "manual reopen from DONE must not be undone by the stale finished run")

        let freshWork = BoardCard(
            sessionID: "claude-new", projectDir: "/work",
            agent: .claude, flow: .b, state: .running,
            updatedAt: base.addingTimeInterval(1)
        )
        shell.applySessions([freshWork])
        #expect(try #require(shell.cards.first).state == .running)

        let freshDone = BoardCard(
            sessionID: "claude-new", projectDir: "/work",
            agent: .claude, flow: .b, state: .done,
            updatedAt: base.addingTimeInterval(2)
        )
        shell.applySessions([freshDone])
        #expect(try #require(shell.cards.first).state == .done,
                "after fresh work, a new completion can move the card to DONE again")
    }
}
