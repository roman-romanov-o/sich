import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

/// Field report 2026-07-16: cards jump OUT of WORKING and back into QUEUE, which is
/// confusing. Under the CARD-STATUS.md contract QUEUE is reserved for work that has
/// not started: once a session is engaged, automation moves it only between WORKING
/// and NEEDS YOU (turn end → rule 3; silent stall → rule 2.1) — never back to QUEUE.
///
/// Three production paths could rewind a started session, and each gets a test here:
/// a mid-session `SessionStart`, the stall sweep, and an unrecognized hook.
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
        let store = HookSessionStore(stallThreshold: 30)
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

    /// CARD-STATUS.md rule 2.1: a WORKING session silent past the stall threshold
    /// moves to NEEDS YOU — a hung/stuck/dead loop needs eyes, and it must NOT slide
    /// back to QUEUE (the door this suite guards).
    @Test func stallSweepMovesSilentWorkingSessionToNeedsYouNotQueue() {
        let store = workingStore()
        store.sweepStale(now: base.addingTimeInterval(60))

        #expect(store.entry(for: "s")?.state == .waitingForInput,
                "silence past the stall threshold is an attention signal, never a rewind to QUEUE")
        store.sweepStale(now: base.addingTimeInterval(600))
        #expect(store.entry(for: "s")?.state == .waitingForInput)
    }

    @Test func unrecognizedHookMarksWorkingCardUnknown() {
        let store = workingStore()
        store.ingest([normalized(#"{"hook_event_name":"SomeFutureHook","session_id":"s"}"#,
                                 arrival: base.addingTimeInterval(10))])

        #expect(store.entry(for: "s")?.state == .unknown,
                "an undetermined signal must stay explicit, not become attention")
    }

    /// CARD-STATUS.md rule 1: QUEUE is for work that has NOT started — and a
    /// launched-but-unprompted claude has not started. Card creation auto-launches
    /// the agent, so its SessionStart must leave the card in QUEUE (`.idle`),
    /// through sweeps too (an at-rest session never stalls into NEEDS YOU). Work
    /// begins at the first prompt, and only THEN does the stall guard arm.
    @Test func launchedButUnpromptedSessionRestsInQueueUntilFirstPrompt() {
        let store = HookSessionStore(stallThreshold: 30)
        #expect(store.entry(for: "fresh") == nil, "no events → no entry → the card stays QUEUE")

        store.ingest([normalized(#"{"hook_event_name":"SessionStart","session_id":"fresh"}"#,
                                 arrival: base)])
        #expect(store.entry(for: "fresh")?.state == .idle,
                "launching an agent is not starting work — the card stays QUEUE")
        store.sweepStale(now: base.addingTimeInterval(60))
        #expect(store.entry(for: "fresh")?.state == .idle,
                "an unprompted session is deliberately at rest, never a stall")

        store.ingest([normalized(#"{"hook_event_name":"UserPromptSubmit","session_id":"fresh"}"#,
                                 arrival: base.addingTimeInterval(70))])
        #expect(store.entry(for: "fresh")?.state == .running)
        store.sweepStale(now: base.addingTimeInterval(110))
        #expect(store.entry(for: "fresh")?.state == .waitingForInput,
                "once work started, silence past the threshold is rule 2.1 — NEEDS YOU, not QUEUE")
    }

    /// Bug 2026-07-20 (card 13E294A4): SessionEnd used to latch the session `.done`
    /// FOREVER, and app restarts `claude --resume` the SAME session id — so every
    /// post-restart hook was swallowed and the card froze at seed idle. SessionEnd
    /// is a RESUMABLE rest (`.idle`); later signals on the same id must land.
    @Test func endedSessionRestsAndResumes() {
        let store = workingStore()
        store.ingest([normalized(#"{"hook_event_name":"SessionEnd","session_id":"s"}"#,
                                 arrival: base.addingTimeInterval(5))])
        #expect(store.entry(for: "s")?.state == .idle,
                "process exit is a resumable rest — DONE is manual and board-owned only")

        store.ingest([normalized(#"{"hook_event_name":"Notification","session_id":"s"}"#,
                                 arrival: base.addingTimeInterval(15))])
        #expect(store.entry(for: "s")?.state == .waitingForInput,
                "a resumed session's attention signal must land, not be swallowed by a done-latch")
    }

    /// The full app-restart lifecycle on ONE session id (quit → relaunch →
    /// `claude --resume` → work → turn end), each hop a separate coalesce burst.
    /// This is the exact sequence the done-latch froze.
    @Test func restartResumeLifecycleTracksThroughAllStates() {
        let store = workingStore()
        let hops: [(String, TimeInterval, CardState, String)] = [
            ("SessionEnd", 5, .idle, "quit → resumable rest"),
            ("SessionStart", 10, .idle, "relaunch resume-start is neutral, still at rest"),
            ("UserPromptSubmit", 15, .running, "post-restart prompt puts it back to work"),
            ("Stop", 20, .waitingForInput, "turn end lands as NEEDS YOU (rule 3)"),
        ]
        for (hook, offset, expected, why) in hops {
            store.ingest([normalized(
                #"{"hook_event_name":"\#(hook)","session_id":"s"}"#,
                arrival: base.addingTimeInterval(offset))])
            #expect(store.entry(for: "s")?.state == expected, Comment(rawValue: why))
        }
    }

    /// A straggler SubagentStop landing AFTER the root Stop (children can outlive
    /// the turn boundary in the event file) must not revive a waiting session to
    /// WORKING — SubagentStop says nothing about the root turn.
    @Test func stragglerSubagentStopDoesNotReviveWaitingSession() {
        let store = workingStore()
        store.ingest([normalized(#"{"hook_event_name":"Stop","session_id":"s"}"#,
                                 arrival: base.addingTimeInterval(5))])
        #expect(store.entry(for: "s")?.state == .waitingForInput)

        store.ingest([normalized(#"{"hook_event_name":"SubagentStop","session_id":"s"}"#,
                                 arrival: base.addingTimeInterval(7))])
        #expect(store.entry(for: "s")?.state == .waitingForInput,
                "a child's exit is not the root's activity — attention must stick")
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

    @Test func doneCanOnlyBeEnteredAndExitedManually() throws {
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
                "manual reopen from DONE must not be undone by detector output")

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
        #expect(try #require(shell.cards.first).state == .running,
                "even a fresh agent completion cannot move the task to DONE")

        shell.move(cardID: card.id, to: .done)
        #expect(try #require(shell.cards.first).state == .done)

        let laterWork = BoardCard(
            sessionID: "claude-later", projectDir: "/work",
            agent: .claude, flow: .b, state: .running,
            updatedAt: base.addingTimeInterval(3)
        )
        shell.applySessions([laterWork])
        #expect(try #require(shell.cards.first).state == .done,
                "detector output cannot reopen a manually completed task")

        shell.move(cardID: card.id, to: .running)
        #expect(try #require(shell.cards.first).state == .running,
                "the operator can manually return DONE to WORKING")
    }
}
