import Foundation
import SichCore
import Testing

@testable import SichApp

/// The "blank Cursor/Gemini terminal" regression. libghostty erases every row from the
/// prompt-start row (OSC 133;A) to the bottom of the screen on resize — the shell is
/// expected to redraw its prompt. A prompt that is never closed by 133;C therefore turns
/// a whole running TUI into "prompt", and the first resize of the drill-in surface
/// wipes it. Claude Code repaints its frame and hides that; Ink-style TUIs (Cursor,
/// Gemini) never repaint, so the screen stays blank until the user types.
///
/// Runs the REAL bundled integration inside a real interactive zsh on a pty, resizes
/// the emulator the way `TerminalSurface.syncTerminalSize` does, and asserts the command
/// output survives.
@Suite(.serialized)
struct ShellIntegrationResizeTests {
    private static let st = "\u{1B}\\"

    @Test("command output written after the prompt survives an emulator resize")
    func commandOutputSurvivesResize() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-shellint-resize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("ghostty-integration.zsh")
        try ShellIntegrationInstaller.integrationScript.write(
            to: script, atomically: true, encoding: .utf8)

        // `-f` skips the operator's rc files: only the bundled integration runs.
        let session = try PTYSession(command: ["/bin/zsh", "-f", "-i"], rows: 40, cols: 120)
        try session.start()
        defer { session.terminate() }
        session.setNonBlocking()
        var stream: [UInt8] = []
        session.onOutput = { stream += $0 }

        try drain(session, until: { $0.contains("%") || $0.contains("$") })
        session.send(Array("source '\(script.path)'\n".utf8))
        try drain(session, until: { _ in
            String(decoding: stream, as: UTF8.self).contains("\u{1B}]133;A\(Self.st)")
        })
        session.send(Array("for i in {1..10}; do echo \"hello world $i\"; done; read -k 1\n".utf8))
        try drain(session, until: { $0.contains("hello world 10") })

        let text = String(decoding: stream, as: UTF8.self)
        #expect(text.contains("\u{1B}]133;C\(Self.st)"),
                "preexec must open the command region (133;C)")

        // The drill-in surface's first sync: one column wider, the way any window
        // or font change lands on the emulator.
        session.resize(rows: 40, cols: 121, cellWidthPx: 10, cellHeightPx: 20)
        try drain(session, until: { _ in false }, timeout: 0.5)   // nothing redraws: the TUI is "running"
        let after = try session.terminal.lines()
        #expect(after.contains { $0.contains("hello world 10") },
                "resize erased the command output — the prompt region was never closed")
        session.send([0x0A])
    }

    /// Pump the pty on the calling thread until `until` is true for the current screen
    /// text, or `timeout` elapses (when `until` never fires the timeout is the wait).
    private func drain(
        _ session: PTYSession,
        until condition: (String) -> Bool,
        timeout: TimeInterval = 10
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            _ = session.pumpAvailable()
            if condition((try? session.terminal.plainText()) ?? "") { return }
            usleep(20_000)
        }
        if timeout >= 10 {
            Issue.record("timed out waiting for the shell; screen:\n\((try? session.terminal.plainText()) ?? "")")
        }
    }
}
