import Foundation

/// Detects Codex's interactive choice UI from the terminal's rendered screen.
///
/// This is intentionally narrow: Codex's request-for-choice screen carries a stable
/// footer with select/navigation/cancel affordances. A plain question in scrollback
/// is not enough to light the board's NEEDS YOU signal.
public enum CodexChoiceScreen {
    public static func isWaitingForChoice(_ screen: String) -> Bool {
        // The affordance is a footer; bounding normalization prevents a large
        // screen export from multiplying Unicode and string-search work.
        let normalized = String(screen.suffix(4096))
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .lowercased()

        return normalized.contains("enter to select")
            && normalized.contains("to navigate")
            && normalized.contains("esc to cancel")
    }
}
