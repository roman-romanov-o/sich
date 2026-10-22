import Foundation
import Testing
@testable import SichCore

/// The control-mode bridge against a REAL tmux server, end to end through a real
/// pty: the exact argv shape a POSIX remote card uses, minus ssh. What the pure
/// channel tests cannot prove — that the attach survives tmux's greeting block,
/// that `-CC` runs under the pty we give it, that the backfill lands in the local
/// emulator's scrollback (so the wheel and the ⌘↑/⌘↓ prompt jumps have something
/// to walk), that typed keys reach the pane and a resize reflows it.
///
/// Skips LOUDLY without tmux, like the session-env suite: a machine without tmux
/// must never let this pass silently.
@Suite("tmux control mode against a local server", .serialized)
struct TmuxControlLocalTests {

    /// A throwaway server on its own socket, so the developer's tmux is untouched.
    /// The socket is an absolute `-S` path: the pty-spawned client and the helper's
    /// `run` (which sets its own `TMUX_TMPDIR`) must land on the SAME server.
    private struct Server {
        let tmux: LocalTmux
        var socket: String {
            tmux.root.appendingPathComponent("cc-\(getpid())").path
        }

        func argv(script: String) -> [String] {
            [tmux.executable, "-CC", "-S", socket, "-f", "/dev/null",
             "new-session", "-A", "-D", "-s", "card", script]
        }

        /// A session that exists BEFORE any control client attaches — the restart
        /// case, where whatever runs in it already chose its terminal modes.
        func createDetached(script: String) -> Bool {
            tmux.run(["-S", socket, "-f", "/dev/null", "new-session", "-d",
                      "-s", "card", "-x", "100", "-y", "30", script]).status == 0
        }

        func kill() {
            _ = tmux.run(["-S", socket, "kill-server"])
            tmux.tearDown()
        }
    }

    private func pump(_ pty: PTYSession, until done: () -> Bool, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = pty.pumpAvailable()
            if done() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    private func screen(_ pty: PTYSession) -> String {
        (try? pty.terminal.plainText()) ?? ""
    }

    @Test("attach → backfill into local scrollback → typed keys → resize, like a local card")
    func controlModeRendersThePaneLocally() throws {
        guard let tmux = try LocalTmux.orSkip() else { return }
        let server = Server(tmux: tmux)
        defer { server.kill() }

        // 100 numbered lines, a claude-style prompt line, then a shell to type into.
        let pty = try PTYSession(
            command: server.argv(script: "seq 1 100; echo ❯ hello there; exec /bin/sh"),
            rows: 30, cols: 100)
        try pty.start()
        pty.setNonBlocking()
        defer { pty.terminate() }
        TmuxControlBridge.attach(to: pty, ownsTTYModes: false)

        let terminal = pty.terminal
        #expect(pump(pty, until: { screen(pty).contains("hello there") }, seconds: 10),
                "the capture-pane backfill never rendered — screen: \(screen(pty))")
        #expect(!terminal.alternateScreenActive, "data, not a tmux UI on the alt screen")
        #expect(terminal.scrollbackRows > 60,
                "history flows into LOCAL scrollback (\(terminal.scrollbackRows) rows)")
        let lines = try terminal.lines()
        let marks = TranscriptMarks.userPromptRows(
            in: lines, cursorRow: terminal.scrollbackRows + terminal.cursorRow)
        #expect(marks.count == 1, "the ❯ line is a prompt mark the ⌘↑ jump can reach: \(marks)")

        // Keystrokes reach the pane through `send`, and its echo comes back as %output.
        _ = pty.send(Array("echo typed-$((40+2))\r".utf8))
        #expect(pump(pty, until: { screen(pty).contains("typed-42") }, seconds: 10),
                "typed input did not round-trip — screen tail: \(screen(pty).suffix(200))")

        // A local resize reflows the far pane (refresh-client -C).
        pty.resize(rows: 20, cols: 60, cellWidthPx: 8, cellHeightPx: 16)
        _ = pump(pty, until: { false }, seconds: 0.5)
        _ = pty.send(Array("tput cols; tput lines\r".utf8))
        #expect(pump(pty, until: { screen(pty).contains("60\n20") }, seconds: 10),
                "the pane did not take the new size — screen tail: \(screen(pty).suffix(200))")
    }

    @Test("typed non-ASCII text reaches the pane as the characters typed")
    func typedUnicodeRoundTrips() throws {
        guard let tmux = try LocalTmux.orSkip() else { return }
        let server = Server(tmux: tmux)
        defer { server.kill() }
        let pty = try PTYSession(command: server.argv(script: "exec /bin/sh"), rows: 30, cols: 100)
        try pty.start()
        pty.setNonBlocking()
        defer { pty.terminate() }
        TmuxControlBridge.attach(to: pty, ownsTTYModes: false)
        #expect(pump(pty, until: { screen(pty).contains("$") }, seconds: 10),
                "the shell prompt never rendered — screen: \(screen(pty))")

        _ = pty.send(Array("echo typed-Привіт-🙂\r".utf8))
        #expect(pump(pty, until: { screen(pty).contains("typed-Привіт-🙂") }, seconds: 10),
                "Ukrainian did not survive the send — screen tail: \(screen(pty).suffix(200))")
    }

    @Test("attaching to a pane already on the alt screen with mouse tracking: the emulator learns both, and a wheel report reaches the pane")
    func attachLearnsModesSetBeforeTheAttach() throws {
        guard let tmux = try LocalTmux.orSkip() else { return }
        let server = Server(tmux: tmux)
        defer { server.kill() }
        // Claude Code's fullscreen renderer, reduced to its terminal footprint: alt
        // screen + any-motion SGR mouse, set long before this client shows up.
        try #require(server.createDetached(
            script: "printf '\\033[?1049h\\033[?1003h\\033[?1006h'; exec cat -v"))

        let pty = try PTYSession(command: server.argv(script: "exec /bin/sh"), rows: 30, cols: 100)
        try pty.start()
        pty.setNonBlocking()
        defer { pty.terminate() }
        TmuxControlBridge.attach(to: pty, ownsTTYModes: false)

        let terminal = pty.terminal
        #expect(pump(pty, until: { terminal.alternateScreenActive }, seconds: 10),
                "the alt screen set before the attach never reached the emulator")
        let geometry = Terminal.MouseGeometry(
            screenWidth: 800, screenHeight: 480, cellWidth: 8, cellHeight: 16, padding: 0)
        let wheel = terminal.encodeWheel(up: true, x: 10, y: 10, geometry: geometry)
        #expect(wheel != nil, "mouse tracking set before the attach never reached the emulator")

        // The surface forwards the wheel as the SGR report the pane asked for; `cat -v`
        // shows what the pane actually received.
        _ = pty.send(wheel ?? [])
        _ = pty.send([0x0A])
        #expect(pump(pty, until: { screen(pty).contains("^[[<64;") }, seconds: 10),
                "the wheel report did not reach the pane — screen tail: \(screen(pty).suffix(200))")
    }
}
