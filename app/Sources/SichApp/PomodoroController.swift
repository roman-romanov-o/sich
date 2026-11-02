import AppKit
import SichCore

/// The shell's handle on the pomodoro: owns the engine, the on-disk state and the
/// one-second clock; every mutation goes through here so the state is saved after
/// each change and the views learn about it from a single `onChange`.
///
/// Board signals (`noteCardState`, `forget`) save but do not fire `onChange` — they
/// arrive from inside the shell's own render sweep, which repaints the pomodoro
/// views itself at the end; firing back into it would re-enter the sweep.
@MainActor
final class PomodoroController {
    let engine: PomodoroEngine
    private var store: PomodoroStore?
    private var timer: Timer?
    private var lastSaved: PomodoroState?
    /// Injectable clock, so a test can run a phase out without waiting 25 minutes.
    var now: () -> Date = Date.init
    /// The state changed by a control or a tick (not by a board signal).
    var onChange: (() -> Void)?
    /// A phase ended: `(finished, next)`; `next == .idle` for a break that ran out
    /// (then `state.breakOver`) or was ended.
    var onPhaseCompleted: ((PomodoroPhase, PomodoroPhase) -> Void)?
    /// Asked at the instant the work phase runs out: is there an unsent prompt in
    /// the drilled-in terminal? If so the break waits for ↵.
    var holdForReply: () -> Bool = { false }

    var state: PomodoroState { engine.state }

    init(engine: PomodoroEngine = PomodoroEngine()) {
        self.engine = engine
        engine.onPhaseCompleted = { [weak self] finished, next in
            self?.onPhaseCompleted?(finished, next)
        }
    }

    /// Load the saved state and catch its clock up to now (a phase that ran out
    /// while the app was closed completes on this first tick).
    func attach(store: PomodoroStore) {
        self.store = store
        if let saved = store.load() {
            engine.restore(saved)
            lastSaved = saved
            tick()
        }
    }

    func startTicking() {
        guard timer == nil else { return }
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        engine.tick(at: now(), holdForReply: holdForReply())
        changed()
    }

    // MARK: - Controls

    func start(cardID: UUID?) {
        engine.start(cardID: cardID, at: now())
        changed()
    }

    func toggle() {
        engine.toggle(at: now())
        changed()
    }

    func restNow() {
        engine.restNow(at: now())
        changed()
    }

    func endBreak() {
        engine.endBreak(at: now())
        changed()
    }

    func releaseHold() {
        engine.releaseHold(at: now())
        changed()
    }

    /// Drilling into a card mid-pomodoro moves the minutes onto it from here —
    /// they follow where you actually are, card by card.
    func noteDrilledIn(_ cardID: UUID) {
        engine.tag(cardID: cardID, at: now())
        changed()
    }

    /// Standups (the NEEDS YOU prompt) wait for a phase boundary: never during work
    /// or a break; the break-over tray is itself the standup.
    var allowsStandup: Bool { state.phase == .idle }

    // MARK: - Board signals

    func noteCardState(_ cardID: UUID, state newState: CardState) {
        engine.noteCardState(cardID, state: newState)
        save()
    }

    func forget(cardID: UUID) {
        engine.forget(cardID: cardID)
        save()
    }

    // MARK: - Private

    private func changed() {
        guard state != lastSaved else { return }
        save()
        onChange?()
    }

    private func save() {
        guard state != lastSaved else { return }
        lastSaved = state
        try? store?.save(state)
    }
}
