import Foundation

/// Which quota pool a managed session draws from.
///
/// The product's economic invariant (see the project memory): managed sessions
/// run **interactive** `claude` inside our owned PTY, billing the Claude
/// subscription's *interactive* pool. The tool must **never** auto-launch
/// `claude -p` / the Agent SDK, which would silently spend the separate
/// headless API-credit pool.
public enum Pool: Sendable, Equatable {
    case interactive
}

/// Raised when a launch would route to the forbidden headless pool.
public enum PoolViolation: Error, Equatable, CustomStringConvertible {
    case emptyCommand
    case headlessClaudeForbidden(flag: String)

    public var description: String {
        switch self {
        case .emptyCommand:
            return "refusing to launch an empty command"
        case .headlessClaudeForbidden(let flag):
            return "refusing to launch headless `claude \(flag)` — that spends the API-credit "
                + "pool. Managed sessions must run interactive `claude` in our PTY."
        }
    }
}

/// In-code firewall that keeps every spawned session on the interactive pool.
///
/// This is structural, not advisory: ``PTYSession`` validates through it before
/// it ever calls into the spawn path, so there is no way to launch a managed
/// session that drains the headless pool.
public enum PoolFirewall {
    /// Flags that switch `claude` into headless / print (API-credit) mode.
    static let headlessFlags: Set<String> = ["-p", "--print"]

    /// Classify a command into its pool, or throw if it is forbidden.
    @discardableResult
    public static func classify(_ argv: [String]) throws -> Pool {
        guard let executable = argv.first else { throw PoolViolation.emptyCommand }
        if isClaude(executable) {
            try assertNoHeadlessFlag(in: argv.dropFirst())
        } else if isSSH(executable) {
            try assertNoHeadlessClaude(inRemoteCommand: remoteCommand(of: argv))
        }
        return .interactive
    }

    private static func isClaude(_ executable: String) -> Bool {
        (executable as NSString).lastPathComponent == "claude"
    }

    private static func isSSH(_ executable: String) -> Bool {
        (executable as NSString).lastPathComponent == "ssh"
    }

    // MARK: - the ssh branch (DD-004)
    //
    // BEST-EFFORT, AND DELIBERATELY NOT SOUND. Do not read what follows as a
    // firewall: the remote command is a string re-parsed by a login shell we do
    // not control, so no local scan can decide what it will run.
    //
    // The actual guarantee is structural and lives elsewhere: ssh argvs are only
    // ever GENERATED from a constrained `RemoteTmuxSpec`, never supplied, and the
    // destination token comes from `RemoteTmuxCommand.destination(for:)`. This
    // scan is a second net under that guarantee. The real failure mode is a future
    // reader assuming it is the first one.
    //
    // It also does not — and must not — stop a human from typing `claude -p` in
    // their own remote pane. The invariant protects the operator from OUR
    // automation, not from themselves.

    /// ssh options that consume the FOLLOWING word as their value (`-o Foo=bar`).
    /// The attached form (`-oFoo=bar`) carries its value in the same word.
    private static let sshFlagsTakingAValue: Set<Character> = [
        "B", "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l",
        "m", "O", "o", "P", "p", "Q", "R", "S", "W", "w"
    ]

    /// The operand words left after ssh's options and its destination — i.e. what
    /// gets handed to the login shell on the far side.
    private static func remoteCommand(of argv: [String]) -> [String] {
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            guard arg.hasPrefix("-"), arg.count > 1 else { break }  // the destination
            let flag = arg.dropFirst()
            let consumesNextWord = flag.count == 1 && sshFlagsTakingAValue.contains(flag[flag.startIndex])
            index += consumesNextWord ? 2 : 1
        }
        return Array(argv.dropFirst(index + 1))  // options + destination
    }

    /// Tokenized on shell word boundaries — NEVER a substring search for "claude"
    /// over the joined argv, which would refuse a tmux session named `claude-work`.
    private static func assertNoHeadlessClaude(inRemoteCommand words: [String]) throws {
        for word in words {
            let tokens = word.split(whereSeparator: { " \t\n;|&()".contains($0) })
                .map { unquoted(String($0)) }
            guard tokens.contains(where: isClaude) else { continue }
            try assertNoHeadlessFlag(in: tokens)
        }
    }

    private static func unquoted(_ token: String) -> String {
        String(token.drop(while: { $0 == "'" || $0 == "\"" })
            .reversed().drop(while: { $0 == "'" || $0 == "\"" }).reversed())
    }

    private static func assertNoHeadlessFlag<S: Sequence>(in args: S) throws where S.Element == String {
        for arg in args {
            // Normalize `--print=...` / `-p=...` to the bare flag before comparing.
            let flag = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
            if headlessFlags.contains(flag) {
                throw PoolViolation.headlessClaudeForbidden(flag: flag)
            }
        }
    }
}
