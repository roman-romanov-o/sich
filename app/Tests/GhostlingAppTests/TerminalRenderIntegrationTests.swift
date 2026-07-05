import AppKit
import GhostlingCore
import Testing

@testable import GhostlingApp

/// The complaint that matters most: "real terminal is not opening." Every prior
/// test stubbed the PTY with a self-terminating command (`/bin/echo`, `cat`), so
/// the GUI read loop was never proven against a **real interactive login shell**.
/// This drives the EXACT path a drill-in uses — `TerminalSurface.startReading()`
/// on a `$SHELL -il` PTY, serviced by a spun main run loop — and asserts the
/// surface actually renders the shell's prompt. If this is empty, the user sees a
/// black rectangle: the terminal "didn't open."
@MainActor
struct TerminalRenderIntegrationTests {
    /// Pump the real read loop for up to `seconds`, returning the rendered screen
    /// once it is non-empty (the prompt arrived) or the budget runs out.
    private func renderedText(of session: Session, within seconds: Double) -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if let text = try? session.pty.terminal.plainText(),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return (try? session.pty.terminal.plainText()) ?? ""
    }

    @Test func liveShellRendersAPromptThroughTheSurfaceReadLoop() throws {
        let registry = SessionRegistry()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let session = try registry.launch(
            command: [shell, "-il"], projectDir: ".", agentType: .shell
        )
        let surface = TerminalSurface(session: session.pty)
        surface.startReading()   // the same call DrillInPanel.focus makes
        defer { surface.stopReading(); session.pty.terminate() }

        let text = renderedText(of: session, within: 3.0)
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func typedInputIsEchoedBackIntoTheRenderedScreen() throws {
        let registry = SessionRegistry()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let session = try registry.launch(
            command: [shell, "-il"], projectDir: ".", agentType: .shell
        )
        let surface = TerminalSurface(session: session.pty)
        surface.startReading()
        defer { surface.stopReading(); session.pty.terminate() }

        _ = renderedText(of: session, within: 3.0)            // wait for the prompt
        session.pty.send(Array("echo GHOSTLING_OK\n".utf8))   // the keystroke path
        let text = renderedText(of: session, within: 3.0)
        #expect(text.contains("GHOSTLING_OK"))
    }
}
