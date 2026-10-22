import Foundation
import Testing

@testable import SichApp
@testable import SichCore

/// What happens when the FAR SIDE loses the tmux session — the reboot, the OOM sweep,
/// the killed tmux server. `-A` makes that case look exactly like a resume: it creates
/// the session and attaches, so the card came back as a bare login shell at `$HOME`
/// with the operator's conversation stranded and no error anywhere to say so.
///
/// The rule these tests pin: ASK the far side first. A definite "the session is gone"
/// rebuilds the context we know about — on the session's own launch command, which
/// only the CREATE branch of `-A` runs; anything else — a live session, an unreachable
/// host, a silent one — is left strictly alone, and nothing is ever typed into the
/// attach: the control-mode handshake would read keystrokes as protocol commands.
///
/// No case dials a host: the probe runs through the injected runner and the reserved
/// `.invalid` TLD fails its lookup immediately.
@MainActor
@Suite(.serialized)
struct RemoteSessionLostTests {

    private let spec = RemoteTmuxSpec(
        host: "host.invalid", user: "roman", sessionName: "agent",
        remoteDir: "~/MyProjects/spectre")

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-session-lost-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A board whose card comes from the task book, whose spawns are stubbed to a
    /// `/bin/cat` pty that records everything typed into it, and whose far side answers
    /// the session probe with `probeOutput`.
    private func makeShell(
        bookDir: URL, record: TaskRecord, probeOutput: String?, typed: Revival
    ) throws -> BoardShell {
        _ = try BoardTaskStore(directory: bookDir).save(tasks: [record])
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        shell.taskStore = BoardTaskStore(directory: bookDir)
        shell.remoteSessionRunner = ProbeStub(output: probeOutput)
        shell.launchOverrideForTesting = { seed in
            let pty = try! PTYSession(command: ["/bin/cat"])
            try! pty.start()
            pty.onInput = { bytes in
                MainActor.assumeIsolated { typed.text += String(decoding: bytes, as: UTF8.self) }
            }
            let session = Session(projectDir: seed.projectDir, agentType: .claude,
                                  flowTag: .interactive, pty: pty, state: .running)
            MainActor.assumeIsolated {
                typed.argv = seed.command
                typed.session = session
            }
            return session
        }
        shell.hydrateForTesting(sessionStore: SessionSnapshotStore(directory: makeTempDir()))
        return shell
    }

    private func remoteRecord(sessionRef: TaskSessionRef? = nil) -> TaskRecord {
        TaskRecord(
            title: "far work", placement: .board(.idle), agent: "claude",
            mode: .interactive, projectDir: spec.target, sessionRef: sessionRef,
            remote: RemoteSpecSnapshot(spec: spec))
    }

    // MARK: - the far side lost the session

    @Test("a session the far side lost comes back on the SAME conversation, in the last dir")
    func lostSessionResumesTheConversation() throws {
        let bookDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: bookDir) }
        let resumeID = UUID()
        let typed = Revival()
        let shell = try makeShell(
            bookDir: bookDir,
            record: remoteRecord(sessionRef: TaskSessionRef(
                claudeSessionID: resumeID, lastCwd: "/home/roman/MyProjects/spectre")),
            probeOutput: RemoteTmuxCommand.noSessionMarker, typed: typed)
        defer { shell.e2eTeardown() }

        let card = try #require(shell.cards.first)
        shell.drill(into: card)

        // The conversation, not a bare prompt — and interactive, never `claude -p`.
        let remote = try #require(typed.argv.last)
        #expect(remote.contains("claude --resume \(resumeID.uuidString.lowercased())"))
        #expect(!remote.contains("claude -p"))
        #expect(typed.text.isEmpty, "the rebuild rides the argv, nothing is typed")
        // And in the directory the operator was last seen in, not $HOME (and not the
        // `~` the card was created with, which tmux silently drops). tmux honours `-c`
        // only on the session it CREATES, which is precisely this case.
        #expect(try #require(typed.argv.last)
            .contains("-c '/home/roman/MyProjects/spectre'"))
    }

    @Test("a lost session with no known conversation is pinned to a fresh one")
    func lostSessionWithoutHistoryPinsAFreshConversation() throws {
        let bookDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: bookDir) }
        let typed = Revival()
        let shell = try makeShell(
            bookDir: bookDir, record: remoteRecord(),
            probeOutput: RemoteTmuxCommand.noSessionMarker, typed: typed)
        defer { shell.e2eTeardown() }

        let card = try #require(shell.cards.first)
        shell.drill(into: card)

        // Pinned, not bare: the id is ours up front, so the NEXT time the far side
        // drops this session there is something to resume.
        let pinned = try #require(typed.session?.claudeSessionID)
        let remote = try #require(typed.argv.last)
        #expect(remote.contains("claude --session-id \(pinned.uuidString.lowercased())"))
        #expect(!remote.contains("claude -p"))
        #expect(typed.text.isEmpty)
    }

    // MARK: - learning what only the far side knows

    @Test("a bound hook line teaches the card its conversation and far-side dir — and a dropped link keeps them")
    func farSideFactsSurviveTheLink() throws {
        let bookDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: bookDir) }
        let typed = Revival()
        let shell = try makeShell(
            bookDir: bookDir, record: remoteRecord(),
            probeOutput: RemoteTmuxCommand.noSessionMarker, typed: typed)
        defer { shell.e2eTeardown() }

        // The REAL spawn path: ssh to the reserved `.invalid` TLD fails its lookup and
        // exits — which is exactly what a dropped link looks like to the reconcile loop.
        // A stubbed `/bin/cat` cannot stand in here: `terminate()` reaps its own child,
        // so the death never reaches `reconcile`.
        shell.launchOverrideForTesting = nil
        let card = try #require(shell.cards.first)
        shell.drill(into: card)
        shell.returnToBoard()

        // One hook line comes back from the far side. Nothing else in the app knows
        // these two facts: the operator ran `claude` themselves, in a directory they
        // chose, on a machine we only watch.
        let conversation = UUID()
        shell.applySessions([BoardCard(
            sessionID: conversation.uuidString,
            projectDir: "/home/roman/MyProjects/spectre",
            agent: .claude, flow: .b, state: .running,
            updatedAt: Date(), boundCardID: card.id.uuidString, host: "host.invalid")])

        // The link is already gone; the reconcile pass is where the card learns it —
        // and the moment the hints used to be discarded, because `sessionRef` has
        // nothing to join once the session leaves the registry.
        for _ in 0..<500 {
            if !shell.reconcileDeadSessions().isEmpty { break }
            usleep(10_000)
        }
        #expect(shell.ptyForTesting(card.id) == nil, "the link really did drop")

        let record = try #require(
            BoardTaskStore(directory: bookDir).load()?.tasks.first { $0.id == card.id })
        #expect(record.sessionRef?.claudeSessionID == conversation)
        #expect(record.sessionRef?.lastCwd == "/home/roman/MyProjects/spectre")
        // The card is still on the board, idle, holding everything a revival needs.
        #expect(shell.cards.contains { $0.id == card.id })
    }

    // MARK: - every other answer leaves the far side alone

    @Test("a session that is still alive gets no start command and is never typed into")
    func liveSessionIsLeftAlone() throws {
        let bookDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: bookDir) }
        let typed = Revival()
        let record = remoteRecord(sessionRef: TaskSessionRef(claudeSessionID: UUID()))
        // The far side reports OUR binding: tmux kept the session, and whatever is
        // running in it must not be talked over.
        let shell = try makeShell(
            bookDir: bookDir, record: record,
            probeOutput: "SICH_CARD_ID=\(record.id.uuidString)", typed: typed)
        defer { shell.e2eTeardown() }

        shell.drill(into: try #require(shell.cards.first))

        #expect(typed.text.isEmpty, "a pure re-attach types nothing: \(typed.text)")
        #expect(!(try #require(typed.argv.last)).contains("claude"),
                "a pure re-attach carries no agent start either")
    }

    @Test("an unreachable host is not a lost session")
    func silenceIsNotALostSession() throws {
        let bookDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: bookDir) }
        let typed = Revival()
        // The probe itself failed — the far side said nothing at all. Guessing "gone"
        // here would type a resume into a session that is very likely still running.
        let shell = try makeShell(
            bookDir: bookDir,
            record: remoteRecord(sessionRef: TaskSessionRef(claudeSessionID: UUID())),
            probeOutput: nil, typed: typed)
        defer { shell.e2eTeardown() }

        shell.drill(into: try #require(shell.cards.first))

        #expect(typed.text.isEmpty, "silence must not fabricate a create: \(typed.text)")
    }
}

/// What a revival actually did: the argv it attached with, the session it produced,
/// and every byte typed into the revived pane.
@MainActor
final class Revival {
    var text = ""
    var argv: [String] = []
    var session: Session?
}

/// A far side that answers the session probe without any ssh; `nil` output is a probe
/// that failed outright (unreachable host, no tmux, spawning disabled).
private struct ProbeStub: RemoteCommandRunner {
    let output: String?

    func run(argv: [String], input: Data?) -> RemoteCommandResult? {
        guard let output else { return nil }
        return RemoteCommandResult(exitCode: 0, standardOutput: Data(output.utf8))
    }
}
