import Foundation

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

    public init(
        host: String, user: String? = nil, sessionName: String = "ghostling",
        port: Int? = nil, identityFile: String? = nil, remoteDir: String? = nil
    ) {
        self.host = host
        self.user = user
        self.sessionName = sessionName
        self.port = port
        self.identityFile = identityFile
        self.remoteDir = remoteDir
    }

    /// `user@host` (or bare `host`) — the ssh destination and a compact card label.
    public var target: String {
        guard let user, !user.isEmpty else { return host }
        return "\(user)@\(host)"
    }

    /// Parse a single human-typed destination `[user@]host[:port]` into a spec (with
    /// the session name and start dir supplied separately). Lets one dialog field
    /// accept the familiar SSH form instead of three sub-fields for user/host/port.
    /// Returns `nil` only when no host survives (blank or bare `user@`).
    public static func parse(
        destination: String, sessionName: String = "ghostling", remoteDir: String? = nil
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
/// `ssh -t [opts] <target> tmux new-session -A -s <name> [-c <dir>]`.
///
/// `-A` makes tmux *attach if the session exists, else create it* — so re-opening
/// a card reconnects to the same running session instead of spawning duplicates,
/// which is the whole point of tmux on a remote box (survive disconnects, resume).
/// `-t` forces PTY allocation so the remote tmux is fully interactive.
///
/// Pure and total (no process launch) so the command shape is unit-testable.
public enum RemoteTmuxCommand {
    public enum Invalid: Error, Equatable, CustomStringConvertible {
        case emptyHost
        case emptySessionName

        public var description: String {
            switch self {
            case .emptyHost: return "a remote host is required"
            case .emptySessionName: return "a tmux session name is required"
            }
        }
    }

    /// tmux rejects `.` and `:` in session names (they're address separators); fold
    /// them plus whitespace to `-` so a human-typed name like "my project" or a
    /// "host:2222" paste can't produce an unattachable session.
    public static func sanitizeSessionName(_ raw: String) -> String {
        let mapped = raw.map { ".: \t".contains($0) ? "-" : $0 }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The full local argv. Throws ``Invalid`` when host or session name is blank.
    public static func argv(for spec: RemoteTmuxSpec) throws -> [String] {
        let host = spec.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw Invalid.emptyHost }
        let session = sanitizeSessionName(spec.sessionName)
        guard !session.isEmpty else { throw Invalid.emptySessionName }

        var argv = ["/usr/bin/ssh", "-t"]
        if let port = spec.port { argv += ["-p", String(port)] }
        if let id = spec.identityFile, !id.trimmingCharacters(in: .whitespaces).isEmpty {
            argv += ["-i", (id as NSString).expandingTildeInPath]
        }
        var target = spec.target
        if let user = spec.user, !user.isEmpty { target = "\(user)@\(host)" } else { target = host }
        argv.append(target)
        argv.append(remoteScript(session: session, dir: spec.remoteDir))
        return argv
    }

    /// The single remote command string ssh hands to the login shell on the far side.
    /// Session name and dir are shell-quoted because that shell re-parses this string.
    static func remoteScript(session: String, dir: String?) -> String {
        var tmux = "tmux new-session -A -s \(remoteQuoted(session))"
        if let dir, !dir.trimmingCharacters(in: .whitespaces).isEmpty {
            tmux += " -c \(remoteQuoted(dir))"
        }
        return tmux
    }

    private static func remoteQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
