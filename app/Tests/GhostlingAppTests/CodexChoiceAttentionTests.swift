import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

@MainActor
struct CodexChoiceAttentionTests {
    @Test func codexChoiceScreenMovesOwnedCardToNeedsYouAndBackToWorking() throws {
        let shell = BoardShell(seeds: [])
        shell.launchOverrideForTesting = { seed in
            let sessionPTY = try! PTYSession(command: ["/bin/cat"])
            try! sessionPTY.start()
            return Session(
                projectDir: seed.projectDir,
                agentType: .codex,
                flowTag: .interactive,
                pty: sessionPTY,
                state: .running
            )
        }

        let card = try #require(shell.createSession(
            title: "Decide task scope",
            projectDir: FileManager.default.temporaryDirectory.path,
            autoStartAgent: .codex
        ))

        shell.reconcileCodexChoiceScreenForTesting(cardID: card.id, screen: codexChoiceScreen)

        #expect(shell.cards.first { $0.id == card.id }?.state == .waitingForInput)

        shell.reconcileCodexChoiceScreenForTesting(cardID: card.id, screen: "working on it")

        #expect(shell.cards.first { $0.id == card.id }?.state == .running)
        shell.e2eTeardown()
    }

    private var codexChoiceScreen: String {
        """
        Which design decisions should we document in this phase?

        1. All 8 (Recommended)
        2. Core 5 only
        3. Blocking 3 only
        4. Type something.

        Enter to select · ↑/↓ to navigate · Esc to cancel
        """
    }
}
