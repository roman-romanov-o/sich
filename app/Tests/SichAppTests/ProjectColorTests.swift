import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// Checklist 18.08, items 4+5: a project's chip colour is consistent BETWEEN runs
/// (the slot map persists, so relaunch order can't re-roll hues), and the same
/// project on another machine — linked by the trailing name of its directory —
/// wears the same colour as the local checkout.
@MainActor
@Suite(.serialized)
struct ProjectColorTests {

    /// A throwaway defaults suite per test, restored to `.standard` afterwards.
    private func withFreshDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "sich-color-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        BoardTheme.repoColorDefaults = defaults
        defer {
            BoardTheme.repoColorDefaults = .standard
            defaults.removePersistentDomain(forName: name)
        }
        try body(defaults)
    }

    @Test("a project's colour survives a relaunch even when discovery order flips")
    func colorIsStableAcrossRuns() throws {
        try withFreshDefaults { defaults in
            // First run discovers alpha, then beta.
            let alpha1 = BoardTheme.repoColor("/Users/x/alpha")
            let beta1 = BoardTheme.repoColor("/Users/x/beta")
            #expect(alpha1 != beta1)

            // "Relaunch": the in-memory map is dropped; only the persisted one
            // remains. The next run happens to see beta first.
            BoardTheme.repoColorDefaults = defaults
            let beta2 = BoardTheme.repoColor("/Users/x/beta")
            let alpha2 = BoardTheme.repoColor("/Users/x/alpha")

            #expect(alpha2 == alpha1, "alpha keeps its hue across runs")
            #expect(beta2 == beta1, "beta keeps its hue across runs")
        }
    }

    @Test("a remote card links to the local project by the trailing directory name")
    func remoteCardWearsTheLocalProjectColor() throws {
        try withFreshDefaults { _ in
            let shell = BoardShell(seeds: [])
            _ = shell.buildContentForTesting()
            defer { shell.e2eTeardown() }

            let localColor = BoardTheme.repoColor("/Users/x/my-app")
            let spec = RemoteTmuxSpec(host: "studio.invalid", user: "roman",
                                      sessionName: "agent",
                                      remoteDir: "/home/roman/work/my-app")
            let card = try #require(shell.createRemoteTmuxSession(spec: spec))

            #expect(card.projectDir == "roman@studio.invalid",
                    "the label stays the host anchor")
            #expect(BoardTheme.repoColor(for: card) == localColor,
                    "…but the hue is the project's, linked by the dir's trailing name")
        }
    }

    @Test("a remote card with no start dir keeps its host-label hue")
    func remoteCardWithoutDirFallsBackToHostColor() throws {
        try withFreshDefaults { _ in
            let shell = BoardShell(seeds: [])
            _ = shell.buildContentForTesting()
            defer { shell.e2eTeardown() }

            let spec = RemoteTmuxSpec(host: "bare.invalid", sessionName: "agent")
            let card = try #require(shell.createRemoteTmuxSession(spec: spec))

            #expect(BoardTheme.repoColor(for: card) == BoardTheme.repoColor("bare.invalid"))
        }
    }

    @Test("a task-book restore re-links the remote card's project colour")
    func restoredRemoteCardKeepsTheProjectLink() throws {
        try withFreshDefaults { _ in
            let bookDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sich-color-book-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: bookDir) }

            // Run 1: a remote card with a start dir is created and persisted.
            let first = BoardShell(seeds: [])
            _ = first.buildContentForTesting()
            first.taskStore = BoardTaskStore(directory: bookDir)
            let spec = RemoteTmuxSpec(host: "studio.invalid", sessionName: "agent",
                                      remoteDir: "~/work/my-app")
            let card = try #require(first.createRemoteTmuxSession(spec: spec))
            let liveColor = BoardTheme.repoColor(for: card)
            first.e2eTeardown()

            // Run 2: the board comes back from the task book alone.
            let second = BoardShell(seeds: [])
            _ = second.buildContentForTesting()
            second.taskStore = BoardTaskStore(directory: bookDir)
            let snapDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sich-color-snap-\(UUID().uuidString)", isDirectory: true)
            second.hydrateForTesting(sessionStore: SessionSnapshotStore(directory: snapDir))
            defer { second.e2eTeardown() }

            let restored = try #require(second.cards.first { $0.id == card.id })
            #expect(BoardTheme.repoColor(for: restored) == liveColor)
            #expect(liveColor == BoardTheme.repoColor("/Users/x/my-app"),
                    "the link is by trailing dir name, machine-independent")
        }
    }
}
