import Foundation
import SichCore
import Testing

@testable import SichApp

@MainActor
@Suite(.serialized)
struct NeedsYouStandupAppTests {

    @Test("defer moves the card to queue and persists snooze until tomorrow")
    func deferToTomorrow() throws {
        let bookDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-standup-\(UUID().uuidString)", isDirectory: true)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-standup-wt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: bookDir)
            try? FileManager.default.removeItem(at: work)
        }

        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        shell.taskStore = BoardTaskStore(directory: bookDir)
        shell.launchOverrideForTesting = { seed in
            let pty = try! PTYSession(command: ["/bin/cat"])
            try! pty.start()
            return Session(projectDir: seed.projectDir, agentType: .claude,
                           pty: pty, state: .running)
        }
        defer { shell.e2eTeardown() }

        let card = try #require(
            shell.createSession(title: "Stale ask", projectDir: work.path))
        shell.move(cardID: card.id, to: .waitingForInput)
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        shell.deferNeedsYouToTomorrow(cardID: card.id, now: fixedNow)

        #expect(shell.cards.first { $0.id == card.id }?.state == .parked)
        let until = try #require(shell.taskMetaForTesting(card.id)?.needsYouDeferredUntil)
        #expect(until == NeedsYouStandup.defaultDeferUntil(from: fixedNow))

        let record = try #require(
            BoardTaskStore(directory: bookDir).load()?.tasks.first { $0.id == card.id })
        #expect(record.placement == .board(.parked))
        #expect(record.needsYouDeferredUntil == until)
    }
}
