import Foundation
import Testing

@testable import SichCore

/// The vendored Pomodoro engine, driven by an injected clock — the board
/// semantics (card attribution, held cards, hold-for-reply, the fourth break is
/// long) on top of the plain 25/5/15 timer.
@Suite("Pomodoro engine")
struct PomodoroEngineTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test("a fresh engine is idle with a full 25:00 ring")
    func idleStart() {
        let engine = PomodoroEngine()
        #expect(engine.state.phase == .idle)
        #expect(engine.state.remaining == 25 * 60)
        #expect(!engine.state.isRunning)
        #expect(PomodoroFormat.mmss(engine.state.remaining) == "25:00")
    }

    @Test("start tags the card and counts down by wall clock; the digits round up")
    func startAndTick() {
        let card = UUID()
        let engine = PomodoroEngine()
        engine.start(cardID: card, at: t0)
        #expect(engine.state.phase == .work && engine.state.isRunning)
        #expect(engine.state.cardID == card && engine.state.touched == [card])

        engine.tick(at: at(61))
        #expect(engine.state.remaining == 25 * 60 - 61)
        #expect(PomodoroFormat.mmss(engine.state.remaining) == "23:59")
        #expect(abs(engine.state.fraction - (25 * 60 - 61) / (25 * 60)) < 1e-9)
    }

    @Test("pause stops the clock; resume continues from where it stopped")
    func pauseResume() {
        let engine = PomodoroEngine()
        engine.start(cardID: nil, at: t0)
        engine.tick(at: at(60))
        engine.toggle(at: at(60))
        #expect(!engine.state.isRunning)
        engine.tick(at: at(600))
        #expect(engine.state.remaining == 24 * 60, "paused time is not counted")
        engine.toggle(at: at(600))
        engine.tick(at: at(660))
        #expect(engine.state.remaining == 23 * 60)
    }

    @Test("work running out attributes the minutes to the card and starts a short break")
    func workCompletes() {
        let card = UUID()
        var boundaries: [(PomodoroPhase, PomodoroPhase)] = []
        let engine = PomodoroEngine()
        engine.onPhaseCompleted = { boundaries.append(($0, $1)) }
        engine.start(cardID: card, at: t0)
        engine.tick(at: at(25 * 60 + 1))

        #expect(engine.state.phase == .shortBreak && engine.state.isRunning)
        #expect(engine.state.remaining == 5 * 60)
        #expect(engine.state.completed == 1)
        #expect(engine.state.focusToday == 25 * 60)
        #expect(engine.state.humanTime(for: card) == 25 * 60)
        #expect(boundaries.count == 1)
        #expect(boundaries[0].0 == .work && boundaries[0].1 == .shortBreak)
    }

    @Test("the fourth completed pomodoro earns the long break")
    func fourthBreakIsLong() {
        let engine = PomodoroEngine()
        var clock: TimeInterval = 0
        for round in 1...4 {
            engine.start(cardID: nil, at: at(clock))
            clock += 25 * 60
            engine.tick(at: at(clock))
            #expect(engine.state.completed == round)
            #expect(engine.state.phase == (round == 4 ? .longBreak : .shortBreak))
            clock += engine.state.total
            engine.tick(at: at(clock))
            #expect(engine.state.breakOver, "the break runs out into the tray")
        }
        #expect(engine.state.remaining == 0 && !engine.state.isRunning)
    }

    @Test("rest now ends the work early: minutes count, the pomodoro does not")
    func restNowIsEarly() {
        let card = UUID()
        let engine = PomodoroEngine()
        engine.start(cardID: card, at: t0)
        engine.tick(at: at(10 * 60))
        engine.restNow(at: at(10 * 60))
        #expect(engine.state.phase == .shortBreak)
        #expect(engine.state.completed == 0)
        #expect(engine.state.humanTime(for: card) == 10 * 60)
        #expect(engine.state.focusToday == 10 * 60)
    }

    @Test("a pomodoro split over three cards credits each with the minutes spent in it")
    func minutesFollowTheCardYouAreIn() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        let engine = PomodoroEngine()
        engine.start(cardID: a, at: t0)
        engine.tick(at: at(5 * 60))
        engine.tag(cardID: b, at: at(5 * 60))          // drill into b
        engine.tick(at: at(12 * 60))
        engine.tag(cardID: c, at: at(12 * 60))         // then c
        engine.tick(at: at(20 * 60))
        engine.tag(cardID: a, at: at(20 * 60))         // back to a: no duplicate entry
        engine.tick(at: at(25 * 60))

        #expect(engine.state.isBreak)
        #expect(engine.state.humanTime(for: a) == 10 * 60)
        #expect(engine.state.humanTime(for: b) == 7 * 60)
        #expect(engine.state.humanTime(for: c) == 8 * 60)
        #expect(engine.state.focusToday == 25 * 60, "the day's tally is the whole pomodoro")
        #expect(engine.state.touched == [a, b, c])
    }

    @Test("a running total is readable mid-phase; a pause earns nothing; the next pomodoro starts a fresh touched list")
    func runningTotalAndPause() {
        let card = UUID()
        let engine = PomodoroEngine()
        engine.start(cardID: nil, at: t0)
        engine.tick(at: at(3 * 60))                    // untagged minutes land nowhere
        engine.tag(cardID: card, at: at(3 * 60))
        engine.tick(at: at(7 * 60))
        #expect(engine.state.humanTime(for: card) == 4 * 60, "read live, not only at the end")
        engine.toggle(at: at(7 * 60))                  // pause
        engine.tick(at: at(17 * 60))
        engine.toggle(at: at(17 * 60))                 // resume
        engine.tick(at: at(18 * 60))
        #expect(engine.state.humanTime(for: card) == 5 * 60, "paused time is not work")

        engine.restNow(at: at(18 * 60))
        engine.endBreak(at: at(19 * 60))
        engine.start(cardID: nil, at: at(19 * 60))
        #expect(engine.state.touched.isEmpty)
        #expect(engine.state.humanTime(for: card) == 5 * 60, "the card keeps its history")
    }

    @Test("drilling into a held card releases it — you are on it now")
    func drillingIntoAHeldCardReleasesIt() {
        let (mine, other) = (UUID(), UUID())
        let engine = PomodoroEngine()
        engine.start(cardID: mine, at: t0)
        engine.noteCardState(other, state: .waitingForInput)
        #expect(engine.state.held == [other])

        engine.tag(cardID: other, at: at(60))
        #expect(engine.state.held.isEmpty)
        #expect(engine.state.cardID == other)
        engine.noteCardState(other, state: .waitingForInput)
        #expect(engine.state.held.isEmpty, "the card you are in is never held")

        engine.tick(at: at(25 * 60))
        engine.tag(cardID: mine, at: at(25 * 60))
        #expect(engine.state.cardID == other, "a break is not attributed: tagging waits for the next pomodoro")
    }

    @Test("a half-typed reply holds the break until it is released")
    func holdForReply() {
        let engine = PomodoroEngine()
        engine.start(cardID: nil, at: t0)
        engine.tick(at: at(25 * 60), holdForReply: true)
        #expect(engine.state.awaitingReply)
        #expect(engine.state.phase == .work && engine.state.remaining == 0 && !engine.state.isRunning)
        engine.tick(at: at(26 * 60), holdForReply: true)
        #expect(engine.state.phase == .work, "the hold does not time out on its own")
        engine.releaseHold(at: at(26 * 60))
        #expect(engine.state.phase == .shortBreak && engine.state.isRunning)
        #expect(engine.state.completed == 1)
    }

    @Test("cards needing you mid-pomodoro are held; the worked card never is; release on recovery")
    func heldCards() {
        let mine = UUID(), other = UUID(), third = UUID()
        let engine = PomodoroEngine()
        engine.noteCardState(other, state: .waitingForInput)
        #expect(engine.state.held.isEmpty, "nothing is held while idle")

        engine.start(cardID: mine, at: t0)
        engine.noteCardState(other, state: .waitingForInput)
        engine.noteCardState(other, state: .waitingForInput)
        engine.noteCardState(mine, state: .waitingForInput)
        engine.noteCardState(third, state: .waitingForInput)
        #expect(engine.state.held == [other, third])

        engine.noteCardState(other, state: .running)
        #expect(engine.state.held == [third])

        engine.tick(at: at(25 * 60))
        #expect(engine.state.isBreak)
        engine.noteCardState(other, state: .waitingForInput)
        #expect(engine.state.held == [third, other], "the break still coalesces")

        engine.tick(at: at(30 * 60))
        #expect(engine.state.breakOver && engine.state.held == [third, other], "the tray keeps them")
        engine.start(cardID: third, at: at(30 * 60))
        #expect(engine.state.held.isEmpty, "the next pomodoro releases the tray")
    }

    @Test("ending a break early goes idle and releases the held cards")
    func endBreakEarly() {
        let engine = PomodoroEngine()
        engine.start(cardID: nil, at: t0)
        engine.noteCardState(UUID(), state: .waitingForInput)
        engine.tick(at: at(25 * 60))
        engine.endBreak(at: at(26 * 60))
        #expect(engine.state.phase == .idle && engine.state.held.isEmpty)
        #expect(engine.state.remaining == 25 * 60)
        #expect(engine.state.completed == 1, "the finished pomodoro still counts")
    }

    @Test("a reload catches up on the time the app was not running")
    func restoreCatchesUp() throws {
        let engine = PomodoroEngine()
        engine.start(cardID: nil, at: t0)
        engine.tick(at: at(60))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-pomodoro-\(UUID().uuidString)")
        let store = PomodoroStore(directory: dir)
        try store.save(engine.state)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reloaded = PomodoroEngine(state: try #require(store.load()))
        #expect(reloaded.state == engine.state)
        reloaded.tick(at: at(20 * 60))
        #expect(reloaded.state.remaining == 5 * 60, "the 19 minutes away were counted")
    }

    @Test("the day's tallies reset on the first tick of a new day; card time is kept")
    func dayRollover() {
        let card = UUID()
        let engine = PomodoroEngine()
        engine.start(cardID: card, at: t0)
        engine.tick(at: at(25 * 60))
        #expect(engine.state.completed == 1)
        engine.tick(at: at(48 * 3600))
        #expect(engine.state.completed == 0 && engine.state.focusToday == 0)
        #expect(engine.state.humanTime(for: card) == 25 * 60)
    }

    @Test("formats: digits round up, human minutes roll into hours")
    func formats() {
        #expect(PomodoroFormat.mmss(0) == "0:00")
        #expect(PomodoroFormat.mmss(0.4) == "0:01")
        #expect(PomodoroFormat.mmss(900) == "15:00")
        #expect(PomodoroFormat.minutes(0) == "0m")
        #expect(PomodoroFormat.minutes(75 * 60) == "1h 15m")
        #expect(PomodoroFormat.minutes(59 * 60 + 59) == "59m")
    }
}

@Suite("Pomodoro hint")
struct PomodoroHintTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ state: CardState) -> BoardCard {
        BoardCard(sessionID: "s", projectDir: "/tmp/p", agent: .claude, state: state)
    }

    private func working() -> PomodoroState {
        var state = PomodoroState()
        state.phase = .work
        state.isRunning = true
        return state
    }

    @Test("an exhausted 5H pool refilling within a long break makes the break a refill")
    func refillHint() {
        let gauge = QuotaGauge(
            provider: "anthropic", pool: "interactive_5h", state: .exhausted,
            confidence: .measured, refillKind: .rollingWindow, reset: now.addingTimeInterval(9 * 60))
        let hint = PomodoroHint.compute(
            state: working(), gauges: [gauge], cards: [card(.waitingForInput)], now: now)
        #expect(hint == .breakIsRefill(resetIn: 9 * 60))
        #expect(hint?.text.hasPrefix("5H pool back in") == true)
    }

    @Test("a refill an hour away is not a hint; a healthy pool is not a hint")
    func noRefillHint() {
        let far = QuotaGauge(
            provider: "anthropic", pool: "interactive_5h", state: .exhausted,
            confidence: .measured, refillKind: .rollingWindow, reset: now.addingTimeInterval(3600))
        #expect(PomodoroHint.compute(state: working(), gauges: [far], cards: [card(.waitingForInput)], now: now) == nil)
        let healthy = QuotaGauge(
            provider: "anthropic", pool: "interactive_5h", state: .active,
            confidence: .measured, refillKind: .rollingWindow, reset: now.addingTimeInterval(60))
        #expect(PomodoroHint.compute(state: working(), gauges: [healthy], cards: [card(.waitingForInput)], now: now) == nil)
    }

    @Test("two live agents both working says rest now; a waiting card, a held card, a lone agent or a drill-in silences it")
    func allWorkingHint() {
        let cards = [card(.running), card(.runningTests), card(.done), card(.idle), card(.blocked)]
        #expect(PomodoroHint.compute(state: working(), gauges: [], cards: cards, now: now) == .allAgentsWorking)
        #expect(PomodoroHint.compute(state: working(), gauges: [], cards: cards, now: now)?.text == "all agents working — rest now?")
        #expect(PomodoroHint.compute(state: working(), gauges: [], cards: cards + [card(.waitingForInput)], now: now) == nil)
        #expect(PomodoroHint.compute(state: working(), gauges: [], cards: [card(.running)], now: now) == nil, "one agent is not a fleet")
        #expect(PomodoroHint.compute(state: working(), gauges: [], cards: cards, drilledIn: true, now: now) == nil)
        var held = working()
        held.held = [UUID()]
        #expect(PomodoroHint.compute(state: held, gauges: [], cards: cards, now: now) == nil)
        var ending = working()
        ending.remaining = 2 * 60
        #expect(PomodoroHint.compute(state: ending, gauges: [], cards: cards, now: now) == nil, "too late to rest now")
    }

    @Test("hints only speak during a running work phase")
    func hintsOnlyDuringWork() {
        var idle = PomodoroState()
        idle.phase = .idle
        #expect(PomodoroHint.compute(state: idle, gauges: [], cards: [card(.running)], now: now) == nil)
        var paused = working()
        paused.isRunning = false
        #expect(PomodoroHint.compute(state: paused, gauges: [], cards: [card(.running), card(.running)], now: now) == nil)
    }
}
