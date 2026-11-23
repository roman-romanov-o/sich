import Testing

@testable import SichCore

/// Agent detection walks the same directories the Sich shims do, so "installed"
/// means "a card can start it".
@Suite("Agent inventory")
struct AgentInventoryTests {
    let home = "/Users/new"
    let shims = "/Users/new/.sich/bin"

    @Test("PATH order wins, and Sich's own shim dir is never mistaken for the agent")
    func pathOrderSkipsShims() {
        let exists: Set = ["/Users/new/.sich/bin/claude", "/opt/x/claude", "/usr/local/bin/claude"]
        let found = AgentInventory.locate(
            .claude, searchPath: [shims, "/opt/x"], home: home, excludedDirs: [shims],
            isExecutable: exists.contains)
        #expect(found == "/opt/x/claude")
    }

    @Test("an agent the installer just put in ~/.local/bin is found off a bare PATH")
    func installDirFallback() {
        let found = AgentInventory.locate(
            .claude, searchPath: ["/usr/bin", "/bin"], home: home, excludedDirs: [shims],
            isExecutable: { $0 == "/Users/new/.local/bin/claude" })
        #expect(found == "/Users/new/.local/bin/claude")
    }

    @Test("a fresh Mac has nothing; each agent resolves by its own binary name")
    func scanByBinaryName() {
        #expect(AgentInventory.scan(searchPath: ["/usr/bin"], home: home, excludedDirs: [shims],
                                    isExecutable: { _ in false }).isEmpty)
        let found = AgentInventory.scan(
            searchPath: ["/usr/bin"], home: home, excludedDirs: [shims],
            isExecutable: { ["/Users/new/.local/bin/agent", "/Users/new/.local/bin/agy"].contains($0) })
        #expect(found == [.cursor: "/Users/new/.local/bin/agent", .antigravity: "/Users/new/.local/bin/agy"])
    }

    @Test("the login-shell PATH is read past whatever the rc files print")
    func parsesMarkedPath() {
        let out = "Welcome!\n\(AgentInventory.pathMarker)/a/bin:/b/bin\n"
        #expect(AgentInventory.parsePath(fromShellOutput: out) == ["/a/bin", "/b/bin"])
        #expect(AgentInventory.parsePath(fromShellOutput: "no marker here") == nil)
    }

    @Test("installer colour codes are stripped for the setup sheet")
    func stripsEscapes() {
        #expect(AgentInventory.strippingEscapes("\u{1B}[1;32m✔ Installed\u{1B}[0m") == "✔ Installed")
    }
}
