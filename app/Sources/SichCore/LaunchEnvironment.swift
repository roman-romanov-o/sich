import Foundation

/// The environment a Sich process must NOT inherit from whatever launched it.
///
/// Launched from Finder, Sich starts with launchd's clean environment. Launched from
/// a shell inside one of its own cards — an agent rebuilding and relaunching the app
/// — it inherits that card's binding (`SICH_CARD_ID`) and that agent session's
/// markers (`CLAUDECODE`, `CLAUDE_CODE_*`, `CLAUDE_PID`, …), and hands them to EVERY
/// pty it spawns from then on. Observed fallout: the hidden `/usage` probe stamped
/// each of its throwaway sessions with the launching card's id, and that fresh
/// (idle, newest) observation dragged the card from NEEDS YOU to QUEUE on every
/// refresh; every nested `claude` saw `CLAUDE_CODE_CHILD_SESSION` and stopped saving
/// transcripts; cards without a profile ran under the launcher's `CLAUDE_CONFIG_DIR`.
///
/// Scrubbing at process start makes a from-a-card launch indistinguishable from a
/// Finder launch. A card's shell re-derives what it needs (`SICH_CARD_ID`, the
/// profile's config dir) from its own launch line, never from the app's environment.
public enum LaunchEnvironment {
    /// Names that only mean something INSIDE a card or INSIDE an agent session.
    static let sessionScopedNames: Set<String> = [
        "SICH_CARD_ID", "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_CONFIG_DIR",
    ]
    static let sessionScopedPrefixes: [String] = ["CLAUDE_CODE_"]

    /// The keys of `environment` that must not outlive process start.
    public static func inheritedSessionKeys(in environment: [String: String]) -> [String] {
        environment.keys
            .filter { key in
                sessionScopedNames.contains(key)
                    || sessionScopedPrefixes.contains { key.hasPrefix($0) }
            }
            .sorted()
    }

    /// Drop every session-scoped variable from this process's environment, so no
    /// child pty (card shell, hidden probe, ssh relay) can inherit it.
    public static func scrub() {
        for key in inheritedSessionKeys(in: ProcessInfo.processInfo.environment) {
            unsetenv(key)
        }
    }
}
