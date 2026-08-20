import AppKit
import SichCore

/// Checklist 18.08, item 7: remembers WHEN each card started needing the operator,
/// so the card face can age its attention signal ("waiting 4m" is nearly invisible,
/// "waiting 3h35m" is loud). Fed by the board's central state sweep — the same
/// choke point the work journal reads — and consumed by ``SessionCard``.
@MainActor
final class AttentionClock {
    static let shared = AttentionClock()

    private var since: [UUID: Date] = [:]

    /// Record what the sweep sees. Entering a needs-attention state starts the
    /// clock (seeded from the card's last observation time when it has one — a
    /// hook-observed card was already waiting before we noticed); leaving stops it.
    func note(_ card: BoardCard, at now: Date = Date()) {
        guard card.state.needsAttention else {
            since[card.id] = nil
            return
        }
        guard since[card.id] == nil else { return }
        since[card.id] = card.updatedAt > .distantPast ? min(card.updatedAt, now) : now
    }

    func waitingSince(_ id: UUID) -> Date? { since[id] }

    /// Forget cards that left the board so the map can't grow unbounded.
    func retain(_ live: Set<UUID>) {
        since = since.filter { live.contains($0.key) }
    }
}
