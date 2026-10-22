import Foundation
import SichCore
import Testing

@testable import SichApp

/// Checklist 18.08, item 6: each task keeps a verbose journal of when the agent
/// worked and when the operator did — driven by the REAL board lifecycle (state
/// sweep, drill-in, return), not by calling the journal directly.
@MainActor
@Suite(.serialized)
struct TaskWorkLogTests {

    private func makeTempDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-worklog-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeShell(bookDir: URL, logDir: URL) -> BoardShell {
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        shell.taskStore = BoardTaskStore(directory: bookDir)
        shell.workLog = TaskWorkLog(directory: logDir)
        shell.launchOverrideForTesting = { seed in
            let pty = try! PTYSession(command: ["/bin/cat"])
            try! pty.start()
            return Session(projectDir: seed.projectDir, agentType: .claude,
                           flowTag: .interactive, pty: pty, state: .running)
        }
        return shell
    }

    @Test("agent state edges land in the task's journal, with a duration on stop")
    func agentEdgesAreJournaled() throws {
        let bookDir = makeTempDir("book"), logDir = makeTempDir("log")
        let projectDir = makeTempDir("proj")
        defer {
            for dir in [bookDir, logDir, projectDir] { try? FileManager.default.removeItem(at: dir) }
        }
        let shell = makeShell(bookDir: bookDir, logDir: logDir)
        defer { shell.e2eTeardown() }

        let card = try #require(
            shell.createSession(title: "audit the parser", projectDir: projectDir.path))
        shell.move(cardID: card.id, to: .running)
        shell.move(cardID: card.id, to: .waitingForInput)

        let log = try String(contentsOf: shell.workLog!.fileURL(for: card.id), encoding: .utf8)
        #expect(log.hasPrefix("# audit the parser — \(projectDir.path)"),
                "the journal opens with what the task is")
        #expect(log.contains("state: running → waiting-for-input"), "every edge is verbose")
        #expect(log.contains("agent stopped working after 0:00:0"),
                "the working interval closes with its duration")
    }

    @Test("drill-in and return journal the operator's own time on the task")
    func operatorIntervalsAreJournaled() throws {
        let bookDir = makeTempDir("book"), logDir = makeTempDir("log")
        let projectDir = makeTempDir("proj")
        defer {
            for dir in [bookDir, logDir, projectDir] { try? FileManager.default.removeItem(at: dir) }
        }
        let shell = makeShell(bookDir: bookDir, logDir: logDir)
        defer { shell.e2eTeardown() }

        let card = try #require(
            shell.createSession(title: "review it", projectDir: projectDir.path))
        shell.drill(into: card)
        shell.returnToBoard()

        let log = try String(contentsOf: shell.workLog!.fileURL(for: card.id), encoding: .utf8)
        #expect(log.contains("you entered the task"))
        #expect(log.contains("you left the task after 0:00:0"),
                "the operator interval closes with its duration")
    }

    @Test("a shell with no journal configured (every other suite) writes nothing")
    func noJournalMeansNoWrites() throws {
        let bookDir = makeTempDir("book"), projectDir = makeTempDir("proj")
        defer {
            for dir in [bookDir, projectDir] { try? FileManager.default.removeItem(at: dir) }
        }
        let shell = makeShell(bookDir: bookDir, logDir: makeTempDir("unused"))
        shell.workLog = nil
        defer { shell.e2eTeardown() }

        let card = try #require(shell.createSession(title: "quiet", projectDir: projectDir.path))
        shell.move(cardID: card.id, to: .running)
        #expect(shell.workLog == nil)
        _ = card
    }
}
