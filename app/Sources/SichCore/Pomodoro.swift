import Foundation

/// The operator's Pomodoro — the one timer on the board that measures YOU, not an
/// agent. Vendored from the sibling `macos-flow` engine (`PomodoroState` + `Phase`
/// + `PomodoroConstants`) and reshaped into a pure, clock-injected state machine:
/// no Combine, no `@Observable`, no scheduler — the shell ticks it from a wall-clock
/// timer and reads the state back. Everything the dock, the rest overlay and the
/// board need to decide is derivable from ``PomodoroState`` alone, so it is also
/// what gets persisted (see ``PomodoroStore``).
///
/// Board semantics on top of the plain timer (research 2026-10-28):
/// - a pomodoro is *tagged* to the card you are working, so the minutes you spend
///   land on that card as human time beside the agent's working time;
/// - agents never stop for a break — the break only blurs YOUR view;
/// - a card that starts needing you mid-pomodoro is *held* (dimmed, coalesced
///   into "N will need you after this pomodoro") instead of pulling focus;
/// - the break can *wait for your reply* when the work ran out with a half-typed
///   prompt in the drilled-in terminal (``releaseHold(at:)``).
public enum PomodoroPhase: String, Codable, Sendable, Equatable {
    case idle
    case work
    case shortBreak = "short_break"
    case longBreak = "long_break"

    public var duration: TimeInterval {
        switch self {
        case .idle: return PomodoroConstants.work
        case .work: return PomodoroConstants.work
        case .shortBreak: return PomodoroConstants.shortBreak
        case .longBreak: return PomodoroConstants.longBreak
        }
    }

    public var isBreak: Bool { self == .shortBreak || self == .longBreak }
}

public enum PomodoroConstants {
    public static let work: TimeInterval = 25 * 60
    public static let shortBreak: TimeInterval = 5 * 60
    public static let longBreak: TimeInterval = 15 * 60
    /// Pomodoros per cycle — the fourth break is the long one.
    public static let perCycle = 4
    /// The last stretch of a phase, where the ring's ink drifts toward attention.
    public static let attentionWindow: TimeInterval = 3 * 60
}

/// Everything the Pomodoro is, as a value. `remaining` is the authoritative
/// countdown; `lastTick` lets a reload after sleep/relaunch account for the time
/// the app was not running instead of silently pausing.
public struct PomodoroState: Codable, Equatable, Sendable {
    public var phase: PomodoroPhase = .idle
    public var remaining: TimeInterval = PomodoroConstants.work
    public var total: TimeInterval = PomodoroConstants.work
    public var isRunning = false
    /// Pomodoros completed today (early "rest now" does not count).
    public var completed = 0
    /// Focused minutes today — the sum of every work phase's spent time.
    public var focusToday: TimeInterval = 0
    /// The card the minutes land on right now — the one you are in (or were last
    /// in). A pomodoro is rarely one task: every card you drill into takes over
    /// from here, and the time already spent stays with the card it was spent on.
    public var cardID: UUID?
    /// Every card that took minutes during this pomodoro, in the order you reached
    /// them. Cleared when the next one starts.
    public var touched: [UUID] = []
    /// Work ran out with a reply half-typed: the break starts on ↵, not before.
    public var awaitingReply = false
    /// The break ran out: the ring stops at zero and the tray of held cards shows
    /// until the next pomodoro starts or the operator goes back to the board.
    public var breakOver = false
    /// Cards that started needing you during this pomodoro (and its break), in
    /// arrival order — dimmed on the board, listed in the break-over tray.
    public var held: [UUID] = []
    /// Human time attributed per card, across every pomodoro ever tagged to it.
    public var humanTime: [UUID: TimeInterval] = [:]
    /// The local calendar day `completed`/`focusToday` belong to.
    public var day: String = ""
    public var lastTick: Date?

    public init() {}

    public var isBreak: Bool { phase.isBreak }
    /// The arc the ring draws: the share of the phase still ahead.
    public var fraction: Double { total > 0 ? max(0, min(1, remaining / total)) : 0 }
    // periphery:ignore - test-only reader (scan runs with exclude_tests)
    public func humanTime(for cardID: UUID) -> TimeInterval { humanTime[cardID] ?? 0 }
}

public final class PomodoroEngine {
    public private(set) var state: PomodoroState
    /// Fired on every phase boundary with (finished, next) — `next` is `.idle` when
    /// the break ran out (the tray is showing) or the operator ended early.
    public var onPhaseCompleted: ((PomodoroPhase, PomodoroPhase) -> Void)?

    public init(state: PomodoroState = PomodoroState()) {
        self.state = state
    }

    // MARK: - Controls

    /// Begin a work phase. From the break-over tray this is also what clears the
    /// held cards (they undim; you are about to answer them one by one).
    public func start(cardID: UUID?, at now: Date) {
        rollDay(at: now)
        state.phase = .work
        state.total = PomodoroConstants.work
        state.remaining = state.total
        state.isRunning = true
        state.cardID = cardID
        state.touched = cardID.map { [$0] } ?? []
        state.awaitingReply = false
        state.breakOver = false
        state.held = []
        state.lastTick = now
    }

    /// Pause / resume the running phase. A no-op while idle, held or over.
    public func toggle(at now: Date) {
        guard state.phase != .idle, !state.awaitingReply, !state.breakOver else { return }
        if state.isRunning {
            settle(at: now)
            state.isRunning = false
        } else {
            state.isRunning = true
            state.lastTick = now
        }
    }

    /// "rest now ›": end the work phase early. The minutes still count toward the
    /// card and the day; the pomodoro itself does not (it was not completed).
    public func restNow(at now: Date) {
        guard state.phase == .work, !state.awaitingReply else { return }
        settle(at: now)
        finishWork(early: true, holdForReply: false, at: now)
    }

    /// Leave the break (or the break-over tray) and go idle. Held cards undim.
    public func endBreak(at now: Date) {
        guard state.isBreak else { return }
        let finished = state.phase
        settle(at: now)
        goIdle()
        onPhaseCompleted?(finished, .idle)
    }

    /// The reply the break was waiting for went out: start the break now.
    public func releaseHold(at now: Date) {
        guard state.awaitingReply else { return }
        state.awaitingReply = false
        beginBreak(at: now)
    }

    /// You moved to another card mid-pomodoro: the minutes so far are banked on
    /// the card you were in, and from `now` they land on this one. A card you are
    /// in is never held — you are answering it.
    public func tag(cardID: UUID, at now: Date) {
        guard state.phase == .work || state.awaitingReply, state.cardID != cardID else { return }
        settle(at: now)
        state.cardID = cardID
        if !state.touched.contains(cardID) { state.touched.append(cardID) }
        state.held.removeAll { $0 == cardID }
    }

    // MARK: - Time

    /// Advance the countdown to `now`. `holdForReply` is the shell's answer to
    /// "is there an unsent prompt in the drilled-in terminal right now" — only
    /// consulted at the instant the work phase runs out.
    public func tick(at now: Date, holdForReply: Bool = false) {
        rollDay(at: now)
        guard state.isRunning else { return }
        settle(at: now)
        guard state.remaining <= 0 else { return }
        state.remaining = 0
        state.isRunning = false
        switch state.phase {
        case .work:
            finishWork(early: false, holdForReply: holdForReply, at: now)
        case .shortBreak, .longBreak:
            state.breakOver = true
            onPhaseCompleted?(state.phase, .idle)
        case .idle:
            break
        }
    }

    /// Replace the state wholesale (a reload from disk).
    public func restore(_ restored: PomodoroState) {
        state = restored
    }

    // MARK: - Board signals

    /// A card changed state. Cards that start needing you while a pomodoro (or its
    /// break) is on are held; the card you are working is never held — you are on
    /// it. A held card that stops needing you is released.
    public func noteCardState(_ cardID: UUID, state newState: CardState) {
        guard state.phase != .idle, !state.breakOver else { return }
        if newState.needsAttention, cardID != state.cardID {
            if !state.held.contains(cardID) { state.held.append(cardID) }
        } else {
            state.held.removeAll { $0 == cardID }
        }
    }

    /// A card left the board — nothing may keep pointing at it.
    public func forget(cardID: UUID) {
        state.held.removeAll { $0 == cardID }
        state.humanTime[cardID] = nil
        if state.cardID == cardID { state.cardID = nil }
    }

    // MARK: - Private

    /// Move `remaining` forward to `now` without crossing a phase boundary. Work
    /// time is attributed as it passes — to whichever card is current — so a
    /// pomodoro split over three cards credits each with the minutes you spent
    /// in it, and the drill-in header can read the running total straight off.
    private func settle(at now: Date) {
        guard state.isRunning else { return }
        let last = state.lastTick ?? now
        let elapsed = max(0, now.timeIntervalSince(last))
        if state.phase == .work, let card = state.cardID {
            state.humanTime[card, default: 0] += min(elapsed, max(0, state.remaining))
        }
        state.remaining -= elapsed
        state.lastTick = now
    }

    private func finishWork(early: Bool, holdForReply: Bool, at now: Date) {
        let spent = max(0, state.total - max(0, state.remaining))
        state.focusToday += spent
        if !early { state.completed += 1 }
        state.remaining = 0
        state.isRunning = false
        if holdForReply {
            state.awaitingReply = true
            return
        }
        beginBreak(at: now)
    }

    private func beginBreak(at now: Date) {
        let long = state.completed > 0 && state.completed % PomodoroConstants.perCycle == 0
        let next: PomodoroPhase = long ? .longBreak : .shortBreak
        state.phase = next
        state.total = next.duration
        state.remaining = next.duration
        state.isRunning = true
        state.breakOver = false
        state.lastTick = now
        onPhaseCompleted?(.work, next)
    }

    private func goIdle() {
        state.phase = .idle
        state.total = PomodoroConstants.work
        state.remaining = PomodoroConstants.work
        state.isRunning = false
        state.awaitingReply = false
        state.breakOver = false
        state.held = []
        state.lastTick = nil
    }

    /// `completed` and `focusToday` are per-day tallies.
    private func rollDay(at now: Date) {
        let today = Self.dayStamp(now)
        guard state.day != today else { return }
        state.day = today
        state.completed = 0
        state.focusToday = 0
    }

    static func dayStamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}

/// The one line of advice under the ring, derived from the board + quota (pure).
public enum PomodoroHint: Equatable, Sendable {
    /// The interactive 5H pool is spent and refills within a long break's reach —
    /// the break is a refill, not a loss.
    case breakIsRefill(resetIn: TimeInterval)
    /// At least two live agents and every one of them busy, nothing held, more
    /// than the attention window left: nothing needs you, rest now.
    case allAgentsWorking

    /// The one line of advice under the ring. Only speaks during a RUNNING work
    /// phase, and never while you are inside a task (`drilledIn`) — the hint is a
    /// board-level nudge.
    public static func compute(
        state: PomodoroState, gauges: [QuotaGauge], cards: [BoardCard],
        drilledIn: Bool = false, now: Date
    ) -> PomodoroHint? {
        guard state.phase == .work, state.isRunning else { return nil }
        let spent = gauges.first { gauge in
            guard gauge.provider == "anthropic", gauge.state == .exhausted,
                  gauge.refillKind == .rollingWindow, let reset = gauge.reset else { return false }
            let left = reset.timeIntervalSince(now)
            return left > 0 && left <= PomodoroConstants.longBreak
        }
        if let reset = spent?.reset {
            return .breakIsRefill(resetIn: reset.timeIntervalSince(now))
        }
        let live = cards.filter { card in
            switch card.state {
            case .done, .parked, .unreachable, .unknown, .idle, .blocked: return false
            case .running, .runningTests, .waitingForInput: return true
            }
        }
        if live.count >= 2, live.allSatisfy({ $0.state.isWorking }),
           state.remaining > PomodoroConstants.attentionWindow,
           state.held.isEmpty, !drilledIn {
            return .allAgentsWorking
        }
        return nil
    }

    public var text: String {
        switch self {
        case .breakIsRefill(let left):
            return "5H pool back in \(QuotaCountdown.timeLeft(to: Date(timeIntervalSinceNow: left), from: Date())) — take that as the break?"
        case .allAgentsWorking:
            return "all agents working — rest now?"
        }
    }
}

public enum PomodoroFormat {
    /// `24:59` — the ring's digits.
    public static func mmss(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// `1h 15m` / `45m` / `0m` — the human-time readouts.
    public static func minutes(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

/// `Application Support/Sich/pomodoro.json` — the timer survives a relaunch, and
/// ``PomodoroState/lastTick`` lets the reload catch up on the time it missed.
public final class PomodoroStore {
    private let url: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(directory: URL) {
        url = directory.appendingPathComponent("pomodoro.json")
    }

    public static func applicationSupport() -> PomodoroStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return PomodoroStore(directory: base.appendingPathComponent("Sich", isDirectory: true))
    }

    public func save(_ state: PomodoroState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    /// `nil` when nothing was saved or the file is unreadable — start fresh.
    public func load() -> PomodoroState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(PomodoroState.self, from: data)
    }
}
