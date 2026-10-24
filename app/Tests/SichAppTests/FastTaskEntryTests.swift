import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// Checklist 18.08, item 8 ("faster entering the task"): the felt delay was the
/// geometry jump — every session spawned at the pty default 24×80, so the first
/// drill-in forced a big resize and the child reflowed while the operator waited.
/// These tests pin the fix: the drill-in surface teaches its settled grid, and
/// every spawn is born already that shape, so entering is a no-op resize.
@MainActor
@Suite(.serialized)
struct FastTaskEntryTests {

    /// Run `body` against a throwaway defaults suite so tests never read or pollute
    /// the operator's real geometry — the ProjectColorTests idiom.
    private func withFreshDefaults(_ body: () throws -> Void) rethrows {
        let name = "sich-geometry-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        TerminalGeometry.defaults = defaults
        defer {
            TerminalGeometry.defaults = .standard
            defaults.removePersistentDomain(forName: name)
        }
        try body()
    }

    @Test("remembered geometry round-trips; nothing remembered falls back to 24×80")
    func rememberRoundTrip() throws {
        try withFreshDefaults {
            #expect(TerminalGeometry.preferred == TerminalGeometry.fallback,
                    "a fresh board prefers the classic pty default")
            TerminalGeometry.remember(rows: 47, cols: 172)
            #expect(TerminalGeometry.preferred == (47, 172))
            TerminalGeometry.remember(rows: 48, cols: 173)
            #expect(TerminalGeometry.preferred == (48, 173), "the LAST settled grid wins")
        }
    }

    @Test("garbage in the store never becomes a spawn size")
    func garbageFallsBack() throws {
        try withFreshDefaults {
            TerminalGeometry.remember(rows: 0, cols: 100)
            #expect(TerminalGeometry.preferred == TerminalGeometry.fallback,
                    "zero rows are refused at write time")
            TerminalGeometry.defaults.set(["rows": 99999, "cols": 80],
                                          forKey: "sich.terminalGeometry")
            #expect(TerminalGeometry.preferred == TerminalGeometry.fallback,
                    "an absurd persisted size is refused at read time")
            TerminalGeometry.defaults.set("not a dict", forKey: "sich.terminalGeometry")
            #expect(TerminalGeometry.preferred == TerminalGeometry.fallback)
        }
    }

    @Test("a board spawn is born at the remembered drill-in grid — entering is a no-op resize")
    func spawnAdoptsTheRememberedGrid() throws {
        try withFreshDefaults {
            TerminalGeometry.remember(rows: 41, cols: 137)
            let seed = BoardSeed(
                sessionID: "fast-entry", projectDir: "/tmp/fast-entry-proj",
                agent: .claude, state: .running, scrollback: "",
                commandOverride: ["/bin/cat"]
            )
            // No launch override: the seed goes through the REAL launch path —
            // BoardShell.launch(seed:) → registry.launch → PTYSession — the exact
            // chain a ⌘N card takes in production.
            let shell = BoardShell(seeds: [seed])
            _ = shell.buildContentForTesting()
            defer { shell.e2eTeardown() }
            let card = try #require(shell.cards.first { $0.sessionID == "fast-entry" })
            let pty = try #require(shell.ptyForTesting(card.id))
            #expect(pty.rows == 41 && pty.cols == 137,
                    "the child starts life drill-in-sized — no first-entry reflow")
        }
    }

    @Test("a teaching surface remembers the grid its layout settles on")
    func drillInSurfaceTeaches() throws {
        try withFreshDefaults {
            let pty = try PTYSession(command: ["/bin/cat"])
            try pty.start()
            defer { pty.terminate() }
            let surface = TerminalSurface(session: pty, fontSize: 20)
            surface.teachesGeometry = true
            surface.setFrameSize(NSSize(width: 640, height: 480))
            let taught = TerminalGeometry.preferred
            #expect(taught == (pty.rows, pty.cols),
                    "the remembered grid IS the grid the surface pushed to the pty")
            #expect(taught != TerminalGeometry.fallback,
                    "640×480 at 20pt is not the 24×80 default — something real was taught")
        }
    }

    @Test("a non-teaching surface (tests) never touches the memory")
    func mutePaneDoesNotTeach() throws {
        try withFreshDefaults {
            let pty = try PTYSession(command: ["/bin/cat"])
            try pty.start()
            defer { pty.terminate() }
            let surface = TerminalSurface(session: pty, fontSize: 20)
            surface.setFrameSize(NSSize(width: 640, height: 480))
            #expect(TerminalGeometry.preferred == TerminalGeometry.fallback,
                    "only the production drill-in teaches; every other surface is mute")
        }
    }
}
