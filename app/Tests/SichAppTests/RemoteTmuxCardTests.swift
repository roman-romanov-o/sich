import AppKit
import Testing
@testable import SichApp
import SichCore

/// Proves the remote-tmux card is actually reachable: `createRemoteTmuxSession`
/// (the method the ⌘⇧R menu action calls) builds a firewall-clean ssh card and
/// drops it on the board. Uses the reserved `.invalid` TLD so the spawned ssh fails
/// its lookup immediately instead of dialling a real host — the card is appended
/// synchronously, before ssh does anything, so the assertions don't race the process.
@MainActor
@Suite("Remote tmux card creation")
struct RemoteTmuxCardTests {

    @Test("createRemoteTmuxSession appends an ssh/tmux card on the board")
    func opensRemoteCard() throws {
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }

        let spec = try #require(RemoteTmuxSpec.parse(
            destination: "roman@host.invalid:2200", sessionName: "agent"))
        let card = try #require(shell.createRemoteTmuxSession(spec: spec))

        #expect(shell.cards.contains { $0.id == card.id })
        #expect(card.projectDir == "roman@host.invalid")   // ssh destination, shown as the label
        #expect(card.sessionID == "remote/host.invalid/agent")
        #expect(card.flow == .b)
    }

    @Test("the launched command is ssh attaching to tmux — never claude -p")
    func remoteCommandIsFirewallClean() throws {
        let spec = RemoteTmuxSpec(host: "host.invalid", sessionName: "agent")
        let seed = try BoardSeed.remoteTmux(spec: spec)
        #expect(seed.command.first == "/usr/bin/ssh")
        #expect(seed.command.contains("tmux new-session -A -s 'agent'"))
        #expect(try PoolFirewall.classify(seed.command) == .interactive)
    }
}
