import Testing
@testable import SichCore

@Suite("Remote tmux command builder")
struct RemoteTmuxCommandTests {

    @Test("minimal spec → ssh -t <host> attach-or-create")
    func minimalArgv() throws {
        let argv = try RemoteTmuxCommand.argv(for: RemoteTmuxSpec(host: "build-box"))
        #expect(argv == [
            "/usr/bin/ssh", "-t", "build-box",
            "tmux new-session -A -s 'sich'",
        ])
    }

    @Test("attach-or-create: uses -A so re-opening reconnects, never duplicates")
    func attachOrCreateFlag() throws {
        let argv = try RemoteTmuxCommand.argv(for: RemoteTmuxSpec(host: "h", sessionName: "work"))
        // -A is what makes tmux resume the SAME session across disconnects.
        #expect(argv.last == "tmux new-session -A -s 'work'")
    }

    @Test("user, port, identity and start dir all thread through")
    func fullSpec() throws {
        let spec = RemoteTmuxSpec(
            host: "10.0.0.5", user: "roman", sessionName: "agent",
            port: 2222, identityFile: "/keys/id_ed25519", remoteDir: "/srv/app"
        )
        let argv = try RemoteTmuxCommand.argv(for: spec)
        #expect(argv == [
            "/usr/bin/ssh", "-t", "-p", "2222", "-i", "/keys/id_ed25519",
            "roman@10.0.0.5",
            "tmux new-session -A -s 'agent' -c '/srv/app'",
        ])
    }

    @Test("tmux-illegal chars in the session name are folded to '-'")
    func sessionNameSanitised() throws {
        // '.' and ':' are tmux address separators — an unsanitised name is unattachable.
        #expect(RemoteTmuxCommand.sanitizeSessionName("my.proj:2 build") == "my-proj-2-build")
        let argv = try RemoteTmuxCommand.argv(for: RemoteTmuxSpec(host: "h", sessionName: "a.b:c"))
        #expect(argv.last == "tmux new-session -A -s 'a-b-c'")
    }

    @Test("firewall clean: the launched executable is ssh, not claude")
    func firewallClean() throws {
        // The pool firewall only ever forbids auto-launching `claude -p`; a remote
        // watcher must sail through it untouched.
        let argv = try RemoteTmuxCommand.argv(for: RemoteTmuxSpec(host: "h"))
        #expect(try PoolFirewall.classify(argv) == .interactive)
    }

    @Test("blank host / session are rejected up front")
    func rejectsBlank() {
        #expect(throws: RemoteTmuxCommand.Invalid.emptyHost) {
            try RemoteTmuxCommand.argv(for: RemoteTmuxSpec(host: "   "))
        }
        #expect(throws: RemoteTmuxCommand.Invalid.emptySessionName) {
            try RemoteTmuxCommand.argv(for: RemoteTmuxSpec(host: "h", sessionName: "..."))
        }
    }

    @Test("single quotes in a start dir are escaped so the remote shell can't break out")
    func remoteDirQuotingIsSafe() throws {
        let argv = try RemoteTmuxCommand.argv(
            for: RemoteTmuxSpec(host: "h", remoteDir: "/o'neil/app"))
        #expect(argv.last == "tmux new-session -A -s 'sich' -c '/o'\\''neil/app'")
    }

    // MARK: - destination parsing (the single dialog field → spec)

    @Test("parses [user@]host[:port] into user / host / port")
    func parseFullDestination() throws {
        let spec = try #require(RemoteTmuxSpec.parse(destination: "roman@10.0.0.5:2222"))
        #expect(spec.user == "roman")
        #expect(spec.host == "10.0.0.5")
        #expect(spec.port == 2222)
    }

    @Test("bare host parses with no user / no port")
    func parseBareHost() throws {
        let spec = try #require(RemoteTmuxSpec.parse(destination: "build-box"))
        #expect(spec.user == nil)
        #expect(spec.host == "build-box")
        #expect(spec.port == nil)
    }

    @Test("session + dir carry through the parse into a valid argv")
    func parseThreadsSessionAndDir() throws {
        let spec = try #require(RemoteTmuxSpec.parse(
            destination: "host", sessionName: "agent", remoteDir: "/srv"))
        let argv = try RemoteTmuxCommand.argv(for: spec)
        #expect(argv.last == "tmux new-session -A -s 'agent' -c '/srv'")
    }

    @Test("blank / userless destinations parse to nil")
    func parseRejectsHostless() {
        #expect(RemoteTmuxSpec.parse(destination: "   ") == nil)
        #expect(RemoteTmuxSpec.parse(destination: "roman@") == nil)
    }
}
