import SichCore
import Testing

@testable import SichApp

/// US-005 / TC-INT-015: the board must keep updating while the operator is drilled
/// into a terminal, so on return the columns — and the always-visible attention
/// badge — already reflect reality instead of a frozen snapshot. These drive
/// `BoardShell.applySessions` with a live state change while `focusedCardID != nil`
/// and read the deterministic `lastAttentionCount` seam to prove the re-render
/// happened (never a wall-clock latency assertion).
@MainActor
struct BoardShellTests {
    /// A light owned seed: the demo-stub PTY (a real `/bin/sh`, cheap to launch)
    /// standing in for the live terminal whose PTY we own and can drill into.
    private func ownedShell() -> BoardShell {
        let seed = BoardSeed(
            sessionID: "live-terminal", projectDir: "/work",
            agent: .claude, flow: .b, state: .idle, scrollback: "ready"
        )
        let shell = BoardShell(seeds: [seed])
        shell.buildContentForTesting()
        return shell
    }

    /// The focused terminal's own agent starts waiting on the operator (same `/work`
    /// dir → the owned card adopts it).
    private func waitingHook() -> BoardCard {
        BoardCard(sessionID: "claude-abc", projectDir: "/work",
                  agent: .claude, flow: .b, state: .waitingForInput)
    }

    /// AC#1 + edge case 2: with a terminal focused (drilled in), a live state change
    /// STILL re-renders the board — the attention badge count updates without waiting
    /// for blur. RED before the fix (the old `focusedCardID == nil` guard froze the
    /// badge at 0), GREEN after.
    @Test func applySessions_rendersWhileFocused() {
        let shell = ownedShell()
        let owned = shell.cards.first { $0.sessionID == "live-terminal" }!
        shell.drill(into: owned)                       // focusedCardID != nil
        #expect(shell.lastAttentionCount == 0)    // idle → nothing waiting yet

        shell.applySessions([waitingHook()])

        // Board re-rendered DESPITE being focused: the badge tracks the live count.
        #expect(shell.lastAttentionCount == 1)
    }

    /// Edge case 1: drilling out then back in rapidly drops no update — the last
    /// applied snapshot is reflected in the badge regardless of focus churn.
    @Test func rapidFocusBlur_dropsNoUpdate() {
        let shell = ownedShell()
        let owned = shell.cards.first { $0.sessionID == "live-terminal" }!

        shell.drill(into: owned)
        shell.returnToBoard()
        shell.drill(into: owned)                        // rapid in → out → in

        shell.applySessions([waitingHook()])
        #expect(shell.lastAttentionCount == 1)     // update landed despite the churn
    }
}
