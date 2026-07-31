import Testing
@testable import SichCore

// The pool firewall is the product's economic invariant: managed sessions run
// interactive `claude` (interactive pool); the tool must never auto-launch
// `claude -p` (headless API-credit pool). These tests pin that down without
// spawning anything.

@Suite("Pool firewall")
struct PoolFirewallTests {

    @Test("interactive claude is allowed on the interactive pool")
    func interactiveClaudeAllowed() throws {
        #expect(try PoolFirewall.classify(["claude"]) == .interactive)
        #expect(try PoolFirewall.classify(["claude", "--resume"]) == .interactive)
        #expect(try PoolFirewall.classify(["/opt/homebrew/bin/claude", "--model", "opus"]) == .interactive)
    }

    @Test("non-claude commands are allowed")
    func nonClaudeAllowed() throws {
        #expect(try PoolFirewall.classify(["/bin/echo", "hi"]) == .interactive)
        #expect(try PoolFirewall.classify(["bash", "-lc", "ls"]) == .interactive)
    }

    @Test("headless `claude -p` / --print is refused", arguments: [
        ["claude", "-p", "do a thing"],
        ["claude", "--print", "do a thing"],
        ["claude", "--print=do a thing"],
        ["/usr/local/bin/claude", "-p"],
    ])
    func headlessClaudeRefused(_ argv: [String]) {
        #expect(throws: PoolViolation.self) {
            try PoolFirewall.classify(argv)
        }
    }

    @Test("an empty command is refused")
    func emptyRefused() {
        #expect(throws: PoolViolation.emptyCommand) {
            try PoolFirewall.classify([])
        }
    }

    // MARK: - the ssh branch (US-001.AC-1, TC-UNIT-001)
    //
    // Until this landed, classify() gated the headless check behind
    // argv[0] == "claude" — and "ssh" is not "claude", so an ssh argv carrying
    // `claude -p` returned .interactive uninspected.

    @Test("an ssh argv carrying headless claude is refused", arguments: [
        ["/usr/bin/ssh", "host", "claude -p 'x'"],
        ["/usr/bin/ssh", "-t", "roman@host", "claude --print 'x'"],
        ["ssh", "-p", "2222", "host", "cd /srv && claude -p 'x'"],
        ["/usr/bin/ssh", "-o", "ServerAliveInterval=15", "host", "claude --print=x"]
    ])
    func sshCarryingHeadlessClaudeRefused(_ argv: [String]) {
        #expect(throws: PoolViolation.self) { try PoolFirewall.classify(argv) }
    }

    @Test("the ssh scan is tokenized: a name that merely contains `claude` passes", arguments: [
        ["/usr/bin/ssh", "-t", "host", "tmux new-session -A -s 'claude-work'"],
        ["/usr/bin/ssh", "-t", "host", "tmux new-session -A -s 'p' -c '/srv/claude-p'"]
    ])
    func sshTokenizedScanAllowsLookalikes(_ argv: [String]) throws {
        // A substring search for "claude" over the joined argv would refuse these.
        #expect(try PoolFirewall.classify(argv) == .interactive)
    }

    @Test("an ssh option that merely looks headless is not the remote command")
    func sshOptionsAreNotScanned() throws {
        // `-p 2222` is ssh's PORT flag sitting in the option position; only the
        // remote-command operand is in scope.
        #expect(try PoolFirewall.classify(["/usr/bin/ssh", "-p", "2222", "host", "tmux ls"])
            == .interactive)
    }

    @Test("the firewall sits on the PTYSession spawn path")
    func sessionRefusesHeadlessAtConstruction() {
        #expect(throws: PoolViolation.self) {
            _ = try PTYSession(command: ["claude", "-p", "headless"])
        }
        // …and the ssh branch is on the same chokepoint, so no *generated* remote
        // argv can reach a PTY without passing it (US-001.AC-1, TC-INT-018).
        #expect(throws: PoolViolation.self) {
            _ = try PTYSession(command: ["/usr/bin/ssh", "-t", "host", "claude -p 'x'"])
        }
    }
}
