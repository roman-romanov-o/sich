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

    @Test("the firewall sits on the PTYSession spawn path")
    func sessionRefusesHeadlessAtConstruction() {
        #expect(throws: PoolViolation.self) {
            _ = try PTYSession(command: ["claude", "-p", "headless"])
        }
    }
}
