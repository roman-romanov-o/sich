import Foundation
import Testing

@testable import SichCore

@Suite("Board card working duration")
struct BoardCardWorkingDurationTests {
    @Test("working intervals start, survive test-running, and reset after leaving")
    func workingIntervalLifecycle() {
        let firstStart = Date(timeIntervalSince1970: 1_000)
        let testsStart = firstStart.addingTimeInterval(300)
        let firstStop = firstStart.addingTimeInterval(600)
        let secondStart = firstStart.addingTimeInterval(900)
        let secondTick = secondStart.addingTimeInterval(240)
        let queued = BoardCard(
            sessionID: "timer", title: "Timer", projectDir: "/tmp/p",
            agent: .codex, state: .idle
        )

        let running = queued.with(state: .running, at: firstStart)
        #expect(running.workingSince == firstStart)

        let testing = running.with(state: .runningTests, at: testsStart)
        #expect(testing.workingSince == firstStart,
                "running tests is still the same trip through WORKING")
        #expect(testing.with(title: "Renamed").workingSince == firstStart)

        #expect(testing.currentWorkingTime(at: firstStop) == 600)
        #expect(testing.totalWorkingTime(at: firstStop) == 600)

        let waiting = testing.with(state: .waitingForInput, at: firstStop)
        #expect(waiting.workingSince == nil)
        #expect(waiting.accumulatedWorkingTime == 600)
        #expect(waiting.totalWorkingTime(at: secondStart) == 600,
                "Needs You time does not inflate active work")

        let resumed = waiting.with(state: .running, at: secondStart)
        #expect(resumed.workingSince == secondStart,
                "returning to WORKING starts a new interval")
        #expect(resumed.currentWorkingTime(at: secondTick) == 240)
        #expect(resumed.totalWorkingTime(at: secondTick) == 840)
    }

    @Test("non-working construction discards an impossible working timestamp")
    func nonWorkingStateHasNoTimer() {
        let card = BoardCard(
            sessionID: "idle", projectDir: "/tmp/p", agent: .claude,
            state: .idle, workingSince: Date()
        )
        #expect(card.workingSince == nil)
        #expect(CardState.running.isWorking)
        #expect(CardState.runningTests.isWorking)
        #expect(!CardState.waitingForInput.isWorking)
    }

    @Test("a durable total overlay keeps card identity and clamps negative values")
    func durableTotalOverlay() {
        let card = BoardCard(
            sessionID: "idle", projectDir: "/tmp/p", agent: .claude,
            state: .idle
        )
        let restored = card.with(accumulatedWorkingTime: 3_600)
        #expect(restored.id == card.id)
        #expect(restored.accumulatedWorkingTime == 3_600)
        #expect(card.with(accumulatedWorkingTime: -1).accumulatedWorkingTime == 0)
    }
}
