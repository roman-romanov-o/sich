import AppKit
import SichCore
import Testing

@testable import SichApp

/// Two claims the Core theme tests can't make, because Core has no AppKit:
/// that `BoardTheme` hands out a *different* ANSI ramp per appearance, and that a
/// real light/dark flip actually reaches the emulator. The second is the one that
/// matters — the palette maths being right is worthless if nothing calls it — so it
/// flips the surface's appearance and lets AppKit dispatch its own
/// `viewDidChangeEffectiveAppearance`, rather than calling the handler directly.
@MainActor
@Suite("Terminal theme is wired to the system appearance")
struct TerminalThemeWiringTests {

    private func makeSurface() throws -> (TerminalSurface, PTYSession) {
        let session = try PTYSession(command: ["/bin/cat"])
        try session.start()
        return (TerminalSurface(session: session), session)
    }

    private func theme(_ name: NSAppearance.Name) throws -> TerminalTheme {
        BoardTheme.terminalTheme(for: try #require(NSAppearance(named: name)))
    }

    @Test("each appearance gets its own ANSI ramp, over a shared xterm cube")
    func rampsDifferPerAppearance() throws {
        let dark = try theme(.darkAqua)
        let light = try theme(.aqua)

        #expect(dark.palette.count == 256)
        #expect(light.palette.count == 256)
        // The 16 themed slots flip...
        #expect(Array(dark.palette[0..<16]) != Array(light.palette[0..<16]))
        #expect(dark.background != light.background)
        #expect(dark.foreground != light.foreground)
        // ...while 16+ are absolute xterm values every terminal agrees on.
        #expect(Array(dark.palette[16...]) == Array(light.palette[16...]))
    }

    @Test("the light ramp is legible on paper: no near-white ANSI white")
    func lightRampSuitsPaper() throws {
        let light = try theme(.aqua)
        // `printf '\e[97mhi'` on cream paper must not come out invisible: white (7)
        // and bright white (15) are text greys in the light ramp, not near-white.
        for index in [7, 15] {
            let white = light.palette[index]
            let luminance = (Int(white.r) + Int(white.g) + Int(white.b)) / 3
            #expect(luminance < 160, "ANSI \(index) is too pale to read on light paper")
        }
    }

    @Test("a surface starts out themed for the appearance it was born into")
    func themeAppliedOnInit() throws {
        let (surface, session) = try makeSurface()
        defer { session.terminate() }
        let expected = BoardTheme.terminalTheme(for: surface.effectiveAppearance)
        #expect(session.terminal.currentPalette() == expected.palette)
    }

    @Test("flipping the system appearance re-themes the live emulator")
    func appearanceFlipReachesEmulator() throws {
        let (surface, session) = try makeSurface()
        defer { session.terminate() }

        // The real path: set the appearance and let AppKit dispatch
        // viewDidChangeEffectiveAppearance itself. Calling the handler by hand would
        // leave the wiring — the part that actually breaks — unproven.
        surface.appearance = NSAppearance(named: .darkAqua)
        let dark = session.terminal.currentPalette()
        surface.appearance = NSAppearance(named: .aqua)
        let light = session.terminal.currentPalette()

        let darkTheme = try theme(.darkAqua)
        let lightTheme = try theme(.aqua)
        #expect(dark == darkTheme.palette)
        #expect(light == lightTheme.palette)
        #expect(dark != light)
    }

    @Test("output the child already wrote re-colours on a flip")
    func flipRecoloursExistingOutput() throws {
        let (surface, session) = try makeSurface()
        defer { session.terminate() }

        surface.appearance = NSAppearance(named: .darkAqua)
        session.terminal.write(Array("\u{1b}[31mred".utf8))
        let before = session.terminal.snapshot().cell(col: 0, row: 0).fg

        surface.appearance = NSAppearance(named: .aqua)
        let after = session.terminal.snapshot().cell(col: 0, row: 0).fg

        let darkRed = try theme(.darkAqua).palette[1]
        let lightRed = try theme(.aqua).palette[1]
        #expect(before == darkRed)
        #expect(after == lightRed)
    }
}
