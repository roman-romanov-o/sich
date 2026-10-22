import Foundation

/// The tmux control-mode (`-CC`) wire protocol as a pure state machine: raw ssh
/// bytes in, pane bytes for the emulator out, protocol commands for the child via
/// a callback. No fd, no process — fully unit-testable. tmux (POSIX hosts) and
/// psmux (Windows hosts) speak the same protocol, so one channel serves both.
///
/// Why this exists (the remote scroll fix): attached full-screen, tmux repaints
/// its own alt-screen UI, so the local emulator never accumulates scrollback: the
/// wheel falls back to arrow-key synthesis that rewinds claude's input history,
/// and the prompt jumps (⌘↑/⌘↓) have no transcript to walk. In control mode the
/// server sends the pane's output as data (`%output` lines) instead of drawing a
/// UI, so Sich renders it into its **normal** buffer — local scrollback, the
/// smooth wheel, the prompt marks, exactly like a local card — while the session
/// still survives disconnects on the far side.
///
/// Two phases, split by the DCS opener `ESC P 1000 p` the server emits once attached:
///  * **passthrough** — everything before the opener renders verbatim. This is
///    ssh's interactive auth: the password prompt must reach the screen and the
///    typed password must reach ssh untouched (the no-key-install constraint).
///  * **attached** — line-oriented protocol. `%begin/%end` response blocks are
///    correlated FIFO with the commands we sent (blocks never interleave); the
///    block's flags field tells a reply (`1`) from the server's own greeting
///    (`0`), which tmux emits right behind the opener and must dequeue nothing.
///    `%output` notifications carry the pane bytes, octal-escaped.
///
/// On attach the channel bootstraps: sizes the viewport (`refresh-client -C`),
/// binds the first pane (`list-panes`), replays the pane's terminal MODES
/// (`display-message`), then backfills history + screen with one `capture-pane`.
/// Live `%output` is DROPPED until that backfill lands — any output the server
/// sent before the capture is already inside the capture, so rendering both would
/// double-print. One rule covers fresh create and re-attach.
///
/// The mode replay is what a mid-session attach needs: a program that switched to
/// the alternate screen or enabled mouse tracking BEFORE we attached (Claude Code's
/// fullscreen renderer, vim) did so in bytes this client never saw. Without them
/// the local emulator believes it owns the scrollback, the wheel moves an empty
/// viewport, and the program never receives the mouse reports it asked for.
final class TmuxControlChannel {
    /// Writes protocol command bytes to the child (the ssh stdin). Must bypass
    /// input interception — commands are already wire-shaped.
    var sendToChild: (([UInt8]) -> Void)?
    /// Fired once when the opener is seen — the Windows wiring switches the local
    /// pty to raw mode here, because under `ssh -T` nothing else owns the line
    /// discipline and a cooked one echoes master-side writes back into master
    /// reads, corrupting the protocol parse.
    var onAttached: (() -> Void)?

    private(set) var isAttached = false
    private(set) var isExited = false
    /// The single pane this card renders and types into (`%N`). Cards are
    /// one-pane by construction; extra windows a far-side operator opens are
    /// simply not rendered.
    private(set) var boundPane: String?

    private var cols: Int
    private var rows: Int
    /// Passthrough bytes held back because they end in a proper prefix of the
    /// opener — the opener can straddle a read boundary.
    private var carry: [UInt8] = []
    /// Attached-phase partial line awaiting its newline.
    private var lineBuffer: [UInt8] = []

    /// What each in-flight command's response should do when its block closes.
    private enum Purpose { case ignore, bindPane, paneModes, backfill }
    private var pendingPurposes: [Purpose] = []
    private var responsePurpose: Purpose = .ignore
    /// Non-nil while inside a `%begin` block; collects raw content lines.
    private var responseLines: [[UInt8]]?
    /// Set when the first `capture-pane` backfill has rendered; gates `%output`.
    private var backfilled = false
    /// Programmatic input (an agent start, a login) handed over before a pane is
    /// bound, delivered the moment one is. Typed before attach it would reach the
    /// far side as protocol commands, not keystrokes — so it is never passed through.
    private var inputAwaitingPane: [UInt8] = []

    private static let opener: [UInt8] = Array("\u{1B}P1000p".utf8)
    /// History depth replayed into local scrollback on attach.
    private static let backfillLines = 1000
    /// The pane's DEC/ANSI modes as tmux tracks them, in ``modeSequences``'s order.
    /// Only set-when-1 modes: a server that prints zeros for unknown flags then
    /// replays nothing rather than hiding the cursor or disabling wrap.
    private static let modeFormat = [
        "alternate_on", "mouse_standard_flag", "mouse_button_flag", "mouse_all_flag",
        "mouse_sgr_flag", "mouse_utf8_flag", "keypad_cursor_flag", "keypad_flag",
        "origin_flag", "insert_flag",
    ].map { "#{\($0)}" }.joined(separator: " ")
    private static let modeSetSequences = [
        "\u{1B}[?1049h", "\u{1B}[?1000h", "\u{1B}[?1002h", "\u{1B}[?1003h",
        "\u{1B}[?1006h", "\u{1B}[?1005h", "\u{1B}[?1h", "\u{1B}=",
        "\u{1B}[?6h", "\u{1B}[4h",
    ]

    init(cols: Int, rows: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
    }

    /// Feed raw bytes read from the pty; returns the bytes the emulator should
    /// render (passthrough text, backfill replay, decoded pane output).
    func ingest(_ raw: [UInt8]) -> [UInt8] {
        guard !raw.isEmpty, !isExited else { return [] }
        return isAttached ? ingestProtocol(raw) : ingestPassthrough(raw)
    }

    /// Transform keystrokes into wire bytes. Before attach this is the identity —
    /// the password must reach ssh exactly as typed. After attach the input goes
    /// as one hex-code-point `send` command, which the server coalesces into one
    /// PTY write so multi-byte keys (arrows) arrive atomically. With no pane bound
    /// yet (the ~one bootstrap round-trip) keystrokes are dropped, not queued.
    func encode(input: [UInt8]) -> [UInt8] {
        guard isAttached else { return input }
        guard !isExited, !input.isEmpty, let boundPane else { return [] }
        pendingPurposes.append(.ignore)
        return Array("send -t \(boundPane) \(Self.hexKeys(input))\n".utf8)
    }

    /// `send-keys 0xNN` names a Unicode CODE POINT, not a byte — tmux runs it
    /// through `wctomb` on the server — so UTF-8 input is sent per scalar: per
    /// byte, "П" (D0 9F) reaches the pane as "Ð" plus a control character. A byte
    /// that does not start a valid sequence is sent as itself.
    static func hexKeys(_ input: [UInt8]) -> String {
        var keys: [String] = []
        var i = 0
        while i < input.count {
            let width = utf8Width(lead: input[i])
            if width > 1, i + width <= input.count,
               let scalar = singleScalar(input[i..<(i + width)]) {
                keys.append(String(format: "0x%x", scalar.value))
                i += width
            } else {
                keys.append(String(format: "0x%02x", input[i]))
                i += 1
            }
        }
        return keys.joined(separator: " ")
    }

    private static func utf8Width(lead: UInt8) -> Int {
        switch lead {
        case 0xC2...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF4: 4
        default: 1
        }
    }

    private static func singleScalar(_ bytes: ArraySlice<UInt8>) -> Unicode.Scalar? {
        let scalars = String(decoding: bytes, as: UTF8.self).unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first, scalar != "\u{FFFD}" else { return nil }
        return scalar
    }

    /// Keystrokes that must reach the PANE, whenever it exists: held until the
    /// first pane binds, then sent like typed input. Unlike ``encode(input:)``,
    /// never passed through to ssh — a command line typed into the control
    /// client's stdin is parsed as a protocol command, not delivered to a shell.
    func deliverWhenBound(_ input: [UInt8]) {
        guard !isExited, !input.isEmpty else { return }
        if boundPane != nil {
            sendToChild?(encode(input: input))
        } else {
            inputAwaitingPane += input
        }
    }

    /// The local grid changed. Stored always (attach uses the latest size);
    /// forwarded as `refresh-client -C` once attached so the far pane reflows.
    func viewportChanged(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        self.cols = cols
        self.rows = rows
        guard isAttached, !isExited else { return }
        sendCommand("refresh-client -C \(cols),\(rows)", purpose: .ignore)
    }

    // MARK: - passthrough phase

    private func ingestPassthrough(_ raw: [UInt8]) -> [UInt8] {
        carry += raw
        if let start = firstIndex(of: Self.opener, in: carry) {
            var render = Array(carry[..<start])
            let rest = Array(carry[(start + Self.opener.count)...])
            carry = []
            becomeAttached()
            render += ingestProtocol(rest)
            return render
        }
        let hold = openerPrefixLength(atTailOf: carry)
        let render = Array(carry[..<(carry.count - hold)])
        carry = Array(carry.suffix(hold))
        return render
    }

    private func becomeAttached() {
        isAttached = true
        onAttached?()
        sendCommand("refresh-client -C \(cols),\(rows)", purpose: .ignore)
        sendCommand("list-panes -F '#{pane_id}'", purpose: .bindPane)
    }

    private func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }

    /// Longest suffix of `bytes` that is a proper prefix of the opener.
    private func openerPrefixLength(atTailOf bytes: [UInt8]) -> Int {
        let longest = min(bytes.count, Self.opener.count - 1)
        guard longest > 0 else { return 0 }
        for length in stride(from: longest, through: 1, by: -1)
        where Array(bytes.suffix(length)) == Array(Self.opener.prefix(length)) {
            return length
        }
        return 0
    }

    // MARK: - attached phase

    private func ingestProtocol(_ raw: [UInt8]) -> [UInt8] {
        lineBuffer += raw
        var render: [UInt8] = []
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            var line = Array(lineBuffer[..<newline])
            lineBuffer.removeSubrange(...newline)
            // The protocol terminates lines \r\n (and ONLCR may have cooked a few
            // in flight before the raw-mode switch); content never ends in bare CR.
            if line.last == 0x0D { line.removeLast() }
            render += handleLine(line)
            if isExited { break }
        }
        return render
    }

    private func handleLine(_ line: [UInt8]) -> [UInt8] {
        if responseLines != nil {
            if hasPrefix(line, "%end") || hasPrefix(line, "%error") {
                let lines = responseLines ?? []
                responseLines = nil
                return finishResponse(
                    responsePurpose, lines: lines, failed: hasPrefix(line, "%error"))
            }
            responseLines?.append(line)
            return []
        }
        if hasPrefix(line, "%begin") {
            // `%begin <time> <number> <flags>`: flags 1 marks a reply to a command
            // THIS client sent; 0 is the server's own block (tmux's attach greeting),
            // which lands right behind the opener — after the bootstrap commands are
            // already queued — and must not consume their purposes.
            let unsolicited = String(decoding: line, as: UTF8.self)
                .split(separator: " ").last == "0"
            responsePurpose = !unsolicited && !pendingPurposes.isEmpty
                ? pendingPurposes.removeFirst() : .ignore
            responseLines = []
        } else if hasPrefix(line, "%output ") {
            return paneOutput(line)
        } else if hasPrefix(line, "%window-pane-changed ") {
            rebind(line)
        } else if hasPrefix(line, "%exit") {
            isExited = true
        }
        // Every other notification (%layout-change, %session-changed, %message, …)
        // carries nothing a single-pane data card renders.
        return []
    }

    private func finishResponse(
        _ purpose: Purpose, lines: [[UInt8]], failed: Bool
    ) -> [UInt8] {
        guard !failed else { return [] }
        switch purpose {
        case .ignore:
            return []
        case .bindPane:
            let pane = lines
                .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            if let pane { bind(to: pane) }
            return []
        case .paneModes:
            guard let line = lines.first else { return [] }
            return Self.modeSequences(flags: String(decoding: line, as: UTF8.self))
        case .backfill:
            backfilled = true
            // Clear whatever passthrough left on screen (banner, password prompt),
            // then replay the pane: history flows into local scrollback, the
            // visible tail lands on screen; the pane's next repaint places the cursor.
            var render = Array("\u{1B}[H\u{1B}[2J".utf8)
            render += Array(lines.joined(separator: [0x0D, 0x0A]))
            return render
        }
    }

    /// Bind (or re-bind) the rendered pane: replay its modes, then backfill it.
    /// The id came off the wire, so it is validated before it re-enters a command
    /// line. Modes are queried BEFORE the capture: a mode the pane sets after the
    /// capture arrives as live `%output` and renders on its own.
    private func bind(to pane: String) {
        guard pane.hasPrefix("%"), pane.count > 1,
              pane.dropFirst().allSatisfy(\.isNumber) else { return }
        boundPane = pane
        backfilled = false
        sendCommand("display-message -p -t \(pane) '\(Self.modeFormat)'", purpose: .paneModes)
        sendCommand(
            "capture-pane -peqJN -t \(pane) -S -\(Self.backfillLines)",
            purpose: .backfill)
        // Behind the capture on purpose: the server runs commands in order, so the
        // backfill never contains these keystrokes' echo — it arrives as `%output`.
        if !inputAwaitingPane.isEmpty {
            sendToChild?(encode(input: inputAwaitingPane))
            inputAwaitingPane = []
        }
    }

    private func paneOutput(_ line: [UInt8]) -> [UInt8] {
        guard backfilled, let boundPane else { return [] }
        let prefix = Array("%output \(boundPane) ".utf8)
        guard line.count > prefix.count, Array(line[..<prefix.count]) == prefix else {
            return []   // another pane's output, or the pre-backfill duplicate
        }
        return Self.unescapeOctal(Array(line[prefix.count...]))
    }

    private func rebind(_ line: [UInt8]) {
        // %window-pane-changed @<window> %<pane> — the far side replaced the
        // active pane (pane death respawn); re-bind and re-backfill.
        let parts = String(decoding: line, as: UTF8.self).split(separator: " ")
        guard parts.count >= 3 else { return }
        bind(to: String(parts[2]))
    }

    /// The escape sequences that put a fresh emulator into the state a
    /// `display-message` flags line describes: one 0/1 per mode, in
    /// ``modeFormat`` order. Anything else (a server without these formats)
    /// replays nothing.
    static func modeSequences(flags: String) -> [UInt8] {
        let bits = flags.split(separator: " ")
        guard bits.count == modeSetSequences.count,
              bits.allSatisfy({ $0 == "0" || $0 == "1" }) else { return [] }
        return Array(zip(bits, modeSetSequences)
            .filter { $0.0 == "1" }
            .map(\.1)
            .joined()
            .utf8)
    }

    private func sendCommand(_ command: String, purpose: Purpose) {
        pendingPurposes.append(purpose)
        sendToChild?(Array((command + "\n").utf8))
    }

    private func hasPrefix(_ line: [UInt8], _ prefix: String) -> Bool {
        let p = Array(prefix.utf8)
        return line.count >= p.count && Array(line[..<p.count]) == p
    }

    /// `%output` payload decoding: printable ASCII and tab pass through, `\\` is a
    /// backslash, `\NNN` is a 3-digit octal byte (CR/LF arrive as `\015`/`\012`).
    /// A malformed escape is passed through literally rather than dropped.
    static func unescapeOctal(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var i = 0
        while i < data.count {
            let byte = data[i]
            guard byte == 0x5C else { out.append(byte); i += 1; continue }
            if i + 1 < data.count, data[i + 1] == 0x5C {
                out.append(0x5C)
                i += 2
            } else if i + 3 < data.count, let value = octalByte(data[i + 1], data[i + 2], data[i + 3]) {
                out.append(value)
                i += 4
            } else {
                out.append(byte)
                i += 1
            }
        }
        return out
    }

    private static func octalByte(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8? {
        let digits = [a, b, c].map { Int($0) - 0x30 }
        guard digits.allSatisfy({ (0...7).contains($0) }) else { return nil }
        let value = digits[0] * 64 + digits[1] * 8 + digits[2]
        return value <= 255 ? UInt8(value) : nil
    }
}

/// Wires a ``TmuxControlChannel`` onto a live session's pty. One call per remote
/// card, at both places a remote spec binds to a session (fresh open and restore)
/// — the same chokepoint discipline as `recordRemoteSpec`.
public enum TmuxControlBridge {
    /// Attach iff the session is a remote card. Idempotent.
    @discardableResult
    public static func attachIfNeeded(to session: Session) -> Bool {
        guard let kind = session.remoteSpec?.hostKind else { return false }
        attach(to: session.pty, ownsTTYModes: kind == .windowsPsmux)
        return true
    }

    /// `ownsTTYModes`: switch the local pty to raw mode on attach. Right for the
    /// Windows path (`ssh -T`: nobody else configures the tty, and a cooked one
    /// echoes our commands back into the parse). WRONG for the POSIX path
    /// (`ssh -t`): the ssh client already put the tty in raw mode itself, and
    /// re-setting the modes from the master side mid-stream was observed to drop
    /// everything in flight after the first read — the attach never backfilled.
    public static func attach(to pty: PTYSession, ownsTTYModes: Bool) {
        guard pty.interceptOutput == nil else { return }   // already bridged
        let channel = TmuxControlChannel(cols: Int(pty.cols), rows: Int(pty.rows))
        // The channel lives exactly as long as the pty holds these closures.
        channel.sendToChild = { [weak pty] bytes in _ = pty?.sendRaw(bytes) }
        if ownsTTYModes {
            channel.onAttached = { [weak pty] in pty?.setRawMode() }
        }
        pty.interceptOutput = { channel.ingest($0) }
        pty.interceptInput = { channel.encode(input: $0) }
        pty.queueInput = { channel.deliverWhenBound($0) }
        pty.onResize = { rows, cols in
            channel.viewportChanged(cols: Int(cols), rows: Int(rows))
        }
    }
}
