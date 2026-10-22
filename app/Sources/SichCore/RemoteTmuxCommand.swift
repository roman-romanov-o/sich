import Foundation

/// What shell and multiplexer the far side runs. Persisted with the spec, so a
/// restore rebuilds the same attach without re-asking.
public enum RemoteHostKind: String, Codable, Equatable, Sendable {
    /// A POSIX host: tmux, `sh` quoting, `$HOME` — every channel works.
    case posix
    /// A Windows host running native OpenSSH + psmux (a tmux clone on ConPTY).
    /// The remote command lands in cmd.exe or PowerShell, not `sh`, and such a box
    /// is typically password-auth only — so the card is TERMINAL-ONLY: the attach
    /// works (the operator types the password into the visible pane), while every
    /// headless channel (session probe, hook install, event relay) refuses to build
    /// an argv, and each caller already fails soft on that refusal.
    case windowsPsmux = "windows-psmux"
}

/// Where a remote tmux session lives and what to call it. A card built from this
/// spec SSHes into `host` and attaches to (or creates) tmux session `sessionName`
/// — the app *being* the terminal for a session that lives on another machine.
///
/// This stays firmly inside the watcher-not-spawner rule: we attach to an
/// interactive tmux where a human runs `claude` (or anything) themselves. We never
/// run `claude -p` — locally or remotely.
public struct RemoteTmuxSpec: Equatable, Sendable {
    /// Hostname or IP (or an ssh_config `Host` alias). Required.
    public var host: String
    /// Login user; `nil` uses ssh's default (ssh_config / current user).
    public var user: String?
    /// tmux session name to attach to or create. Required.
    public var sessionName: String
    /// ssh port; `nil` uses the default (22 / ssh_config).
    public var port: Int?
    /// Optional identity file (`-i`); `~` is expanded.
    public var identityFile: String?
    /// Directory the session starts in when tmux *creates* it (ignored on attach).
    public var remoteDir: String?
    /// What runs on the far side — decides which argv family the emitters build.
    public var hostKind: RemoteHostKind

    public init(
        host: String, user: String? = nil, sessionName: String = "sich",
        port: Int? = nil, identityFile: String? = nil, remoteDir: String? = nil,
        hostKind: RemoteHostKind = .posix
    ) {
        self.host = host
        self.user = user
        self.sessionName = sessionName
        self.port = port
        self.identityFile = identityFile
        self.remoteDir = remoteDir
        self.hostKind = hostKind
    }

    /// `user@host` (or bare `host`) — a compact card label.
    ///
    /// NOT the ssh destination: this interpolates the **untrimmed** host, so it
    /// diverges from the token an argv actually appends. Anything that reaches
    /// ssh must come from ``RemoteTmuxCommand/destination(for:)`` instead.
    public var target: String {
        guard let user, !user.isEmpty else { return host }
        return "\(user)@\(host)"
    }

    /// Parse a single human-typed destination `[user@]host[:port]` into a spec (with
    /// the session name and start dir supplied separately). Lets one dialog field
    /// accept the familiar SSH form instead of three sub-fields for user/host/port.
    /// Returns `nil` only when no host survives (blank or bare `user@`).
    public static func parse(
        destination: String, sessionName: String = "sich", remoteDir: String? = nil
    ) -> RemoteTmuxSpec? {
        var rest = destination.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        var user: String?
        if let at = rest.firstIndex(of: "@") {
            let u = String(rest[..<at])
            user = u.isEmpty ? nil : u
            rest = String(rest[rest.index(after: at)...])
        }
        var port: Int?
        if let colon = rest.lastIndex(of: ":"), let p = Int(rest[rest.index(after: colon)...]) {
            port = p
            rest = String(rest[..<colon])
        }
        let host = rest.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        let dir = remoteDir?.trimmingCharacters(in: .whitespaces)
        return RemoteTmuxSpec(
            host: host, user: user, sessionName: sessionName, port: port,
            remoteDir: (dir?.isEmpty ?? true) ? nil : dir
        )
    }
}

/// Builds the argv that opens a remote tmux session in a local PTY:
/// `ssh -t [opts] <target> tmux new-session -A -D -s <name> [-c <dir>]`.
///
/// `-A` makes tmux *attach if the session exists, else create it* — so re-opening
/// a card reconnects to the same running session instead of spawning duplicates,
/// which is the whole point of tmux on a remote box (survive disconnects, resume).
/// `-D` takes the session OVER on that attach; see ``remoteScript(session:dir:cardID:)``.
/// `-t` forces PTY allocation so the remote tmux is fully interactive.
///
/// Pure and total (no process launch) so the command shape is unit-testable.
public enum RemoteTmuxCommand {
    public enum Invalid: Error, Equatable, CustomStringConvertible {
        case emptyHost
        case emptySessionName
        /// The composed destination is not a host — carries the rejected token verbatim.
        case invalidDestination(String)
        /// The card id is not uuid-shaped, so it may not enter the remote shell word.
        case invalidCardID(String)
        /// A token cmd.exe or PowerShell would re-parse — safety on a Windows far
        /// side is validation, because there is no quoting both shells agree on.
        case windowsUnsafeToken(String)
        /// The probe/hook/relay channels are POSIX-only; a Windows (psmux) card is
        /// terminal-only. Every caller of these emitters fails soft on a throw.
        case posixChannelOnWindowsHost

        public var description: String {
            switch self {
            case .emptyHost: return "a remote host is required"
            case .emptySessionName: return "a tmux session name is required"
            case .invalidDestination(let token):
                return "Destination \"\(token)\" looks like an ssh option, not a host. "
                    + "Remove the leading dash."
            case .invalidCardID(let token):
                return "Card id \"\(token)\" is not a UUID."
            case .windowsUnsafeToken(let token):
                return "\"\(token)\" has characters a Windows shell would re-parse. "
                    + "Use letters, digits and dashes (a folder may add \\ / : . space)."
            case .posixChannelOnWindowsHost:
                return "hook and relay channels need a POSIX far side; "
                    + "a Windows (psmux) card is terminal-only"
            }
        }
    }

    // MARK: - the destination chokepoint (DD-004)

    /// The one place an ssh destination token is produced. Every emitter takes its
    /// destination from here; none interpolates `host`, `user` or ``RemoteTmuxSpec/target``
    /// into an argv itself.
    ///
    /// This is the *structural* half of DD-004: a destination that is really an ssh
    /// **option** lands in ssh's option position, and options execute on the **local**
    /// machine — `-oProxyCommand=sh -c '…'` has no `@` and no trailing `:<port>`, so it
    /// survives ``RemoteTmuxSpec/parse(destination:sessionName:remoteDir:)`` whole.
    ///
    /// Validated **post-trim, on the exact string appended** — never on `spec.target`,
    /// which composes the untrimmed host and so passes a payload that begins with a space.
    public static func destination(for spec: RemoteTmuxSpec) throws -> String {
        let host = spec.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw Invalid.emptyHost }
        let user = spec.user?.trimmingCharacters(in: .whitespaces) ?? ""
        let token = user.isEmpty ? host : "\(user)@\(host)"
        guard isWellFormedHost(host), user.isEmpty || isWellFormedLogin(user) else {
            throw Invalid.invalidDestination(token)
        }
        return token
    }

    private static let loginChars = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    /// Hex digits plus the separators an IPv6 literal may carry: `:` and an
    /// embedded IPv4 tail. A `%`-scoped zone id is checked separately.
    private static let ipv6Chars = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")

    private static func isWellFormedLogin(_ login: String) -> Bool {
        !login.hasPrefix("-") && login.unicodeScalars.allSatisfy(loginChars.contains)
    }

    /// A hostname, an IPv4 literal, an ssh_config `Host` alias — or a **bracketed**
    /// IPv6 literal, which must be accepted: Tailscale hands out IPv6, so a
    /// `[A-Za-z0-9.-]` grammar would refuse real hosts.
    private static func isWellFormedHost(_ host: String) -> Bool {
        guard host.hasPrefix("[") else { return isWellFormedLogin(host) }
        guard host.hasSuffix("]"), host.count > 2 else { return false }
        // `fe80::1%en0` — the address, then an optional interface zone id.
        let parts = host.dropFirst().dropLast().split(separator: "%", maxSplits: 1)
        guard let address = parts.first, !address.isEmpty else { return false }
        guard address.unicodeScalars.allSatisfy(ipv6Chars.contains) else { return false }
        return parts.count == 1 || isWellFormedLogin(String(parts[1]))
    }

    /// tmux rejects `.` and `:` in session names (they're address separators); fold
    /// them plus whitespace to `-` so a human-typed name like "my project" or a
    /// "host:2222" paste can't produce an unattachable session.
    public static func sanitizeSessionName(_ raw: String) -> String {
        let mapped = raw.map { ".: \t".contains($0) ? "-" : $0 }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The full local argv. Throws ``Invalid`` when the host or session name is blank,
    /// when the destination is option-shaped, or when `cardID` is not uuid-shaped.
    ///
    /// `cardID` binds the pane to a board card (US-004, DD-002). It is optional so a
    /// bare attach — an argv that only needs to reach a session — keeps its old shape.
    /// `tmuxEnvironment` seeds per-account env vars (`CLAUDE_CONFIG_DIR`, …) on the
    /// far-side session before the login shell starts.
    public static func argv(
        for spec: RemoteTmuxSpec, cardID: String? = nil,
        tmuxEnvironment: [(String, String)] = [],
        agentCommand: String? = nil
    ) throws -> [String] {
        let destination = try destination(for: spec)
        let session = sanitizeSessionName(spec.sessionName)
        guard !session.isEmpty else { throw Invalid.emptySessionName }
        if let cardID, !isWellFormedCardID(cardID) { throw Invalid.invalidCardID(cardID) }

        // Both far sides attach in CONTROL MODE (`-CC`): the server hands the pane's
        // output over as data and the local emulator owns the scrollback. The
        // `agentCommand` (a claude start or resume) rides the session's own launch
        // command on both, executed far-side on the CREATE branch of `-A` only — a
        // re-attach never double-starts anything, and nothing is ever typed into the
        // handshake, where keystrokes would feed ssh's password prompt or the
        // control client's command reader instead of a shell.
        //
        // A Windows far side gets the psmux family. `tmuxEnvironment` is deliberately
        // dropped there: those are per-account vars carrying POSIX config paths
        // (`$HOME/...`), meaningless on a Windows box.
        //
        // `-T` (no remote PTY) on Windows, not `-t`: psmux's control mode is a line
        // protocol over pipes, and under `-t` ConPTY consumes the protocol's DCS
        // opener and injects cursor sequences into the stream, corrupting the parse.
        // tmux is the opposite: its control client refuses to start WITHOUT a tty
        // (`tcgetattr failed`), so the POSIX attach keeps `-t`.
        if spec.hostKind == .windowsPsmux {
            return ["/usr/bin/ssh", "-T"] + attachOptions + options(for: spec)
                + [destination, try windowsScript(
                    session: session, dir: spec.remoteDir, cardID: cardID,
                    agentCommand: agentCommand)]
        }
        return ["/usr/bin/ssh", "-t"] + attachOptions + options(for: spec)
            + [destination, remoteScript(
                session: session, dir: spec.remoteDir, cardID: cardID,
                tmuxEnvironment: tmuxEnvironment, agentCommand: agentCommand)]
    }

    /// The far-side command that starts a NEW interactive Claude conversation pinned
    /// to `sessionID`, so the id is known up front and resumable later. Plain
    /// `claude`, bare PATH lookup: the far side has no shim (its hooks arrive through
    /// the forwarded event log). Never `claude -p`.
    public static func claudeStart(sessionID: UUID) -> String {
        "claude --session-id \(sessionID.uuidString.lowercased())"
    }

    /// The far-side command that RESUMES conversation `sessionID`. No `|| claude`
    /// fallback here: the pane command keeps a shell behind the agent on both host
    /// kinds, so a vanished transcript lands the operator at a prompt, not a dead pane.
    public static func claudeResume(sessionID: UUID) -> String {
        "claude --resume \(sessionID.uuidString.lowercased())"
    }

    /// The remote command for a Windows far side. Windows OpenSSH hands this string
    /// to the account's DefaultShell — cmd.exe or PowerShell, NOT `sh` — so nothing
    /// POSIX survives here: no single quotes, no `$HOME`, no `exec $SHELL`. The
    /// command is plain space-separated tokens both shells pass through unchanged,
    /// and safety comes from VALIDATION rather than quoting, because cmd and
    /// PowerShell disagree on every quoting rule (`%` expands inside cmd quotes,
    /// `$` and backticks inside PowerShell double quotes).
    ///
    /// psmux — a native-Windows tmux clone on ConPTY — covers everything this argv
    /// needs: `-A` attach-or-create, `-c` start dir, and repeatable `-e KEY=VALUE`
    /// session env, which replaces the whole POSIX `set-environment` +
    /// `exec $SHELL -il` dance in one flag (on the attach branch of `-A` it is
    /// ignored, exactly like tmux). tmux's `-D` takeover flag is not emitted: psmux
    /// is single-client, so there is no stale co-client to detach.
    ///
    /// `-CC` attaches in CONTROL MODE: instead of repainting a full-screen UI,
    /// psmux streams the pane as `%output` data that ``TmuxControlChannel``
    /// decodes into the local emulator's normal buffer — which is what makes the
    /// wheel scroll local scrollback on a Windows card instead of rewinding
    /// claude's input history. Session persistence across drops is unchanged:
    /// the panes live in the far-side server either way.
    static func windowsScript(
        session: String, dir: String?, cardID: String?, agentCommand: String? = nil
    ) throws -> String {
        guard isWindowsSafe(session, allowing: windowsNameChars) else {
            throw Invalid.windowsUnsafeToken(session)
        }
        var words = ["psmux", "-CC", "new-session", "-A", "-s", session]
        if let cardID { words += ["-e", "\(cardIDVariable)=\(cardID)"] }
        let dir = dir?.trimmingCharacters(in: .whitespaces) ?? ""
        if !dir.isEmpty {
            guard isWindowsSafe(dir, allowing: windowsPathChars) else {
                throw Invalid.windowsUnsafeToken(dir)
            }
            // Double quotes are the ONE quoting both shells treat as grouping; the
            // charset above keeps everything inside them inert in both.
            words += ["-c", "\"\(dir)\""]
        }
        // psmux runs everything after `--` instead of a shell (ignored on the attach
        // branch of `-A`, so a re-attach never double-starts claude). The PowerShell
        // `-NoExit` wrapper keeps a shell behind claude — exiting the agent lands the
        // operator in a prompt, matching the POSIX cards where claude runs IN a shell.
        if let agentCommand {
            guard isWindowsSafe(agentCommand, allowing: windowsCommandChars) else {
                throw Invalid.windowsUnsafeToken(agentCommand)
            }
            words += ["--", "powershell", "-NoExit", "-Command", agentCommand]
        }
        return words.joined(separator: " ")
    }

    /// Letters/digits/dash/underscore — inert in cmd.exe AND PowerShell, and a
    /// superset of what ``defaultSessionName(for:)`` produces.
    private static let windowsNameChars = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    /// An agent command line: name-safe words separated by spaces — what
    /// ``claudeStart(sessionID:)`` and ``claudeResume(sessionID:)`` produce.
    private static let windowsCommandChars = windowsNameChars.union(CharacterSet(charactersIn: " "))
    /// A Windows path inside double quotes. Excluded on purpose: `%` and `!` (cmd
    /// expands both even inside quotes), `$` and `` ` `` (PowerShell expands both
    /// inside double quotes), and every redirect/join metacharacter.
    private static let windowsPathChars = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _.:\\/()~-")

    private static func isWindowsSafe(_ token: String, allowing chars: CharacterSet) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy(chars.contains)
    }

    /// What the INTERACTIVE attach adds on top of the relay's keepalive: a bounded dial.
    ///
    /// Without the keepalive a half-open link (laptop lid, Wi-Fi drop, the far side
    /// wedged under load) leaves ssh blocked in TCP retransmit for ~15 minutes — the
    /// operator stares at a frozen pane that is neither alive nor dead, and the board
    /// keeps the card as if it were still attached, because the child never exits.
    /// With it the link is declared dead in ~45s, the card demotes to idle, and the
    /// next drill-in re-attaches. `ConnectTimeout` does the same for the opening dial
    /// so a drill-in on a host that is off does not hang the card either.
    private static let attachOptions = keepAliveOptions + ["-o", "ConnectTimeout=10"]

    /// The env var a far-side pane exports, and the forwarder splices into every hook
    /// payload as `sich_card_id`.
    public static let cardIDVariable = "SICH_CARD_ID"

    /// The tmux session name an unnamed card gets: derived from the card's own id, so
    /// two unnamed cards are two sessions. A single shared default made `-A` attach
    /// every unnamed card to ONE remote shell.
    ///
    /// Hex and `-` only, so ``sanitizeSessionName(_:)`` is a no-op on it.
    public static func defaultSessionName(for cardID: UUID) -> String {
        let parts = cardID.uuidString.lowercased().split(separator: "-")
        let head = parts.first.map(String.init) ?? "0"
        let tail = String((parts.last ?? "0").suffix(4))
        return "sich-\(head)-\(tail)"
    }

    /// Ask the far side what — if anything — holds a session name (US-004 AC-4).
    ///
    /// `has-session` prints the marker when the name is FREE; `show-environment` then
    /// reports the binding a Sich-created session carries. `exit 0` throughout, so a
    /// nonzero status means the transport failed, not that the session is missing —
    /// the difference between `absent` and `unknown`.
    public static func sessionProbeArgv(for spec: RemoteTmuxSpec, session: String) throws -> [String] {
        // A Windows box cannot serve this: the command is POSIX and BatchMode over
        // password auth fails anyway. The probe's `try?` maps this to `.unknown`,
        // which is "proceed" — silence must not make remote cards unopenable.
        guard spec.hostKind == .posix else { throw Invalid.posixChannelOnWindowsHost }
        let target = remoteQuoted("=" + session)
        let command = "tmux has-session -t \(target) 2>/dev/null || echo \(noSessionMarker); "
            + "tmux show-environment -t \(target) \(cardIDVariable) 2>/dev/null; exit 0"
        return ["/usr/bin/ssh"] + probeOptions + options(for: spec)
            + [try destination(for: spec), command]
    }

    /// A probe must never turn into an interactive login: `BatchMode` makes a password
    /// or passphrase prompt fail immediately (which reads as `unknown` — proceed) and
    /// `ConnectTimeout` bounds an unreachable host, so the ⌘⇧R sheet cannot hang.
    private static let probeOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]

    /// Printed by the probe when the session name is unused on the far side.
    static let noSessionMarker = "__sich_no_session__"

    private static let cardIDChars = CharacterSet(charactersIn:
        "0123456789abcdefABCDEF-")

    /// The card id lands **unquoted** inside the remote shell word (that is the shape
    /// the contract fixes), so the grammar is what keeps it inert: uuid characters
    /// only, nothing a shell would expand.
    private static func isWellFormedCardID(_ cardID: String) -> Bool {
        UUID(uuidString: cardID) != nil
            && cardID.unicodeScalars.allSatisfy(cardIDChars.contains)
    }

    /// Push one file to the remote `$HOME`, bytes on **stdin** (US-005 AC-1).
    ///
    /// Two properties this shape exists for, both of which a plausible copy of
    /// ``argv(for:)`` would break:
    ///  * **no `-t`** — a PTY rewrites LF to CRLF, so the bytes that land differ
    ///    from the bytes we hashed and the host reads `staleVersion` forever;
    ///  * **nothing interpolated** — the payload never becomes a remote shell
    ///    word. The forwarder contains `$HOME`, `$SICH_CARD_ID`, `$file` and
    ///    `$@`; a heredoc or an echo would expand every one of them on the far
    ///    side. `cat` copies bytes it never parses.
    ///
    /// `$HOME` is expanded by the far-side shell, so the same command works on a
    /// host whose home directory we do not know.
    public static func installArgv(
        for spec: RemoteTmuxSpec, file: RemoteHookFile
    ) throws -> [String] {
        try installArgv(for: spec, relativePath: file.rawValue, mode: file.mode)
    }

    /// Push one `$HOME`-relative file to the remote host, bytes on **stdin**.
    public static func installArgv(
        for spec: RemoteTmuxSpec, relativePath: String, mode: String
    ) throws -> [String] {
        guard isSafeHomeRelative(relativePath) else {
            throw Invalid.invalidDestination(relativePath)
        }
        let path = remoteHome(relativePath)
        let command = "mkdir -p \(remoteHome(directory(of: relativePath)))"
            + " && cat > \(path).new"
            + " && chmod \(mode) \(path).new"
            + " && mv \(path).new \(path)"
        return try channelArgv(for: spec, command: command)
    }

    public static func probeArgv(
        for spec: RemoteTmuxSpec, file: RemoteHookFile
    ) throws -> [String] {
        try probeArgv(for: spec, relativePath: file.rawValue)
    }

    public static func probeArgv(
        for spec: RemoteTmuxSpec, relativePath: String
    ) throws -> [String] {
        guard isSafeHomeRelative(relativePath) else {
            throw Invalid.invalidDestination(relativePath)
        }
        return try channelArgv(
            for: spec, command: "cat \(remoteHome(relativePath)) 2>/dev/null; exit 0")
    }

    private static func isSafeHomeRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("..")
            && path.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "-_./".unicodeScalars.contains($0)
            }
    }

    /// Follow the remote event log and stream it to the laptop (US-003 AC-5).
    ///
    /// Every token is fixed except the ones the constrained spec supplies, and the
    /// destination comes from the chokepoint — nothing here is composed from free
    /// text. The three parts that are load-bearing:
    ///  * `-o ServerAliveInterval=15 -o ServerAliveCountMax=3` — a wedged link dies
    ///    in ~45s with ssh's own status 255 instead of hanging silently forever;
    ///  * `-F` (`--follow=name --retry`) — the forwarder rotates the log with
    ///    `mv -f` at 5 MiB, and follow-by-name survives that; it also waits out a
    ///    log that does not exist yet instead of exiting;
    ///  * `-n \(relayReplayLines)` — a reconnect replays a BOUNDED tail, so older
    ///    history is never re-ingested (the content dedup drops the overlap).
    ///
    /// No `-t`: a PTY would rewrite LF to CRLF and corrupt every JSON line.
    public static func relayArgv(for spec: RemoteTmuxSpec) throws -> [String] {
        // No `tail`, no `$HOME`, no headless auth on a Windows box: the relay is
        // simply not started for one (`attachRemoteHost` skips on this throw).
        guard spec.hostKind == .posix else { throw Invalid.posixChannelOnWindowsHost }
        return ["/usr/bin/ssh"] + keepAliveOptions + options(for: spec)
            + [try destination(for: spec), relayCommand]
    }

    /// The host a relayed line is stamped with (US-003 AC-2): the bare host, so two
    /// cards that log in as different users on one machine stamp the same host.
    /// Validated through ``destination(for:)`` so it cannot be an ssh option.
    public static func hostToken(for spec: RemoteTmuxSpec) throws -> String {
        _ = try destination(for: spec)
        return spec.host.trimmingCharacters(in: .whitespaces)
    }

    /// Lines of history replayed on every (re)connect.
    static let relayReplayLines = 200

    /// The remote event log, `$HOME`-relative — the same file the forwarder appends
    /// to. A fixed literal, never a caller-supplied path.
    static let remoteEventLog = ".sich/events.jsonl"

    static var relayCommand: String {
        "tail -n \(relayReplayLines) -F \(remoteHome(remoteEventLog))"
    }

    /// ~45s worst case before a wedged link is declared dead (DD-001).
    private static let keepAliveOptions = [
        "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"
    ]

    /// The shared shape of the byte-exact channels: ssh, its options, the
    /// destination from the chokepoint, one remote command. No `-t`.
    private static func channelArgv(
        for spec: RemoteTmuxSpec, command: String
    ) throws -> [String] {
        // Gates hook install AND hook probe: both commands are POSIX (`$HOME`,
        // `cat`, `chmod`) and both callers fail soft (`.failed` → chip `unknown`).
        guard spec.hostKind == .posix else { throw Invalid.posixChannelOnWindowsHost }
        return ["/usr/bin/ssh"] + options(for: spec) + [try destination(for: spec), command]
    }

    /// A `$HOME`-relative path as a single remote shell word. The variable stays
    /// outside the quotes so the far-side shell expands it; the literal tail is
    /// quoted so nothing in it is re-parsed.
    private static func remoteHome(_ relative: String) -> String {
        "\"$HOME\"/\(remoteQuoted(relative))"
    }

    private static func directory(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// Port and identity are safe by **emission order**, not by any property of the
    /// fields: each value is positionally consumed by the flag emitted immediately
    /// before it. A refactor that emits one without its flag puts caller data back
    /// into ssh's option position.
    static func options(for spec: RemoteTmuxSpec) -> [String] {
        var options: [String] = []
        if let port = spec.port { options += ["-p", String(port)] }
        if let id = spec.identityFile, !id.trimmingCharacters(in: .whitespaces).isEmpty {
            options += ["-i", (id as NSString).expandingTildeInPath]
        }
        return options
    }

    /// The single remote command string ssh hands to the login shell on the far side.
    /// Session name and dir are shell-quoted because that shell re-parses this string.
    ///
    /// `-D` detaches whatever client is already on that session, so a re-attach after a
    /// flaky link TAKES IT OVER instead of joining it. Two clients on one session is not
    /// a cosmetic problem: tmux sizes the window to the SMALLEST attached client, so a
    /// half-dead client that ssh has not reaped yet shrinks the pane the operator is
    /// looking at, and every keystroke is echoed to a corpse. `-D` is read only on the
    /// attach branch of `-A`; on the create branch tmux ignores it (it is `-d` that
    /// would create the session detached, and that flag is deliberately not here).
    ///
    /// With a `cardID`, tmux is given a command to run in the new session, and that
    /// command has **two halves, both required** (DD-002):
    ///  * `tmux set-environment` writes the SESSION environment, which is what every
    ///    pane tmux spawns later (`Ctrl-b c`) inherits;
    ///  * `SICH_CARD_ID=… exec $SHELL -il` binds *this* shell, which the session env
    ///    alone would not reach — set-environment does not touch a running process.
    ///
    /// `new-session -e` would do both in one flag but needs tmux ≥ 3.2 (Ubuntu 20.04
    /// ships 3.0a, where it is a usage error and the session never starts).
    ///
    /// `-CC` is CONTROL MODE: tmux draws no UI and streams the pane as data, which
    /// is what gives a remote card local scrollback (see ``TmuxControlChannel``).
    ///
    /// An `agentCommand` runs INSIDE that login shell (`-c`, so the rc files still
    /// shape PATH and prompt), with a plain login shell exec'd behind it: exiting
    /// the agent lands the operator at a prompt in the same pane, never a dead one.
    static func remoteScript(
        session: String, dir: String?, cardID: String? = nil,
        tmuxEnvironment: [(String, String)] = [], agentCommand: String? = nil
    ) -> String {
        var tmux = "tmux -CC new-session -A -D -s \(remoteQuoted(session))"
        let dir = dir?.trimmingCharacters(in: .whitespaces) ?? ""
        if !dir.isEmpty {
            tmux += " -c \(remotePath(dir))"
        }
        var shell = "exec $SHELL -il"
        if let agentCommand {
            shell += " -c " + remoteQuoted(agentCommand + "; exec $SHELL -il")
        }
        var inner = tmuxEnvironment.map { name, value in
            "tmux set-environment \(remoteQuoted(name)) \(remoteQuoted(value))"
        }.joined(separator: "; ")
        if let cardID {
            let bind = inner.isEmpty ? "" : inner + "; "
            inner = bind + "tmux set-environment \(cardIDVariable) \(cardID); "
                + "\(cardIDVariable)=\(cardID) " + shell
            return tmux + " " + remoteQuoted(inner)
        }
        if inner.isEmpty {
            guard agentCommand != nil else { return tmux }
            return tmux + " " + remoteQuoted(shell)
        }
        return tmux + " " + remoteQuoted(inner + "; " + shell)
    }

    /// A far-side path as ONE shell word, with a leading `~` handed to the remote shell
    /// to expand — the tilde stays OUTSIDE the quotes, exactly like `$HOME` in
    /// ``remoteHome(_:)``, and the rest of the path stays inside them.
    ///
    /// This exists because tmux does not expand `~` itself and does not complain when
    /// `-c` names a directory it cannot enter: it silently starts the session in the
    /// user's home. The remote folder picker hands out `~/…` paths, so a fully quoted
    /// `-c '~/MyProjects/spectre'` lost the start directory on every session tmux had
    /// to CREATE — the "my card came back at the home prompt" bug — with no error
    /// anywhere to say so.
    ///
    /// `~otheruser/…` is left quoted: `$HOME` cannot express it, and expanding it would
    /// mean emitting the path unquoted, where a space or a glob in it would re-parse.
    static func remotePath(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        guard path.hasPrefix("~/") else { return remoteQuoted(path) }
        return "\"$HOME\"/" + remoteQuoted(String(path.dropFirst(2)))
    }

    private static func remoteQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
