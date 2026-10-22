import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// The user's report, end to end: a LOCAL Claude card, long output, the window
/// gets smaller (both dimensions — the everyday drill-in resize), then a trackpad
/// swipe up. Before the fix the whole history came back blank and the viewport
/// could not reach the first lines. Real `claude` typed into a real PTY under a
/// real `TerminalSurface`; wheel events are genuine CG events. Never `claude -p`.
///
/// Opt in with `SICH_REAL_AGENT_E2E=1` (needs the claude shim on PATH); ~1–3 min.
private let realAgentOptedIn = ProcessInfo.processInfo.environment["SICH_REAL_AGENT_E2E"] == "1"

@MainActor
struct TerminalScrollbackRealAgentE2ETests {
    private static let prompt =
        "Write 150 numbered one-line facts about Unix and Linux, each on its own line, "
        + "no tools, no headings, do not stop early. End with exactly: FACTS_DONE"

    private func viewportRows(_ pty: PTYSession) -> [String] {
        let grid = pty.terminal.snapshot()
        return (0..<grid.rows).map { row in
            String(String.UnicodeScalarView(
                (0..<grid.cols).compactMap { grid.cells[row * grid.cols + $0].scalar }
            )).trimmingCharacters(in: .whitespaces)
        }
    }

    private func wheelEvent(lines: Int32) throws -> NSEvent {
        let backing = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
            wheel1: lines, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: backing))
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Wait until the child has been silent for a while and the answer's sentinel
    /// is on screen twice (prompt echo + the answer itself).
    private func awaitAnswer(_ pty: PTYSession, bytesSeen: () -> Int) throws {
        let deadline = Date().addingTimeInterval(600)
        var lastSeen = -1, quiet = 0
        while Date() < deadline {
            pump(0.1)
            let seen = bytesSeen()
            if seen == lastSeen { quiet += 1 } else { quiet = 0; lastSeen = seen }
            let text = (try? pty.terminal.plainText()) ?? ""
            if quiet > 40, text.components(separatedBy: "FACTS_DONE").count >= 3 { return }
        }
        Issue.record("claude did not finish the 150 facts within 10 minutes")
    }

    @Test(.enabled(if: realAgentOptedIn))
    func shrinkingTheWindowThenSwipingUpShowsTheWholeHistory() throws {
        let pty = try PTYSession(
            command: ["/bin/zsh", "-lc", "unset CLAUDE_CODE_CHILD_SESSION; claude '\(Self.prompt)'"],
            rows: 40, cols: 120)
        var bytes = 0
        pty.onOutput = { bytes += $0.count }
        try pty.start()
        pty.setNonBlocking()
        let surface = TerminalSurface(session: pty)
        surface.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)   // big drill-in
        surface.startReading()
        defer { pty.send(Array("/exit\r".utf8)); surface.stopReading(); pty.terminate() }

        try awaitAnswer(pty, bytesSeen: { bytes })
        let history = pty.terminal.scrollbackRows
        #expect(history > 100, "150 facts must leave real history, got \(history)")

        // The everyday case: the surface gets smaller in BOTH dimensions.
        surface.setFrameSize(NSSize(width: 900, height: 500))
        pump(1.0)                                   // let claude redraw after SIGWINCH
        #expect(pty.terminal.scrollbackRows < 20_000, "resize invented history: \(pty.terminal.scrollbackRows)")

        // Swipe up, step by step, all the way to the top: every stop must show text.
        var sawFirstFact = false
        var blankStops = 0
        var previous: [String]?
        var stops = 0
        for _ in 0..<400 {
            surface.scrollWheel(with: try wheelEvent(lines: 6))
            pump(0.15)
            let rows = viewportRows(pty)
            let nonBlank = rows.filter { !$0.isEmpty }.count
            if nonBlank < rows.count / 3 { blankStops += 1 }
            // Claude prefixes its first answer line with the ⏺ turn marker.
            if rows.contains(where: { $0.drop(while: { !$0.isNumber }).hasPrefix("1.") }) { sawFirstFact = true }
            stops += 1
            if rows == previous { break }   // the viewport stopped moving: top of history
            previous = rows
        }
        #expect(blankStops == 0, "\(blankStops) viewport stops were mostly blank")
        let top = viewportRows(pty).joined(separator: "\n")
        #expect(sawFirstFact, Comment(rawValue: "never reached fact 1 after \(stops) stops; top viewport:\n\(top)"))

        // And typing a (harmless) space snaps back to the live prompt, badge gone.
        let space = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        surface.keyDown(with: space)
        pump(0.3)
        #expect(!surface.isViewingScrollback)
    }
}
