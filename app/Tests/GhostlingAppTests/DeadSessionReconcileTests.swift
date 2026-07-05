import AppKit
import GhostlingCore
import Testing

@testable import GhostlingApp

/// The BoardShell dead-session reconcile loop: a card whose child has exited must
/// come OFF the board (off-screen) or show the end banner first (drilled in) — the
/// board never lies about a dead shell. This is the gap the UX audit found: the
/// shipped surface never called `markEnded` and dead owned cards lingered forever.
@MainActor
@Suite("Dead-session reconcile (BoardShell)")
struct DeadSessionReconcileTests {

    /// A seed whose child exits immediately (`/bin/sh -c true`).
    private func shortLivedSeed(id: String = "dies/now") -> BoardSeed {
        BoardSeed(
            sessionID: id, projectDir: "~/demo", agent: .claude, flow: .a,
            state: .running, scrollback: "", commandOverride: ["/bin/sh", "-c", "true"]
        )
    }

    /// Poll the reconcile pass until the exited child is reaped (bounded).
    private func reconcileUntilProcessed(_ shell: BoardShell) {
        for _ in 0..<200 {
            if !shell.reconcileDeadSessions().isEmpty { return }
            usleep(10_000)
        }
    }

    @Test("an off-screen card whose child exited is removed from the board")
    func deadCardIsRemoved() throws {
        let shell = BoardShell(seeds: [shortLivedSeed()])
        shell.buildContentForTesting()
        let card = try #require(shell.cards.first)

        reconcileUntilProcessed(shell)

        #expect(!shell.cards.contains(where: { $0.id == card.id }))
    }

    @Test("a drilled-in card survives until return, then is swept")
    func drilledInDeadCardSweptOnReturn() throws {
        let shell = BoardShell(seeds: [shortLivedSeed()])
        shell.buildContentForTesting()
        let card = try #require(shell.cards.first)
        shell.drill(into: card)

        // Child exits while drilled in: the card must NOT vanish under the operator.
        reconcileUntilProcessed(shell)
        #expect(shell.cards.contains(where: { $0.id == card.id }))

        shell.returnToBoard()
        #expect(!shell.cards.contains(where: { $0.id == card.id }))
    }
}
