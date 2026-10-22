import Foundation

/// Builds a context handoff prompt when a task moves to another harness or account.
/// Conversation ids do not port across agents; the handoff points the new harness
/// at the prior session's on-disk transcript instead of pasting terminal noise.
public enum HarnessHandoff {
    public static let maxWorkLogLines = 24

    public static func prompt(
        title: String?,
        projectDir: String,
        priorAgent: CardAgent,
        priorAccountName: String?,
        priorTranscriptPath: String?,
        workLogTail: String?,
        taskFolder: String?
    ) -> String {
        var parts: [String] = []
        let prior = priorAccountName.map { "\(priorAgent.displayName) (\($0))" }
            ?? priorAgent.displayName
        parts.append("Continuing a task that was running on \(prior).")
        if let title, !title.isEmpty { parts.append("Task: \(title)") }
        parts.append("Project: \(projectDir)")
        if let taskFolder, !taskFolder.isEmpty {
            parts.append("Saha task folder: \(taskFolder)")
        }
        if let priorTranscriptPath, !priorTranscriptPath.isEmpty {
            parts.append("""
                Prior session transcript (read/search this file for context — do not assume \
                anything not in it):
                \(priorTranscriptPath)
                """)
        }
        if let workLogTail, !workLogTail.isEmpty {
            parts.append("\nOperator work log (human timeline, not the agent transcript):\n\(workLogTail)")
        }
        parts.append("\nPlease continue this work from where the prior session left off.")
        return parts.joined(separator: "\n")
    }

    /// Last N non-empty lines from the plain-text Sich work log.
    public static func tail(ofWorkLog text: String, maxLines: Int = maxWorkLogLines) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return "" }
        return lines.suffix(maxLines).joined(separator: "\n")
    }
}
