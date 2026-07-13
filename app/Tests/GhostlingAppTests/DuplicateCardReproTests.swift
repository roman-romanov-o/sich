import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

/// Repro of the field report (2026-07-04): an observed hook session was on the board
/// BEFORE the operator created a task card in the same dir; after creation the two
/// must fold into one owned card — never a lingering unclickable duplicate.
@MainActor
struct DuplicateCardReproTests {
    private let dir = "/Users/romanromanov/MyProjects/agentic-coding-kanban"

    @Test func observedCardFoldsIntoATaskCreatedAfterIt() {
        let shell = BoardShell(seeds: [])
        shell.buildContentForTesting()

        // 1. A claude session in the repo (another window) is observed first. With no
        //    owned card yet it is NOT surfaced — the board shows only what we created.
        let observed = [
            BoardCard(sessionID: "e00c9e6d-x", projectDir: dir, agent: .claude,
                      flow: .b, state: .running, updatedAt: Date()),
        ]
        shell.applySessions(observed)
        #expect(shell.cards.isEmpty)   // external session, not ours → not shown

        // 2. Operator creates the "test" task in the SAME dir.
        shell.createSession(title: "test", projectDir: dir)

        // 3. Next poll pushes the same snapshot: the observed session must be
        //    attributed to the owned card, not stay as its own unclickable card.
        shell.applySessions(observed)
        let ids = shell.cards.map(\.sessionID)
        #expect(!ids.contains("e00c9e6d-x"), "duplicate observed card survived: \(ids)")
        #expect(shell.cards.count == 1)
        #expect(shell.cards.first?.state == .running)   // owned card adopted the live state
    }

    /// The exact field failure: the seeded live terminal AND a created task share the
    /// repo dir, so the dir join is (rightly) suppressed as ambiguous — but the claude
    /// session inside the task's pty carries GHOSTLING_CARD_ID, so identity binding
    /// must fold it into THAT card, never leave it as an unclickable duplicate.
    @Test func boundSessionFoldsIntoItsCardDespiteAmbiguousDir() {
        let shell = BoardShell(seeds: [BoardSeed.liveTerminal(projectDir: dir)])
        shell.buildContentForTesting()
        shell.createSession(title: "test", projectDir: dir)
        let taskCard = shell.cards.first { $0.title == "test" }!

        let observed = [BoardCard(
            sessionID: "e00c9e6d-x", projectDir: dir, agent: .claude, flow: .b,
            state: .running, updatedAt: Date(), boundCardID: taskCard.id.uuidString)]
        shell.applySessions(observed)

        #expect(shell.cards.count == 2, "no duplicate: \(shell.cards.map(\.sessionID))")
        #expect(shell.cards.first { $0.id == taskCard.id }?.state == .running)
        // The live terminal (other card in the same dir) must NOT have moved.
        #expect(shell.cards.first { $0.id != taskCard.id }?.state == .idle)
    }

    /// An UNBOUND session (no GHOSTLING_CARD_ID — e.g. claude started in another
    /// terminal, or a run predating binding) in a dir where the operator has task
    /// cards must be suppressed, not surface as an unclickable duplicate card.
    @Test func unboundSessionInAmbiguousOwnedDirIsSuppressed() {
        let shell = BoardShell(seeds: [BoardSeed.liveTerminal(projectDir: dir)])
        shell.buildContentForTesting()
        shell.createSession(title: "test", projectDir: dir)

        shell.applySessions([BoardCard(
            sessionID: "e00c9e6d-x", projectDir: dir, agent: .claude,
            flow: .b, state: .running, updatedAt: Date())])

        #expect(shell.cards.count == 2, "extra card: \(shell.cards.map(\.sessionID))")
        #expect(!shell.cards.contains { $0.sessionID == "e00c9e6d-x" })
        // Neither owned card guessed the state — attribution stays honest.
        #expect(shell.cards.allSatisfy { $0.state == .idle })
    }

    /// A bound session must never fall through to the dir join or the extras list —
    /// even when its card's dir IS unique (binding and dir join agree, one card).
    @Test func bindingAndUniqueDirAgree() {
        let shell = BoardShell(seeds: [])
        shell.buildContentForTesting()
        shell.createSession(title: "solo", projectDir: dir)
        let card = shell.cards[0]
        shell.applySessions([BoardCard(
            sessionID: "s1", projectDir: dir, agent: .claude, flow: .b,
            state: .waitingForInput, updatedAt: Date(), boundCardID: card.id.uuidString)])
        #expect(shell.cards.count == 1)
        #expect(shell.cards[0].state == .waitingForInput)
    }
}
