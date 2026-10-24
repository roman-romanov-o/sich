import AppKit
import XCTest
@testable import SichApp
import SichCore

@MainActor
final class QuotaBlockCardTests: XCTestCase {

    func testQuotaSpentChipRendersOnIdleCard() {
        let card = BoardCard(
            sessionID: "s-1", title: "Finance search", projectDir: "/tmp/p",
            agent: .claude, state: .idle)
        let block = CardQuotaBlock.exhausted(reset: nil)
        let view = SessionCard(card: card, quotaBlock: block)
        let chip = allSubviews(of: view).first {
            $0.identifier?.rawValue == "quota-chip"
        }
        XCTAssertNotNil(chip)
        let label = chip as? NSTextField
        XCTAssertEqual(label?.stringValue, "quota spent")
    }

    func testBoardRenderDiffIncludesQuotaBlock() {
        let board = BoardView()
        let card = BoardCard(
            sessionID: "s-2", title: "Task", projectDir: "/tmp",
            agent: .claude, state: .idle)
        board.render(cards: [card], quotaBlocks: [card.id: .exhausted(reset: nil)])
        board.layoutSubtreeIfNeeded()
        let view = board.cellForTesting(.queue)?.arrangedSubviews
            .compactMap { $0 as? SessionCard }.first
        XCTAssertEqual(view?.quotaBlock, .exhausted(reset: nil))
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }
}

@MainActor
final class HarnessSwitchTests: XCTestCase {

    private final class TypedCapture {
        var text = ""
    }

    private func stubShell(work: URL, capture: TypedCapture) -> BoardShell {
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        shell.launchOverrideForTesting = { seed in
            let pty = try! PTYSession(command: ["/bin/cat"])
            try! pty.start()
            pty.onInput = { bytes in
                MainActor.assumeIsolated {
                    capture.text += String(decoding: bytes, as: UTF8.self)
                }
            }
            return Session(
                projectDir: seed.projectDir, agentType: .claude,
                pty: pty, state: .running)
        }
        return shell
    }

    func testSwitchAccountUpdatesProfileAndRelaunches() {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("switch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let personal = UUID()
        let capture = TypedCapture()
        let shell = stubShell(work: work, capture: capture)
        shell.setAgentAccountsForTesting([
            .defaultClaude,
            AgentAccountProfile(id: personal, name: "personal", agent: .claude, configRoot: "~/.claude-p")
        ])

        let card = shell.createSession(
            title: "Quota task", projectDir: work.path,
            autoStartAgent: .claude, claudeProfileID: personal)!
        XCTAssertEqual(shell.taskMetaForTesting(card.id)?.claudeProfileID, personal)

        shell.switchAccount(on: card, to: AgentAccountProfile.defaultClaudeID)

        let updated = shell.cards.first { $0.id == card.id }!
        XCTAssertEqual(updated.agent, .claude)
        XCTAssertEqual(shell.taskMetaForTesting(card.id)?.claudeProfileID, AgentAccountProfile.defaultClaudeID)
        XCTAssertNil(shell.taskMetaForTesting(card.id)?.sessionRef?.claudeSessionID)
        XCTAssertNotNil(shell.ptyForTesting(card.id))
    }

    func testSwitchHarnessChangesAgent() {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let capture = TypedCapture()
        let shell = stubShell(work: work, capture: capture)
        let card = shell.createSession(
            title: "Move to codex", projectDir: work.path,
            autoStartAgent: .claude)!

        shell.switchHarness(on: card, to: .codex)

        let updated = shell.cards.first { $0.id == card.id }!
        XCTAssertEqual(updated.agent, .codex)
        XCTAssertNotNil(shell.ptyForTesting(card.id))
    }

    func testRemoteCardHasSwitchMenu() {
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        let card = BoardCard(
            id: UUID(), sessionID: "remote/host/s-1", title: "Remote",
            projectDir: "user@host", agent: .claude, state: .idle, host: "host")
        shell.insertCardForTesting(card, remote: RemoteTmuxSpec(
            host: "host", user: "user", sessionName: "s-1", hostKind: .posix))
        shell.refreshForTesting()

        let menus = shell.switchMenusForTesting()
        guard let menu = menus[card.id] else {
            return XCTFail("remote card should have a switch menu")
        }
        XCTAssertFalse(menu.harnesses.isEmpty)
        XCTAssertTrue(menu.harnesses.contains(.codex))
    }

    /// A remote card attaches in tmux CONTROL MODE, so the far side is played by a
    /// stub that greets like a control server (opener, then the two bootstrap replies
    /// binding pane `%0`) and echoes everything else. The start command must reach the
    /// wire as a `send` for that pane — the proof it was delivered to the pane, not
    /// typed into the handshake.
    func testRemoteSwitchHarnessChangesAgent() {
        let capture = TypedCapture()
        let typed = expectation(description: "remote codex start sent to the pane")
        let codexHex = "0x63 0x6f 0x64 0x65 0x78"   // "codex"
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        shell.launchOverrideForTesting = { seed in
            let server = "printf '\\033P1000p'; printf '%%begin 1 1 1\\n%%end 1 1 1\\n';"
                + " printf '%%begin 1 2 1\\n%%0\\n%%end 1 2 1\\n'; exec /bin/cat"
            let pty = try! PTYSession(command: ["/bin/sh", "-c", server])
            try! pty.start()
            pty.onInput = { bytes in
                MainActor.assumeIsolated {
                    capture.text += String(decoding: bytes, as: UTF8.self)
                    if capture.text.contains("send -t %0 \(codexHex)") { typed.fulfill() }
                }
            }
            return Session(
                projectDir: seed.projectDir, agentType: .claude,
                pty: pty, state: .running)
        }
        let card = BoardCard(
            id: UUID(), sessionID: "remote/box/s-1", title: "Remote task",
            projectDir: "user@box", agent: .claude, state: .idle, host: "box")
        shell.insertCardForTesting(card, remote: RemoteTmuxSpec(
            host: "box", user: "user", sessionName: "s-1",
            remoteDir: "/srv/app", hostKind: .posix))
        shell.refreshForTesting()
        // The pane binds only once the greeting is READ: the board pump is the reader
        // for every card that is not drilled in, exactly as in the running app.
        shell.startSessionPump()
        defer { shell.stopSessionPump() }

        shell.switchHarness(on: card, to: .codex)

        let updated = shell.cards.first { $0.id == card.id }!
        XCTAssertEqual(updated.agent, .codex)
        XCTAssertNotNil(shell.ptyForTesting(card.id))
        wait(for: [typed], timeout: 5)
        XCTAssertTrue(capture.text.contains("send -t %0 \(codexHex)"))
        XCTAssertFalse(capture.text.contains("codex\n"), "never typed raw into the handshake")
    }
}
