import Foundation
import Testing
@testable import SichCore

/// A Windows far side (native OpenSSH + psmux over ConPTY, typically password-auth).
/// The card is TERMINAL-ONLY: the interactive attach speaks psmux in tokens cmd.exe
/// and PowerShell both pass through unchanged, and every POSIX headless channel
/// (session probe, hook install, event relay) refuses to build an argv at all —
/// its callers fail soft instead of dialing a box that cannot serve them.
@Suite("Windows (psmux) remote cards")
struct RemoteWindowsPsmuxTests {

    private func windowsSpec(
        sessionName: String = "work", remoteDir: String? = nil
    ) -> RemoteTmuxSpec {
        RemoteTmuxSpec(host: "winbox", user: "roman", sessionName: sessionName,
                       remoteDir: remoteDir, hostKind: .windowsPsmux)
    }

    // MARK: - the attach argv

    @Test("windows spec → ssh -T <host> psmux -CC new-session -A, no POSIX anywhere")
    func windowsArgvShape() throws {
        // `-T`, not `-t`: control mode runs over pipes — a remote ConPTY would
        // eat the protocol's DCS opener and inject cursor noise into the parse.
        let argv = try RemoteTmuxCommand.argv(for: windowsSpec())
        #expect(argv == [
            "/usr/bin/ssh", "-T",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "roman@winbox",
            "psmux -CC new-session -A -s work",
        ])
    }

    @Test("the card binding rides psmux -e, replacing set-environment + exec $SHELL")
    func cardIDRidesDashE() throws {
        let cardID = "0EE0E692-9AF6-4A17-B926-2FA812DB33B3"
        let argv = try RemoteTmuxCommand.argv(for: windowsSpec(), cardID: cardID)
        #expect(argv.last == "psmux -CC new-session -A -s work -e SICH_CARD_ID=\(cardID)")
    }

    @Test("a start dir is double-quoted — the one grouping cmd and PowerShell agree on")
    func startDirIsDoubleQuoted() throws {
        let argv = try RemoteTmuxCommand.argv(
            for: windowsSpec(remoteDir: #"C:\Dev\my project"#))
        #expect(argv.last == #"psmux -CC new-session -A -s work -c "C:\Dev\my project""#)
    }

    @Test("the claude start rides psmux's `--` command — never local keystrokes")
    func claudeStartRidesThePsmuxCommand() throws {
        // Typed bytes would feed ssh's password prompt; psmux runs this far-side
        // instead, and `-A`'s attach branch ignores it, so a re-attach never
        // double-starts claude. `-NoExit` keeps a shell behind the agent.
        let conversation = "0ee0e692-9af6-4a17-b926-2fa812db33b3"
        let argv = try RemoteTmuxCommand.argv(
            for: windowsSpec(), agentCommand: "claude --session-id \(conversation)")
        #expect(argv.last == "psmux -CC new-session -A -s work"
                + " -- powershell -NoExit -Command claude --session-id \(conversation)")
    }

    @Test("a default session name survives windows validation untouched")
    func defaultNameIsWindowsSafe() throws {
        var spec = windowsSpec()
        spec.sessionName = RemoteTmuxCommand.defaultSessionName(for: UUID())
        let argv = try RemoteTmuxCommand.argv(for: spec)
        #expect(argv.last == "psmux -CC new-session -A -s \(spec.sessionName)")
    }

    // MARK: - validation, not quoting

    @Test("a session name a Windows shell would re-parse is refused, not quoted")
    func unsafeNameRefused() {
        // sanitizeSessionName folds "build & test" to "build-&-test" — the `&` is a
        // command join in cmd.exe, so the whole argv must refuse to exist.
        #expect(throws: RemoteTmuxCommand.Invalid.windowsUnsafeToken("build-&-test")) {
            try RemoteTmuxCommand.argv(for: windowsSpec(sessionName: "build & test"))
        }
    }

    @Test("a dir carrying %, $ or & is refused — cmd/PowerShell expand inside quotes")
    func unsafeDirRefused() {
        for dir in [#"C:\%USERPROFILE%\x"#, #"C:\a&b"#, #"C:\$env\x"#] {
            #expect(throws: RemoteTmuxCommand.Invalid.windowsUnsafeToken(dir)) {
                try RemoteTmuxCommand.argv(for: windowsSpec(remoteDir: dir))
            }
        }
    }

    // MARK: - the headless channels refuse; their callers fail soft

    @Test("every POSIX channel throws for a windows spec")
    func posixChannelsThrow() {
        let spec = windowsSpec()
        #expect(throws: RemoteTmuxCommand.Invalid.posixChannelOnWindowsHost) {
            try RemoteTmuxCommand.sessionProbeArgv(for: spec, session: "work")
        }
        #expect(throws: RemoteTmuxCommand.Invalid.posixChannelOnWindowsHost) {
            try RemoteTmuxCommand.relayArgv(for: spec)
        }
        #expect(throws: RemoteTmuxCommand.Invalid.posixChannelOnWindowsHost) {
            try RemoteTmuxCommand.installArgv(for: spec, file: .forwarder)
        }
        #expect(throws: RemoteTmuxCommand.Invalid.posixChannelOnWindowsHost) {
            try RemoteTmuxCommand.probeArgv(for: spec, file: .forwarder)
        }
    }

    @Test("the session probe reads a windows spec as .unknown — proceed, never block")
    func probeFailsSoftToUnknown() throws {
        let spec = windowsSpec()
        let key = try RemoteSessionKey.make(for: spec)
        let runner = MustNotRunRunner()
        let presence = RemoteSessionProbe.presence(
            of: key, cardID: UUID().uuidString, spec: spec, runner: runner)
        #expect(presence == .unknown)
        #expect(!runner.ran.value, "no ssh may even be attempted for a windows probe")
    }

    // MARK: - persistence

    @Test("hostKind survives a snapshot round-trip; a pre-windows snapshot is posix")
    func hostKindPersists() throws {
        let snapshot = RemoteSpecSnapshot(spec: windowsSpec(remoteDir: #"C:\Dev"#))
        let decoded = try JSONDecoder().decode(
            RemoteSpecSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.spec.hostKind == .windowsPsmux)

        // A snapshot written before hostKind existed decodes as a posix card.
        let legacy = #"{"host":"box","sessionName":"work"}"#
        let old = try JSONDecoder().decode(
            RemoteSpecSnapshot.self, from: Data(legacy.utf8))
        #expect(old.spec.hostKind == .posix)
    }
}

/// Flags if the probe ever reaches the transport — for a windows spec it must not.
private final class MustNotRunRunner: RemoteCommandRunner, @unchecked Sendable {
    let ran = LockedFlag()
    func run(argv: [String], input: Data?) -> RemoteCommandResult? {
        ran.set()
        return nil
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
