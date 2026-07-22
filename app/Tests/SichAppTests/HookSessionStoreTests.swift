import Foundation
import SichCore
import Testing

@testable import SichApp

/// Reconciler-correctness invariants the live board depends on (US-002). Two bound
/// symbols live here:
///
/// - **TC-UNIT-012** — freshest state wins by `updatedAt`: when several agent sessions
///   have run in ONE project dir, the owned card must track what is *live now* by
///   observation time, so a STALE `blocked`/`waiting` from a finished run can never
///   out-rank a FRESH `running`. Ordering is by `updatedAt` (already on the model), no
///   `seq`/`ppid`.
/// - **TC-UNIT-014** — a clean `SessionEnd` puts the session at rest immediately
///   (resumable `.idle`, never auto-`done`), while a hard-killed run with no
///   `SessionEnd` still recovers via the stall guard: silence past the threshold
///   routes to NEEDS YOU (rule 2.1).
///
/// Deterministic throughout: every timestamp is injected (epoch + offsets), never the
/// wall clock — the anti-flake rule (GridTextTests fromPTY PTY-EOF precedent).
@MainActor
struct HookSessionStoreTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func ownedShell() -> BoardShell {
        let seed = BoardSeed(
            sessionID: "live-terminal", projectDir: "/work",
            agent: .claude, flow: .b, state: .idle, scrollback: "ready"
        )
        let shell = BoardShell(seeds: [seed])
        _ = shell.buildContentForTesting()
        return shell
    }

    private func run(_ id: String, _ state: CardState, at: Date) -> BoardCard {
        BoardCard(sessionID: id, projectDir: "/work", agent: .claude, flow: .b,
                  state: state, updatedAt: at)
    }

    private func normalized(_ json: String, arrival: Date) -> SignalEvent {
        HookNormalizer.normalize(Data(json.utf8), arrival: arrival)!
    }

    // MARK: - TC-UNIT-012: freshest state wins by updatedAt

    @Test func updatedAtTiebreak_freshWins() throws {
        let shell = ownedShell()   // owned card: dir "/work", state .idle

        // Two agent sessions have run in this ONE terminal: an OLD blocked/waiting run
        // and a FRESHER running one. By activity-rank alone `blocked` (5) out-ranks
        // `running` (3) — the stale-out-ranks-fresh bug. `updatedAt` must decide first.
        let stale = run("claude-old", .blocked, at: base)
        let fresh = run("claude-new", .running, at: base.addingTimeInterval(10))
        shell.applySessions([stale, fresh])

        let owned = try #require(shell.cards.first { $0.sessionID == "live-terminal" })
        #expect(owned.state == .running,
                "the freshest observation must win — a stale blocked run cannot out-rank a fresh running one")
    }

    /// CARD-STATUS.md rule 1: launching an agent is not starting work. Creating a
    /// card auto-launches claude, and that SessionStart alone must leave the card in
    /// QUEUE — only the first submitted prompt moves it to WORKING.
    @Test func freshSessionStaysQueuedUntilFirstPrompt() {
        let store = HookSessionStore(stallThreshold: 30)
        store.ingest([normalized(#"{"hook_event_name":"SessionStart","session_id":"fresh"}"#,
                                 arrival: base)])
        #expect(store.entry(for: "fresh")?.state == .idle,
                "a launched-but-unprompted claude has not started work (rule 1)")
        store.ingest([normalized(#"{"hook_event_name":"UserPromptSubmit","session_id":"fresh"}"#,
                                 arrival: base.addingTimeInterval(2))])
        #expect(store.entry(for: "fresh")?.state == .running)
    }

    // MARK: - TC-UNIT-014: sessionEnd closes now; hard-kill recovers via the stall guard

    @Test func sessionEnd_closesNow_hardKillDecays() {
        let store = HookSessionStore(stallThreshold: 30)

        // A clean SessionEnd hook puts the session at rest IMMEDIATELY — no 30s
        // wait. `.idle`, NOT `.done`: DONE is manual-only (CARD-STATUS.md rule 4),
        // and app restarts `claude --resume` the SAME session id, so the rest must
        // be resumable. The timestamps are 2s apart (a separate coalesce burst).
        store.ingest([
            normalized(#"{"hook_event_name":"SessionStart","session_id":"graceful"}"#,
                       arrival: base),
            normalized(#"{"hook_event_name":"SessionEnd","session_id":"graceful"}"#,
                       arrival: base.addingTimeInterval(2)),
        ])
        #expect(store.entry(for: "graceful")?.state == .idle,
                "a closed session rests in QUEUE, resumable — never auto-done")
        // …and it stays at rest: a later sweep does not stall an idle session.
        store.sweepStale(now: base.addingTimeInterval(3))
        #expect(store.entry(for: "graceful")?.state == .idle)

        // A hard-killed run just stops POSTing — no SessionEnd. It is NOT flagged on
        // the next poll (still within the stall budget)…
        store.ingest([
            normalized(#"{"hook_event_name":"PreToolUse","session_id":"killed"}"#,
                       arrival: base),
        ])
        store.sweepStale(now: base.addingTimeInterval(5))
        #expect(store.entry(for: "killed")?.state == .running)
        // …but the stall guard (CARD-STATUS.md rule 2.1) reaps it once silence passes
        // the threshold: a dead loop needs the operator's eyes → NEEDS YOU.
        store.sweepStale(now: base.addingTimeInterval(31))
        #expect(store.entry(for: "killed")?.state == .waitingForInput)
    }
}
