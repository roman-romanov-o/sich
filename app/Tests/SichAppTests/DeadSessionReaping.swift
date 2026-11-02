import Foundation
import SichCore

@testable import SichApp

extension BoardShell {
    /// Run the reconcile pass until it reaps a dead child (bounded), draining the
    /// card's pty in between the way the production pump does. A test never starts the
    /// pump, and an undrained tty can hold a dying child in its exit — the close waits
    /// for output nobody reads — so a loop that only polls would be waiting on itself.
    @discardableResult
    func reconcileUntilReaped(_ cardID: UUID, attempts: Int = 500) -> Bool {
        for _ in 0..<attempts {
            if let pty = ptyForTesting(cardID), pty.masterFD >= 0 {
                pty.setNonBlocking()
                _ = pty.pumpAvailable()
            }
            if !reconcileDeadSessions().isEmpty { return true }
            usleep(10_000)
        }
        return false
    }
}
