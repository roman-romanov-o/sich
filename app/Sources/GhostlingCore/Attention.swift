import Foundation

/// The "who needs me" attention derivation (US-005) — a faithful port of the
/// Python `attention.py`, pure over card state.
///
/// A session needs the operator when it is `waitingForInput` or `blocked`. These
/// helpers only *route* attention — they read card state and return a count or a
/// filtered list. They never mutate, notify, or act for the user (US-005
/// suggest-only constraint). Zero is the quiet, no-false-alarm state (AC#3).
public enum Attention {

    /// Cards in `waitingForInput` or `blocked`, in input order. `idle`/`running`
    /// (and every other state) are never included, so the operator only sees
    /// genuine blockers (US-005 AC#1).
    public static func cards(_ cards: [BoardCard]) -> [BoardCard] {
        cards.filter { $0.state.needsAttention }
    }

    /// How many sessions need the operator (AC#1); `0` means quiet (AC#3) — no
    /// false alarm when everything is running/idle.
    public static func count(_ cards: [BoardCard]) -> Int {
        self.cards(cards).count
    }
}
