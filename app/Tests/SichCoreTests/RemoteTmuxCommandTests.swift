import Foundation
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

    // MARK: - the destination chokepoint (US-001.AC-2..AC-6, DD-004)
    //
    // An ssh OPTION sitting in the destination position executes on the LOCAL
    // machine. `-oProxyCommand=…` has no "@" and no trailing ":<port>", so it
    // survives parse() whole and used to reach ssh unchecked.

    /// A payload shaped like an ssh option rather than a host.
    static let optionPayload = "-oProxyCommand=sh -c 'claude -p x'"

    @Test("an option-shaped destination is refused, direct and via parse()")
    func optionShapedDestinationRefused() throws {
        let payload = Self.optionPayload
        #expect(throws: RemoteTmuxCommand.Invalid.invalidDestination(payload)) {
            try RemoteTmuxCommand.argv(for: RemoteTmuxSpec(host: payload))
        }
        let parsed = try #require(RemoteTmuxSpec.parse(destination: payload))
        #expect(parsed.host == payload)  // parse() stays Optional and lets it through
        #expect(throws: RemoteTmuxCommand.Invalid.invalidDestination(payload)) {
            try RemoteTmuxCommand.argv(for: parsed)
        }
    }

    @Test("the guard is on the COMPOSED destination: the user position is refused too")
    func optionShapedUserRefused() throws {
        let composed = "\(Self.optionPayload)@build-box"
        let parsed = try #require(RemoteTmuxSpec.parse(destination: composed))
        #expect(parsed.user == Self.optionPayload)
        #expect(parsed.host == "build-box")
        #expect(throws: RemoteTmuxCommand.Invalid.invalidDestination(composed)) {
            try RemoteTmuxCommand.argv(for: parsed)
        }
    }

    @Test("validated POST-TRIM on the exact token appended, not on spec.target")
    func untrimmedHostIsStillRefused() {
        let spec = RemoteTmuxSpec(host: " \(Self.optionPayload)")
        // `target` composes the UNTRIMMED host, so a guard written against it sees a
        // leading SPACE rather than a dash — and waves the payload through, while the
        // token argv actually appends is the trimmed option. Hence: guard the token.
        #expect(spec.target.hasPrefix(" "))
        #expect(throws: RemoteTmuxCommand.Invalid.invalidDestination(Self.optionPayload)) {
            try RemoteTmuxCommand.argv(for: spec)
        }
    }

    @Test("bracketed IPv6 is accepted — Tailscale hands out IPv6 addresses")
    func bracketedIPv6Accepted() throws {
        #expect(try RemoteTmuxCommand.destination(for: RemoteTmuxSpec(host: "[::1]")) == "[::1]")
        #expect(try RemoteTmuxCommand.destination(
            for: RemoteTmuxSpec(host: "[fe80::1%en0]", user: "roman")) == "roman@[fe80::1%en0]")
        #expect(throws: RemoteTmuxCommand.Invalid.invalidDestination("[::1")) {
            try RemoteTmuxCommand.destination(for: RemoteTmuxSpec(host: "[::1"))
        }
    }

    @Test("the argvs this task will emit pass the firewall — asserted at their FINAL shape")
    func legitimateRemoteArgvsPassTheFirewall() throws {
        let card = "tmux new-session -A -s 'sich' "
            + "'tmux set-environment SICH_CARD_ID abc-123; SICH_CARD_ID=abc-123 exec $SHELL -il'"
        let relay = ["/usr/bin/ssh", "-o", "ServerAliveInterval=15",
                     "-o", "ServerAliveCountMax=3", "build-box",
                     "tail -n 200 -F ~/.sich/events.jsonl"]
        let install = ["/usr/bin/ssh", "build-box", "cat > ~/.claude/sich-forward.sh"]
        let probe = ["/usr/bin/ssh", "build-box", "cat ~/.claude/sich-forward.sh 2>/dev/null"]

        #expect(try PoolFirewall.classify(["/usr/bin/ssh", "-t", "build-box", card])
            == .interactive)
        #expect(try PoolFirewall.classify(relay) == .interactive)
        #expect(try PoolFirewall.classify(install) == .interactive)
        #expect(try PoolFirewall.classify(probe) == .interactive)
    }

    @Test("-p and -i each precede their value, so no caller data reaches the option position")
    func portAndIdentityAreConsumedByTheirFlags() throws {
        let argv = try RemoteTmuxCommand.argv(
            for: RemoteTmuxSpec(host: "h", port: 2222, identityFile: "/keys/id"))
        let port = try #require(argv.firstIndex(of: "2222"))
        let identity = try #require(argv.firstIndex(of: "/keys/id"))
        #expect(argv[port - 1] == "-p")
        #expect(argv[identity - 1] == "-i")
        #expect(argv[argv.count - 2] == "h")  // destination stays the last word before the command
    }

    @Test("the quoting boundary is remoteQuoted — NOT sanitizeSessionName")
    func quotingBoundaryIsRemoteQuoted() throws {
        // sanitizeSessionName folds only ". : space tab". It never touches a quote
        // or a ";", so it is not what makes a name safe on the far side.
        #expect(RemoteTmuxCommand.sanitizeSessionName("a';b") == "a';b")
        let argv = try RemoteTmuxCommand.argv(for: RemoteTmuxSpec(
            host: "h", sessionName: "a';b", remoteDir: "/srv;touch pwned"))
        #expect(argv.last == "tmux new-session -A -s 'a'\\'';b' -c '/srv;touch pwned'")
    }

    // MARK: - card identity on the pane (US-004 AC-1/AC-2, DD-002)

    static let cardID = "6E7B0C1A-0000-4000-8000-000000000001"

    @Test("a card id emits BOTH halves: the session env AND the launch shell's env")
    func cardIDBindsSessionAndLaunchShell() throws {
        let argv = try RemoteTmuxCommand.argv(
            for: RemoteTmuxSpec(host: "h"), cardID: Self.cardID)
        // set-environment binds LATER panes (Ctrl-b c); the launch command binds only
        // the first shell. Emitting one without the other is the AC-2 false-pass.
        #expect(argv.last == "tmux new-session -A -s 'sich' "
            + "'tmux set-environment SICH_CARD_ID \(Self.cardID); "
            + "SICH_CARD_ID=\(Self.cardID) exec $SHELL -il'")
        #expect(try PoolFirewall.classify(argv) == .interactive)
    }

    @Test("start dir and the card binding coexist — -c before the shell command")
    func cardIDWithStartDir() throws {
        let argv = try RemoteTmuxCommand.argv(
            for: RemoteTmuxSpec(host: "h", remoteDir: "/srv/app"), cardID: Self.cardID)
        let remote = try #require(argv.last)
        #expect(remote.hasPrefix("tmux new-session -A -s 'sich' -c '/srv/app' 'tmux set-environment"))
    }

    @Test("no card id → the plain attach shape, unchanged")
    func withoutCardIDShapeIsUnchanged() throws {
        let argv = try RemoteTmuxCommand.argv(for: RemoteTmuxSpec(host: "h"))
        #expect(argv.last == "tmux new-session -A -s 'sich'")
    }

    @Test("a card id that is not uuid-shaped is refused, never interpolated")
    func cardIDInjectionRefused() {
        // The id lands UNQUOTED inside the remote shell word (that is the contract's
        // byte shape), so the grammar — not a quoter — is what makes it safe.
        let payload = "x'; touch pwned; '"
        #expect(throws: RemoteTmuxCommand.Invalid.invalidCardID(payload)) {
            try RemoteTmuxCommand.argv(for: RemoteTmuxSpec(host: "h"), cardID: payload)
        }
        #expect(throws: RemoteTmuxCommand.Invalid.invalidCardID("$(id)")) {
            try RemoteTmuxCommand.argv(for: RemoteTmuxSpec(host: "h"), cardID: "$(id)")
        }
    }

    @Test("a blank session name derives a PER-CARD name, not the shared constant")
    func derivedSessionNameIsPerCard() {
        let first = UUID(uuidString: "6E7B0C1A-0000-4000-8000-000000000001")!
        let second = UUID(uuidString: "6E7B0C1A-0000-4000-8000-000000000002")!
        #expect(RemoteTmuxCommand.defaultSessionName(for: first) == "sich-6e7b0c1a-0001")
        #expect(RemoteTmuxCommand.defaultSessionName(for: first)
            != RemoteTmuxCommand.defaultSessionName(for: second))
        // and it survives the sanitizer unchanged — an unattachable default would be worse
        #expect(RemoteTmuxCommand.sanitizeSessionName(
            RemoteTmuxCommand.defaultSessionName(for: first))
            == RemoteTmuxCommand.defaultSessionName(for: first))
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
