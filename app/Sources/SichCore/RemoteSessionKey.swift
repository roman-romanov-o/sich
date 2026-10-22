import Foundation

/// What identifies a remote tmux session: the host it lives on and the name tmux
/// actually uses for it (US-004 AC-4).
///
/// The name is the **sanitized** one, because that is what `-A` matches on: "my.proj"
/// and "my proj" are two typed strings but one tmux session, and two cards holding it
/// would drive the same remote shell.
public struct RemoteSessionKey: Hashable, Sendable {
    public let host: String
    public let session: String

    public init(host: String, session: String) {
        self.host = host
        self.session = session
    }

    /// The key for a spec, with the host validated through the ssh chokepoint and the
    /// name folded exactly as the argv folds it.
    public static func make(for spec: RemoteTmuxSpec) throws -> RemoteSessionKey {
        let host = try RemoteTmuxCommand.hostToken(for: spec)
        let session = RemoteTmuxCommand.sanitizeSessionName(spec.sessionName)
        guard !session.isEmpty else { throw RemoteTmuxCommand.Invalid.emptySessionName }
        return RemoteSessionKey(host: host, session: session)
    }

    /// The board's session id for this session — the string a remote card carries.
    public var sessionID: String { "remote/\(host)/\(session)" }

    /// The inverse of ``sessionID``, so an existing card can be read back into a key.
    /// `nil` for anything that is not a remote session id (a local card's id is a
    /// title slug, not a path).
    public static func parse(sessionID: String) -> RemoteSessionKey? {
        let parts = sessionID.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "remote",
              !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return RemoteSessionKey(host: String(parts[1]), session: String(parts[2]))
    }
}

/// Why a remote card was refused — surfaced to the operator, never swallowed.
public enum RemoteSessionIssue: Equatable, Sendable, CustomStringConvertible {
    /// Another card on this board already holds the session.
    case duplicateCard(RemoteSessionKey)
    /// The far side already runs a session under this name that Sich did not create,
    /// so `-A` would attach and **ignore** the command argument — `set-environment`
    /// would never run and the card would be bound to nothing.
    case foreignSession(RemoteSessionKey)

    public var description: String {
        switch self {
        case .duplicateCard(let key):
            return "A card already holds tmux session \"\(key.session)\" on \(key.host). "
                + "Two cards would share one remote shell — use another session name."
        case .foreignSession(let key):
            return "tmux session \"\(key.session)\" on \(key.host) is already running and "
                + "was not created by Sich, so it cannot be bound to this card. "
                + "Use another session name."
        }
    }
}

/// What the far side says about a session name.
public enum RemoteSessionPresence: Equatable, Sendable {
    /// The name is free — creating the session will run our binding.
    case absent
    /// A live session already bound to this card.
    case bound
    /// A live session bound to something else (or nothing at all).
    case foreign
    /// The far side did not answer — unreachable, no tmux, spawning disabled.
    /// Never a refusal: silence must not make remote cards unopenable.
    case unknown
}

/// Asks the far side whether a session name is free, ours, or somebody else's.
public enum RemoteSessionProbe {
    public static func presence(
        of key: RemoteSessionKey, cardID: String, spec: RemoteTmuxSpec,
        runner: RemoteCommandRunner
    ) -> RemoteSessionPresence {
        guard let argv = try? RemoteTmuxCommand.sessionProbeArgv(for: spec, session: key.session),
              let result = runner.run(argv: argv, input: nil), result.succeeded
        else { return .unknown }
        return classify(String(decoding: result.standardOutput, as: UTF8.self), cardID: cardID)
    }

    static func classify(_ output: String, cardID: String) -> RemoteSessionPresence {
        if output.contains(RemoteTmuxCommand.noSessionMarker) { return .absent }
        let binding = "\(RemoteTmuxCommand.cardIDVariable)=\(cardID)"
        return output.split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == binding } ? .bound : .foreign
    }
}
