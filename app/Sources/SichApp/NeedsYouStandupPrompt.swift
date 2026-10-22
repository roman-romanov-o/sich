import AppKit
import SichCore

/// Native standup sheet for one stale NEEDS YOU card (Rule 1).
@MainActor
enum NeedsYouStandupPrompt {

    enum Choice {
        case respondNow
        case deferUntilTomorrow
        case markDone
        case cancelled
    }

    static func run(for card: BoardCard, waitingSince: Date, now: Date = Date()) -> Choice {
        let age = max(0, now.timeIntervalSince(waitingSince))
        let title = card.title ?? card.projectDir
        let alert = NSAlert()
        alert.messageText = "NEEDS YOU — \(title)"
        alert.informativeText = """
            This task has been waiting \(formatAge(age)). Rule 1: respond, defer to \
            queue until tomorrow, or mark done — don't leave it abandoned.
            """
        alert.addButton(withTitle: "Respond now")
        alert.addButton(withTitle: "Defer to queue until tomorrow")
        alert.addButton(withTitle: "Mark done")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .respondNow
        case .alertSecondButtonReturn: return .deferUntilTomorrow
        case .alertThirdButtonReturn: return .markDone
        default: return .cancelled
        }
    }

    private static func formatAge(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        let hours = seconds / 3600
        let minutes = seconds / 60 % 60
        if hours >= 48 {
            return "\(hours / 24)d \(hours % 24)h"
        }
        if hours >= 1 { return "\(hours)h \(minutes)m" }
        return "\(max(1, minutes))m"
    }
}
