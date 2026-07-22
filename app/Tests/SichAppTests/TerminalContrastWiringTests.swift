import AppKit
import SichCore
import Testing

@testable import SichApp

/// Wiring proof for "terminal suggestions easier to spot": the contrast maths live in
/// SichCore (unit-tested there); this asserts the TerminalSurface draw path
/// actually *routes foregrounds through* that lift with its configured floor — so a
/// dim autosuggestion grey doesn't reach the screen unimproved. Guards against the
/// mechanism being silently bypassed (the dead-code false-pass this repo has hit).
@MainActor
@Suite("Terminal contrast lift is wired into the surface")
struct TerminalContrastWiringTests {

    private func makeSurface() throws -> (TerminalSurface, PTYSession) {
        let session = try PTYSession(command: ["/bin/cat"])
        try session.start()
        return (TerminalSurface(session: session), session)
    }

    /// A per-channel sRGB comparison — the surface returns an NSColor, we compare the
    /// resolved sRGB components to the RGB we expect.
    private func components(_ color: NSColor) -> (r: Double, g: Double, b: Double)? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    @Test("a dim grey foreground on a dark cell bg comes back lighter than it went in")
    func dimForegroundIsLifted() throws {
        let (surface, session) = try makeSurface()
        defer { session.terminate() }
        let darkBg = RGB(r: 0x1e, g: 0x1e, b: 0x1e)
        let dimGrey = RGB(r: 0x58, g: 0x58, b: 0x58)

        let resolved = try #require(components(
            surface.resolvedForegroundForTesting(fg: dimGrey, bg: darkBg)))
        // The lift pushes a low-contrast grey toward white on a dark bg → each channel
        // strictly brighter than the 0x58 input.
        let input = Double(0x58) / 255
        #expect(resolved.r > input)
        #expect(resolved.g > input)
        #expect(resolved.b > input)
    }

    @Test("an already-legible bright foreground passes through untouched")
    func legibleForegroundUntouched() throws {
        let (surface, session) = try makeSurface()
        defer { session.terminate() }
        let darkBg = RGB(r: 0x1e, g: 0x1e, b: 0x1e)
        let white = RGB(r: 0xff, g: 0xff, b: 0xff)

        let resolved = try #require(components(
            surface.resolvedForegroundForTesting(fg: white, bg: darkBg)))
        #expect(resolved.r > 0.99 && resolved.g > 0.99 && resolved.b > 0.99)
    }
}
