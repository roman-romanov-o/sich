import Testing
@testable import GhostlingCore

// The theme path end-to-end through a real libghostty-vt emulator: push a palette,
// feed real SGR output, read the resolved cells back. The claim that actually
// carries the feature is the *retroactive* one — a light/dark flip has to re-colour
// output the child already wrote, not just what it writes next — so that gets a
// test against the emulator rather than a check of what we handed it.

@Suite("Terminal colour theme")
struct TerminalThemeTests {

    /// A theme whose ANSI slots are trivially identifiable: index i = grey(i*16).
    private func theme(brightness: UInt8) -> TerminalTheme {
        TerminalTheme(
            background: RGB(r: 0, g: 0, b: 0),
            foreground: RGB(r: brightness, g: brightness, b: brightness),
            cursor: RGB(r: 1, g: 2, b: 3),
            ansi: (0..<16).map { RGB(r: UInt8($0) &* 16, g: brightness, b: UInt8($0)) }
        )
    }

    @Test("an applied palette is the one libghostty resolves SGR colours through")
    func appliedPaletteResolvesCellColour() throws {
        let terminal = try Terminal(cols: 20, rows: 5)
        let applied = theme(brightness: 200)
        terminal.apply(theme: applied)
        terminal.write(Array("\u{1b}[31mX".utf8))   // SGR 31 → palette index 1

        let cell = terminal.snapshot().cell(col: 0, row: 0)
        #expect(cell.scalar.map(Character.init) == "X")
        #expect(cell.fg == applied.palette[1])
    }

    @Test("re-applying a theme re-colours output the child already wrote")
    func themeSwitchIsRetroactive() throws {
        let terminal = try Terminal(cols: 20, rows: 5)
        terminal.apply(theme: theme(brightness: 200))
        terminal.write(Array("\u{1b}[31mX".utf8))   // written under the FIRST theme
        let before = terminal.snapshot().cell(col: 0, row: 0).fg

        // The light/dark flip: same emulator, same untouched scrollback, new palette.
        let flipped = theme(brightness: 40)
        terminal.apply(theme: flipped)
        let after = terminal.snapshot().cell(col: 0, row: 0).fg

        #expect(before != after)          // the already-written cell re-coloured...
        #expect(after == flipped.palette[1])   // ...to the new theme, not a stale one
    }

    @Test("the default foreground follows the applied theme")
    func defaultForegroundFollowsTheme() throws {
        let terminal = try Terminal(cols: 20, rows: 5)
        let applied = theme(brightness: 123)
        terminal.apply(theme: applied)
        terminal.write(Array("plain".utf8))   // no SGR — falls back to the default fg
        #expect(terminal.snapshot().defaultFg == applied.foreground)
    }

    @Test("the emulator reads back the exact 256 entries it was given")
    func paletteReadsBack() throws {
        let terminal = try Terminal(cols: 20, rows: 5)
        let applied = theme(brightness: 200)
        terminal.apply(theme: applied)
        #expect(terminal.currentPalette() == applied.palette)
    }

    @Test("a theme is 256 entries: 16 themed, then the standard xterm cube")
    func paletteLayout() {
        let dark = theme(brightness: 200)
        let light = theme(brightness: 40)
        #expect(dark.palette.count == 256)
        // Indices 16+ are absolute xterm values, so they must NOT flip with the theme.
        #expect(Array(dark.palette[16...]) == Array(light.palette[16...]))
        #expect(dark.palette[16] == RGB(r: 0, g: 0, b: 0))        // cube origin
        #expect(dark.palette[196] == RGB(r: 255, g: 0, b: 0))     // cube pure red
        #expect(dark.palette[231] == RGB(r: 255, g: 255, b: 255)) // cube apex
        #expect(dark.palette[232] == RGB(r: 8, g: 8, b: 8))       // greyscale floor
        #expect(dark.palette[255] == RGB(r: 238, g: 238, b: 238)) // greyscale ceiling
    }
}
