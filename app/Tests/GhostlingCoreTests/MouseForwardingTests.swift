import Testing

@testable import GhostlingCore

/// Wheel routing contracts behind `TerminalSurface.scrollWheel`: a child that
/// enabled mouse tracking gets encoded reports, one that didn't gets nothing
/// (the surface then scrolls the viewport itself), and the alternate screen is
/// detectable for the arrow-key fallback.
@Suite("Mouse wheel forwarding")
struct MouseForwardingTests {
    private let geometry = Terminal.MouseGeometry(
        screenWidth: 200, screenHeight: 100, cellWidth: 10, cellHeight: 20, padding: 0)

    @Test("no mouse tracking → no bytes to forward")
    func trackingOffEncodesNothing() throws {
        let term = try Terminal(cols: 20, rows: 5)
        #expect(term.encodeWheel(up: true, x: 50, y: 50, geometry: geometry) == nil)
    }

    @Test("SGR button tracking → wheel encodes as an SGR mouse report")
    func sgrTrackingEncodesWheel() throws {
        let term = try Terminal(cols: 20, rows: 5)
        term.write(Array("\u{1B}[?1002h\u{1B}[?1006h".utf8))   // button tracking + SGR

        let down = try #require(term.encodeWheel(up: false, x: 50, y: 50, geometry: geometry))
        let report = String(decoding: down, as: UTF8.self)
        #expect(report.hasPrefix("\u{1B}[<"))   // SGR framing
        #expect(report.hasSuffix("M"))          // press terminator

        term.write(Array("\u{1B}[?1002l".utf8))
        #expect(term.encodeWheel(up: false, x: 50, y: 50, geometry: geometry) == nil)
    }

    @Test("alternate screen mode is visible to the arrow-key fallback")
    func alternateScreenProbe() throws {
        let term = try Terminal(cols: 20, rows: 5)
        #expect(!term.alternateScreenActive)
        term.write(Array("\u{1B}[?1049h".utf8))
        #expect(term.alternateScreenActive)
        term.write(Array("\u{1B}[?1049l".utf8))
        #expect(!term.alternateScreenActive)
    }
}

/// The selection freeze: while `holdOutput` is set, ingested bytes buffer instead
/// of moving the grid (so a viewport-relative selection stays truthful), sniffers
/// still see every byte live, and clearing the flag flushes in order.
@Suite("PTY output hold")
struct HoldOutputTests {
    @Test func holdBuffersThenFlushesInOrder() throws {
        let session = try PTYSession(command: ["/bin/cat"], rows: 5, cols: 40)
        var sniffed = ""
        session.onOutput = { sniffed += String(decoding: $0, as: UTF8.self) }

        session.ingest(Array("before ".utf8))
        session.holdOutput = true
        session.ingest(Array("held".utf8))

        #expect(try session.terminal.plainText().contains("before"))
        #expect(try !session.terminal.plainText().contains("held"))   // grid frozen
        #expect(session.heldByteCount == 4)
        #expect(sniffed == "before held")                             // sniffer stays live

        session.holdOutput = false
        #expect(try session.terminal.plainText().contains("before held"))
        #expect(session.heldByteCount == 0)
    }
}
