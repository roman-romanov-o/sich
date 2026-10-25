import Foundation
import SichCore
import Testing

@testable import SichApp

/// The board hosts two kinds of card at once: an **owned** session we launched in
/// our own PTY (the live interactive terminal — drillable, you run `claude` in it)
/// and **observed** sessions from hook POSTs we only watch (status-only, no PTY).
/// These drive `BoardShell.applySessions` — the live `/sessions` merge — to prove
/// the 3s poll does NOT wipe the real terminal, and that the watcher-not-spawner
/// constraint reaches the board: a session we never spawned is not drillable.
@MainActor
struct BoardSessionMergeTests {
    /// A light owned seed: the demo-stub PTY (a real `/bin/sh`, cheap to launch),
    /// standing in for the live terminal whose PTY we own.
    private func ownedShell(dir: String = "/work") -> BoardShell {
        let seed = BoardSeed(
            sessionID: "live-terminal", projectDir: dir,
            agent: .claude, state: .idle, scrollback: "ready"
        )
        let shell = BoardShell(seeds: [seed])
        shell.buildContentForTesting()
        return shell
    }

    private func observed(_ id: String, _ state: CardState) -> BoardCard {
        BoardCard(sessionID: id, projectDir: "/other", agent: .claude, state: state)
    }

    @Test func liveTerminalSurvivesTheSessionsPollAndStaysDrillable() {
        let shell = ownedShell()

        shell.applySessions([observed("sess-other", .running)])

        // Owned terminal kept; the external session is NOT surfaced as a card.
        #expect(shell.cards.map(\.sessionID) == ["live-terminal"])

        // Still drillable — it carries our PTY, so drilling hides the board.
        let owned = shell.cards.first { $0.sessionID == "live-terminal" }!
        shell.drill(into: owned)
        #expect(shell.boardView.isHidden)
    }

    /// A session in another terminal (no owned card matches its dir) is ignored: the
    /// board shows only what we created here, so there is never an un-openable card.
    @Test func externalSessionIsNotSurfacedOnTheBoard() {
        let shell = ownedShell()
        shell.applySessions([observed("sess-other", .running)])
        #expect(!shell.cards.contains { $0.sessionID == "sess-other" })
    }

    @Test func anEmptyPollLeavesTheLiveTerminalStanding() {
        let shell = ownedShell()
        shell.applySessions([])   // sidecar up, no observed sessions yet
        #expect(shell.cards.map(\.sessionID) == ["live-terminal"])
    }

    /// Running `claude` inside our owned `/work` terminal makes claude POST a hook
    /// session under ITS OWN `session_id` (≠ our "live-terminal" id) but the SAME
    /// `projectDir`. That session IS this terminal's agent: the owned card ADOPTS its
    /// live state and MOVES columns with the model's output — without spawning a
    /// second, drifting "claude-abc123" card.
    @Test func ownedTerminalAdoptsTheLiveStateOfClaudeRunningInIt() {
        let shell = ownedShell()   // owned card: id "live-terminal", dir "/work", state .idle

        let claudeHook = BoardCard(sessionID: "claude-abc123", projectDir: "/work",
                                   agent: .claude, state: .running)
        shell.applySessions([claudeHook])

        // Still ONE card, the owned one — not a second "claude-abc123" card.
        #expect(shell.cards.map(\.sessionID) == ["live-terminal"])
        // …and it MOVED: the owned card now shows claude's live state.
        #expect(shell.cards.first?.state == .running)
    }

    /// The owned terminal tracks live agent activity from the hook stream, but task
    /// completion remains an operator decision. An observed session end cannot move the
    /// task into DONE. One card throughout, PTY preserved (still drillable).
    @Test func ownedTerminalMovesAcrossColumnsAsTheModelWorks() throws {
        // A REAL dir: moving to DONE closes the pty (checklist 18.08 item 1), so the
        // final drill-in goes through revival — whose dir-exists guard a fictional
        // "/work" would fail, leaving the click inert.
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let shell = ownedShell(dir: work.path)
        func claude(_ state: CardState) -> BoardCard {
            BoardCard(sessionID: "claude-xyz", projectDir: work.path,
                      agent: .claude, state: state)
        }

        shell.applySessions([claude(.running)])
        #expect(shell.cards.first?.state == .running)

        shell.applySessions([claude(.waitingForInput)])
        #expect(shell.cards.first?.state == .waitingForInput)
        #expect(Attention.count(shell.cards) == 1)   // the notification: this card needs you

        shell.applySessions([claude(.done)])
        #expect(shell.cards.first?.state == .waitingForInput,
                "an agent/session completion must not complete the task")

        let cardID = try #require(shell.cards.first).id
        shell.move(cardID: cardID, to: .done)
        #expect(shell.cards.first?.state == .done)

        // One card the whole way through, still ours, still drillable — DONE freed
        // the terminal, so drilling back in revives a shell rather than reusing one.
        #expect(shell.cards.count == 1)
        shell.drill(into: shell.cards.first!)
        #expect(shell.boardView.isHidden)
        shell.e2eTeardown()
    }

    /// Hook sessions in a dir that no owned card matches belong to some other terminal
    /// — none of them are surfaced. The board is owned-cards-only, so external activity
    /// never adds cards you can't open.
    @Test func externalSessionsInAnUnownedDirAddNoCards() {
        let shell = ownedShell()      // owned card's dir is "/work"
        let repo = "/elsewhere"       // a dir no owned card matches
        func run(_ id: String, _ state: CardState) -> BoardCard {
            BoardCard(sessionID: id, projectDir: repo, agent: .claude, state: state)
        }
        shell.applySessions([run("run-1", .done), run("run-2", .running), run("run-3", .idle)])

        #expect(shell.cards.filter { $0.projectDir == repo }.isEmpty)
        #expect(shell.cards.map(\.sessionID) == ["live-terminal"])  // only what we own
    }

    /// When two agent sessions have run in one terminal — an old finished run plus a
    /// fresh active one — the owned card tracks what's live now (the active one), not
    /// the stale `done`.
    @Test func ownedTerminalTracksTheLiveRunNotAStaleFinishedOne() {
        let shell = ownedShell()
        let oldRun = BoardCard(sessionID: "claude-old", projectDir: "/work",
                               agent: .claude, state: .done)
        let freshRun = BoardCard(sessionID: "claude-new", projectDir: "/work",
                                 agent: .claude, state: .running)
        shell.applySessions([oldRun, freshRun])

        #expect(shell.cards.map(\.sessionID) == ["live-terminal"])  // no duplicates
        #expect(shell.cards.first?.state == .running)               // the live run wins
    }
}
