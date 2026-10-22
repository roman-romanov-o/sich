import Foundation
import Testing
@testable import SichCore

/// The tmux/psmux control-mode channel: passthrough auth → DCS-opener flip →
/// framed protocol. Everything here drives the pure state machine with wire
/// bytes — no ssh, no tmux, no pty — because the machine is the part that must
/// be exactly right for a live remote card to render at all. The real-server
/// end-to-end lives in `TmuxControlLocalTests`.
@Suite("tmux control-mode channel")
struct TmuxControlChannelTests {

    private let opener = "\u{1B}P1000p"

    private final class Wire {
        var sent: [String] = []
        var attached = 0
    }

    private func makeChannel(cols: Int = 120, rows: Int = 30) -> (TmuxControlChannel, Wire) {
        let channel = TmuxControlChannel(cols: cols, rows: rows)
        let wire = Wire()
        channel.sendToChild = { wire.sent.append(String(decoding: $0, as: UTF8.self)) }
        channel.onAttached = { wire.attached += 1 }
        return (channel, wire)
    }

    private func feed(_ channel: TmuxControlChannel, _ text: String) -> String {
        String(decoding: channel.ingest(Array(text.utf8)), as: UTF8.self)
    }

    /// Drive the channel through attach → pane bind → backfill: the bootstrap a
    /// live server answers with. Leaves the channel rendering `%output %0`.
    private func fullyAttach(_ channel: TmuxControlChannel) {
        _ = channel.ingest(Array(opener.utf8))
        _ = feed(channel, "%begin 1 1 1\r\n%end 1 1 1\r\n")            // refresh-client
        _ = feed(channel, "%begin 1 2 1\r\n%0\r\n%end 1 2 1\r\n")      // list-panes → %0
        _ = feed(channel, "%begin 1 3 1\r\n0 0 0 0 0 0 0 0 0 0\r\n%end 1 3 1\r\n")   // display-message (modes)
        _ = feed(channel, "%begin 1 4 1\r\nback\r\n%end 1 4 1\r\n")    // capture-pane
    }

    // MARK: - mode replay (a pane that changed modes before we attached)

    private let modesQuery = "display-message -p -t %0 '#{alternate_on} #{mouse_standard_flag}"
        + " #{mouse_button_flag} #{mouse_all_flag} #{mouse_sgr_flag} #{mouse_utf8_flag}"
        + " #{keypad_cursor_flag} #{keypad_flag} #{origin_flag} #{insert_flag}'\n"

    @Test("binding a pane asks tmux for its modes BEFORE the capture")
    func bindQueriesModesThenCaptures() {
        let (channel, wire) = makeChannel()
        _ = channel.ingest(Array(opener.utf8))
        _ = feed(channel, "%begin 1 1 1\r\n%end 1 1 1\r\n")
        _ = feed(channel, "%begin 1 2 1\r\n%0\r\n%end 1 2 1\r\n")
        #expect(Array(wire.sent.suffix(2)) == [modesQuery, "capture-pane -peqJN -t %0 -S -1000\n"])
    }

    @Test("a fullscreen pane (alt screen + SGR mouse) is replayed into the emulator before its backfill")
    func modesReplayAltScreenAndMouse() {
        // Claude Code's fullscreen renderer running since before the attach: tmux
        // reports alternate_on, mouse_all and mouse_sgr. Without the replay the
        // local emulator scrolls an empty viewport and never sends the wheel down.
        let (channel, _) = makeChannel()
        _ = channel.ingest(Array(opener.utf8))
        _ = feed(channel, "%begin 1 1 1\r\n%end 1 1 1\r\n")
        _ = feed(channel, "%begin 1 2 1\r\n%0\r\n%end 1 2 1\r\n")
        let modes = feed(channel, "%begin 1 3 1\r\n1 0 0 1 1 0 0 0 0 0\r\n%end 1 3 1\r\n")
        #expect(modes == "\u{1B}[?1049h\u{1B}[?1003h\u{1B}[?1006h")
        let backfill = feed(channel, "%begin 1 4 1\r\nscreen\r\n%end 1 4 1\r\n")
        #expect(backfill == "\u{1B}[H\u{1B}[2Jscreen", "the capture lands on the alt screen")
        #expect(feed(channel, "%output %0 live\r\n") == "live")
    }

    @Test("a server without those formats (or a plain pane) replays nothing")
    func modesReplayIsConservative() {
        #expect(TmuxControlChannel.modeSequences(flags: "0 0 0 0 0 0 0 0 0 0").isEmpty)
        #expect(TmuxControlChannel.modeSequences(flags: "").isEmpty)
        #expect(TmuxControlChannel.modeSequences(flags: "#{alternate_on} #{mouse_standard_flag}").isEmpty)
        #expect(TmuxControlChannel.modeSequences(flags: "1 1").isEmpty, "a short line is not trusted")
        #expect(String(decoding: TmuxControlChannel.modeSequences(flags: "0 0 0 0 0 0 1 1 1 1"), as: UTF8.self)
                == "\u{1B}[?1h\u{1B}=\u{1B}[?6h\u{1B}[4h")
    }

    // MARK: - the tmux greeting (flags 0) vs replies (flags 1)

    @Test("tmux's greeting block (flags 0) dequeues nothing, so the replies still bind the pane")
    func greetingBlockDoesNotConsumeAPurpose() {
        // Real tmux 3.4 emits `%begin <t> <n> 0 … %end` right behind the opener —
        // after the bootstrap commands are already queued. FIFO without the flags
        // check handed the greeting the refresh-client purpose and the pane id to
        // `ignore`: no bind, no backfill, a blank card (the first remote attempt).
        let (channel, wire) = makeChannel()
        _ = feed(channel, opener + "%begin 1792581271 271 0\r\n%end 1792581271 271 0\r\n")
        _ = feed(channel, "%begin 1792581272 272 1\r\n%end 1792581272 272 1\r\n")   // refresh-client
        _ = feed(channel, "%begin 1792581272 273 1\r\n%0\r\n%end 1792581272 273 1\r\n")   // list-panes
        #expect(channel.boundPane == "%0")
        #expect(wire.sent.last == "capture-pane -peqJN -t %0 -S -1000\n")
    }

    // MARK: - programmatic input (an agent start, a login)

    @Test("input handed over before a pane exists is delivered right after the bind, as keystrokes")
    func deferredInputWaitsForThePane() {
        let (channel, wire) = makeChannel()
        channel.deliverWhenBound(Array("claude\n".utf8))
        #expect(wire.sent.isEmpty, "never passed through to ssh: the handshake would parse it")
        _ = feed(channel, opener)
        _ = feed(channel, "%begin 1 1 1\r\n%end 1 1 1\r\n")
        #expect(!wire.sent.contains { $0.hasPrefix("send") }, "still no pane to type into")
        _ = feed(channel, "%begin 1 2 1\r\n%0\r\n%end 1 2 1\r\n")
        let capture = wire.sent.firstIndex { $0.hasPrefix("capture-pane") }
        let typed = wire.sent.firstIndex { $0.hasPrefix("send -t %0 ") }
        #expect(typed != nil && capture != nil && typed! > capture!,
                "typed behind the backfill, so its echo arrives as %output, not twice")
        #expect(wire.sent[typed!] == "send -t %0 0x63 0x6c 0x61 0x75 0x64 0x65 0x0a\n")
        // Once bound, delivery is immediate.
        channel.deliverWhenBound([0x03])
        #expect(wire.sent.last == "send -t %0 0x03\n")
    }

    // MARK: - passthrough (ssh auth)

    @Test("before the opener, bytes render verbatim and input passes untouched")
    func passthroughIsTransparent() {
        let (channel, wire) = makeChannel()
        #expect(feed(channel, "roman@winbox's password: ") == "roman@winbox's password: ")
        #expect(channel.encode(input: Array("hunter2\r".utf8)) == Array("hunter2\r".utf8),
                "the typed password must reach ssh exactly as typed")
        #expect(wire.sent.isEmpty && wire.attached == 0)
    }

    @Test("the opener flips to protocol, fires the raw-mode hook, and bootstraps")
    func openerAttaches() {
        let (channel, wire) = makeChannel()
        let render = feed(channel, "last login\r\n" + opener)
        #expect(render == "last login\r\n", "the opener itself never renders")
        #expect(channel.isAttached)
        #expect(wire.attached == 1)
        #expect(wire.sent == [
            "refresh-client -C 120,30\n",
            "list-panes -F '#{pane_id}'\n",
        ])
    }

    @Test("an opener split across reads is held back, matched, never rendered")
    func openerAcrossChunks() {
        let (channel, wire) = makeChannel()
        #expect(feed(channel, "ok\u{1B}P10") == "ok", "a possible opener prefix is held")
        #expect(feed(channel, "00p") == "")
        #expect(channel.isAttached && wire.attached == 1)
    }

    @Test("a held prefix that turns out NOT to be the opener renders after all")
    func falseOpenerPrefixRenders() {
        let (channel, _) = makeChannel()
        #expect(feed(channel, "x\u{1B}P1") == "x")
        #expect(feed(channel, "abc") == "\u{1B}P1abc")
        #expect(!channel.isAttached)
    }

    // MARK: - bind + backfill

    @Test("list-panes binds the first pane and requests the backfill capture")
    func bindsAndBackfills() {
        let (channel, wire) = makeChannel()
        _ = channel.ingest(Array(opener.utf8))
        _ = feed(channel, "%begin 1 1 1\r\n%end 1 1 1\r\n")
        _ = feed(channel, "%begin 1 2 1\r\n%0\r\n%end 1 2 1\r\n")
        #expect(channel.boundPane == "%0")
        #expect(wire.sent.last == "capture-pane -peqJN -t %0 -S -1000\n")
    }

    @Test("%output is dropped until the backfill lands — it is already inside the capture")
    func outputGatedByBackfill() {
        let (channel, _) = makeChannel()
        _ = channel.ingest(Array(opener.utf8))
        _ = feed(channel, "%begin 1 1 1\r\n%end 1 1 1\r\n")
        _ = feed(channel, "%begin 1 2 1\r\n%0\r\n%end 1 2 1\r\n")
        #expect(feed(channel, "%output %0 early\r\n") == "",
                "pre-backfill output would double-print")
        _ = feed(channel, "%begin 1 3 1\r\n0 0 0 0 0 0 0 0 0 0\r\n%end 1 3 1\r\n")   // modes: plain pane
        let render = feed(channel, "%begin 1 4 1\r\nhistory\r\nprompt>\r\n%end 1 4 1\r\n")
        #expect(render == "\u{1B}[H\u{1B}[2J" + "history\r\nprompt>",
                "the backfill clears the auth residue, then replays the pane")
        #expect(feed(channel, "%output %0 live\r\n") == "live")
    }

    @Test("%output decodes octal escapes; other panes and torn lines don't leak")
    func outputDecoding() {
        let (channel, _) = makeChannel()
        fullyAttach(channel)
        #expect(feed(channel, "%output %0 hi\\015\\012\r\n") == "hi\r\n")
        #expect(feed(channel, "%output %9 other-pane\r\n") == "")
        // A line torn across reads renders only once complete.
        #expect(feed(channel, "%output %0 tail") == "")
        #expect(feed(channel, "-end\r\n") == "tail-end")
    }

    @Test("unescapeOctal: backslash pairs, \\NNN bytes, malformed passes through")
    func octalUnescape() {
        func decode(_ s: String) -> [UInt8] {
            TmuxControlChannel.unescapeOctal(Array(s.utf8))
        }
        #expect(decode(#"a\\b"#) == Array("a\\b".utf8))
        #expect(decode(#"\015\012"#) == [0x0D, 0x0A])
        #expect(decode(#"\134"#) == [0x5C], "tmux-style octal backslash also decodes")
        #expect(decode(#"\033[1m"#) == [0x1B, 0x5B, 0x31, 0x6D])
        #expect(decode(#"x\9z"#) == Array(#"x\9z"#.utf8), "malformed escape is literal")
    }

    // MARK: - input + resize

    @Test("attached keystrokes become one hex send line for the bound pane")
    func encodeIsHexSend() {
        let (channel, _) = makeChannel()
        fullyAttach(channel)
        let up: [UInt8] = [0x1B, 0x5B, 0x41]
        #expect(channel.encode(input: up) == Array("send -t %0 0x1b 0x5b 0x41\n".utf8))
    }

    /// tmux reads `send-keys 0xNN` as a Unicode code point (it runs it through
    /// `wctomb`), not a byte: per byte, "П" (D0 9F) lands as "Ð" + a control char.
    @Test("non-ASCII keystrokes are sent per code point, not per UTF-8 byte")
    func encodeSendsCodePoints() {
        let (channel, _) = makeChannel()
        fullyAttach(channel)
        #expect(channel.encode(input: Array("Привіт".utf8))
                == Array("send -t %0 0x41f 0x440 0x438 0x432 0x456 0x442\n".utf8))
        #expect(channel.encode(input: Array("a🙂\r".utf8))
                == Array("send -t %0 0x61 0x1f642 0x0d\n".utf8))
        #expect(channel.encode(input: [0xD0]) == Array("send -t %0 0xd0\n".utf8),
                "a stray lead byte is passed through as itself rather than dropped")
    }

    @Test("attached but not yet bound, keystrokes are dropped — never leaked raw")
    func encodeUnboundDrops() {
        let (channel, _) = makeChannel()
        _ = channel.ingest(Array(opener.utf8))
        #expect(channel.encode(input: Array("x".utf8)) == [],
                "raw bytes on the protocol wire would be parsed as a command")
    }

    @Test("a viewport change forwards as refresh-client once attached")
    func resizeForwards() {
        let (channel, wire) = makeChannel()
        channel.viewportChanged(cols: 100, rows: 40)   // pre-attach: stored only
        #expect(wire.sent.isEmpty)
        fullyAttach(channel)
        #expect(wire.sent.first == "refresh-client -C 100,40\n",
                "attach uses the latest stored size")
        channel.viewportChanged(cols: 90, rows: 25)
        #expect(wire.sent.last == "refresh-client -C 90,25\n")
    }

    // MARK: - notifications + lifecycle

    @Test("a notification between blocks does not shift response correlation")
    func notificationsDoNotDesyncFIFO() {
        let (channel, wire) = makeChannel()
        _ = channel.ingest(Array(opener.utf8))
        _ = feed(channel, "%sessions-changed\r\n%begin 1 1 1\r\n%end 1 1 1\r\n")
        _ = feed(channel, "%layout-change @0 anything\r\n")
        _ = feed(channel, "%begin 1 2 1\r\n%0\r\n%end 1 2 1\r\n")
        #expect(channel.boundPane == "%0")
        #expect(wire.sent.last == "capture-pane -peqJN -t %0 -S -1000\n")
    }

    @Test("%window-pane-changed re-binds and re-backfills the new pane")
    func paneChangeRebinds() {
        let (channel, wire) = makeChannel()
        fullyAttach(channel)
        _ = feed(channel, "%window-pane-changed @0 %5\r\n")
        #expect(channel.boundPane == "%5")
        #expect(wire.sent.last == "capture-pane -peqJN -t %5 -S -1000\n")
        #expect(feed(channel, "%output %0 stale\r\n") == "", "the dead pane is unbound")
        #expect(feed(channel, "%output %5 fresh\r\n") == "", "gated until ITS backfill")
        _ = feed(channel, "%begin 1 8 1\r\n0 0 0 0 0 0 0 0 0 0\r\n%end 1 8 1\r\n")   // its modes
        _ = feed(channel, "%begin 1 9 1\r\nnew\r\n%end 1 9 1\r\n")
        #expect(feed(channel, "%output %5 fresh\r\n") == "fresh")
    }

    @Test("a wire-borne pane id that is not %<digits> never re-enters a command")
    func hostilePaneIDRefused() {
        let (channel, wire) = makeChannel()
        _ = channel.ingest(Array(opener.utf8))
        _ = feed(channel, "%begin 1 1 1\r\n%end 1 1 1\r\n")
        _ = feed(channel, "%begin 1 2 1\r\n%0; kill-server\r\n%end 1 2 1\r\n")
        #expect(channel.boundPane == nil)
        #expect(!wire.sent.contains { $0.contains("kill-server") })
    }

    @Test("%exit ends the channel: nothing renders, nothing encodes")
    func exitStopsEverything() {
        let (channel, _) = makeChannel()
        fullyAttach(channel)
        _ = feed(channel, "%exit\r\n")
        #expect(channel.isExited)
        #expect(feed(channel, "%output %0 late\r\n") == "")
        #expect(channel.encode(input: Array("x".utf8)) == [])
    }
}

/// The seams ``TmuxControlBridge`` hangs the channel on: output/input
/// interception and the raw send bypass, proven on a real pty child.
@Suite("PTYSession protocol seams")
struct PTYSessionInterceptTests {

    @Test("interceptOutput transforms what the emulator and onOutput see")
    func outputInterception() throws {
        let session = try PTYSession(command: ["/bin/cat"])
        session.interceptOutput = { Array(String(decoding: $0, as: UTF8.self)
            .replacingOccurrences(of: "wire", with: "pane").utf8) }
        var seen: [UInt8] = []
        session.onOutput = { seen += $0 }
        session.ingest(Array("wire-bytes".utf8))
        #expect(String(decoding: seen, as: UTF8.self) == "pane-bytes",
                "sniffers must see decoded pane bytes, not protocol frames")
    }

    @Test("interceptInput shapes the wire; onInput observes wire truth; sendRaw bypasses")
    func inputInterception() throws {
        let session = try PTYSession(command: ["/bin/cat"])
        try session.start()
        defer { session.terminate() }
        session.interceptInput = { Array("[\(String(decoding: $0, as: UTF8.self))]".utf8) }
        var wire: [String] = []
        session.onInput = { wire.append(String(decoding: $0, as: UTF8.self)) }
        _ = session.send(Array("key".utf8))
        _ = session.sendRaw(Array("cmd".utf8))
        #expect(wire == ["[key]", "cmd"],
                "send goes through the transform, sendRaw goes out as-is")
    }

    @Test("an interceptor swallowing a chunk writes nothing to the child")
    func swallowedInputWritesNothing() throws {
        let session = try PTYSession(command: ["/bin/cat"])
        try session.start()
        defer { session.terminate() }
        session.interceptInput = { _ in [] }
        #expect(session.send(Array("dropped".utf8)) == 0)
    }
}
