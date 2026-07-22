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
        }
        return .interactive
    }

    private static func isClaude(_ executable: String) -> Bool {
        (executable as NSString).lastPathComponent == "claude"
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
