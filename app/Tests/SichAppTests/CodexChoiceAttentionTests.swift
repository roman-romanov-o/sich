import Foundation
import SichCore
import Testing

@testable import SichApp

@MainActor
struct CodexChoiceAttentionTests {
    /// A running owned Codex card wired so `reconcileCodexChoiceScreenForTesting` and
    /// `applySessions` can drive its state.
    private func codexCard() throws -> (BoardShell, BoardCard) {
        let shell = BoardShell(seeds: [])
        shell.launchOverrideForTesting = { seed in
            let sessionPTY = try! PTYSession(command: ["/bin/cat"])
            try! sessionPTY.start()
            return Session(
                projectDir: seed.projectDir,
                agentType: .codex,
                pty: sessionPTY,
                state: .running
            )
        }
        let card = try #require(shell.createSession(
            title: "Decide task scope",
            projectDir: FileManager.default.temporaryDirectory.path,
            autoStartAgent: .codex
        ))
        return (shell, card)
    }

    @Test func codexChoiceScreenMovesOwnedCardToNeedsYouAndBackToWorking() throws {
        let (shell, card) = try codexCard()

        shell.reconcileCodexChoiceScreenForTesting(cardID: card.id, screen: codexChoiceScreen)

        #expect(shell.cards.first { $0.id == card.id }?.state == .waitingForInput)

        shell.reconcileCodexChoiceScreenForTesting(cardID: card.id, screen: "working on it")

        #expect(shell.cards.first { $0.id == card.id }?.state == .running)

        // A root-turn Stop reaches the same card through hooks. A normal prompt is
        // not a choice screen, but it must not clear this hook-derived Needs You.
        shell.applySessions([
            BoardCard(
                sessionID: "codex-hook-session", projectDir: card.projectDir,
                agent: .codex, state: .waitingForInput,
                updatedAt: Date(), boundCardID: card.id.uuidString
            )
        ])
        shell.reconcileCodexChoiceScreenForTesting(cardID: card.id, screen: "ready for your next prompt")
        #expect(shell.cards.first { $0.id == card.id }?.state == .waitingForInput,
                "terminal choice detection must not erase hook-derived Needs You")
        shell.e2eTeardown()
    }

    /// The reverse ordering: a hook puts the card into Needs You FIRST, then a choice
    /// screen coincides. The pixel detector must not claim ownership of a wait it did
    /// not originate, so a later clear of the choice screen cannot stomp the still-
    /// pending hook Needs You (which the terminal itself can't see).
    @Test func hookNeedsYouSurvivesACoincidingChoiceScreen() throws {
        let (shell, card) = try codexCard()

        shell.applySessions([
            BoardCard(
                sessionID: "codex-hook-session", projectDir: card.projectDir,
                agent: .codex, state: .waitingForInput,
                updatedAt: Date(), boundCardID: card.id.uuidString
            )
        ])
        #expect(shell.cards.first { $0.id == card.id }?.state == .waitingForInput)

        // A choice screen renders while the hook wait is still pending.
        shell.reconcileCodexChoiceScreenForTesting(cardID: card.id, screen: codexChoiceScreen)
        #expect(shell.cards.first { $0.id == card.id }?.state == .waitingForInput)

        // The pixel choice screen clears. The detector never owned this wait, so it must
        // leave the hook-derived Needs You intact rather than flipping it to working.
        shell.reconcileCodexChoiceScreenForTesting(cardID: card.id, screen: "working on it")
        #expect(shell.cards.first { $0.id == card.id }?.state == .waitingForInput,
                "a coinciding choice-screen clear must not erase a hook-owned Needs You")
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
