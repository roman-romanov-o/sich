import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

/// Reconciler-correctness invariants the live board depends on (US-002). Two bound
/// symbols live here:
///
/// - **TC-UNIT-012** — freshest state wins by `updatedAt`: when several agent sessions
///   have run in ONE project dir, the owned card must track what is *live now* by
///   observation time, so a STALE `blocked`/`waiting` from a finished run can never
///   out-rank a FRESH `running`. Ordering is by `updatedAt` (already on the model), no
///   `seq`/`ppid`.
/// - **TC-UNIT-014** — a clean `SessionEnd` closes the session immediately (no 30s
///   wait), while a hard-killed run with no `SessionEnd` still decays via the
///   stale-sweep backstop.
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

    /// Field report 2026-07-05: a freshly created task (claude auto-started, sitting
    /// at its first prompt) must land in Idle, not Running — it only starts running
    /// once you actually submit a prompt.
    @Test func freshSessionIsIdleUntilFirstPrompt() {
        let store = HookSessionStore(staleThreshold: 30)
        store.ingest([normalized(#"{"hook_event_name":"SessionStart","session_id":"fresh"}"#,
                                 arrival: base)])
        #expect(store.entry(for: "fresh")?.state == .idle)
        store.ingest([normalized(#"{"hook_event_name":"UserPromptSubmit","session_id":"fresh"}"#,
                                 arrival: base.addingTimeInterval(2))])
        #expect(store.entry(for: "fresh")?.state == .running)
    }

    // MARK: - TC-UNIT-014: sessionEnd closes now; hard-kill decays via the sweep

    @Test func sessionEnd_closesNow_hardKillDecays() {
        let store = HookSessionStore(staleThreshold: 30)

        // A clean SessionEnd hook closes the session IMMEDIATELY — no 30s wait. The
        // timestamps are 2s apart (a separate coalesce burst), injected via `arrival`.
        store.ingest([
            normalized(#"{"hook_event_name":"SessionStart","session_id":"graceful"}"#,
                       arrival: base),
            normalized(#"{"hook_event_name":"SessionEnd","session_id":"graceful"}"#,
                       arrival: base.addingTimeInterval(2)),
        ])
        #expect(store.entry(for: "graceful")?.state == .done)
        // …and it stays closed: a later sweep does not reopen a terminal state.
        store.sweepStale(now: base.addingTimeInterval(3))
        #expect(store.entry(for: "graceful")?.state == .done)

        // A hard-killed run just stops POSTing — no SessionEnd. It is NOT closed on the
        // next poll (still within the stale window)…
        store.ingest([
            normalized(#"{"hook_event_name":"PreToolUse","session_id":"killed"}"#,
                       arrival: base),
        ])
        store.sweepStale(now: base.addingTimeInterval(5))
        #expect(store.entry(for: "killed")?.state == .running)
        // …but the stale-decay backstop still reaps it once silence passes threshold.
        store.sweepStale(now: base.addingTimeInterval(31))
        #expect(store.entry(for: "killed")?.state == .unknown)
    }
}
