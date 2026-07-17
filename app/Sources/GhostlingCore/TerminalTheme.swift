/// The colour theme an embedder pushes into a ``Terminal``: the default
/// foreground/background/cursor plus the 256-entry palette that ANSI colour
/// indices resolve through.
///
/// libghostty-vt stores a palette *index* in the cell and only looks it up when the
/// render state is read, so applying a theme re-colours scrollback that was already
/// written — a light/dark flip is retroactive and needs no reflow. Plain `RGB` (not
/// `NSColor`) because the emulator lives below AppKit: the *policy* of which colours
/// a given appearance gets belongs to the app layer (`BoardTheme`), and this type is
/// only the mechanism.
public struct TerminalTheme: Equatable, Sendable {
    public let background: RGB
    public let foreground: RGB
    public let cursor: RGB
    /// Exactly 256 entries: the 16 theme ANSI colours, then the standard xterm cube.
    public let palette: [RGB]

    /// - Parameter ansi: the 16 theme colours in ANSI order — black, red, green,
    ///   yellow, blue, magenta, cyan, white, then the eight bright variants.
    public init(background: RGB, foreground: RGB, cursor: RGB, ansi: [RGB]) {
        precondition(ansi.count == 16, "an ANSI palette is exactly 16 colours, got \(ansi.count)")
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.palette = ansi + Self.xtermExtended
    }

    /// Palette indices 16–255. These are the absolute xterm-256 values every
    /// terminal agrees on, so they carry no theme and are shared by both
    /// appearances — only the first 16 entries flip with light/dark.
    static let xtermExtended: [RGB] = colorCube + greyscaleRamp

    /// Indices 16–231: the 6×6×6 cube, red outermost, blue innermost.
    private static let colorCube: [RGB] = {
        let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
        return levels.flatMap { r in levels.flatMap { g in levels.map { RGB(r: r, g: g, b: $0) } } }
    }()

    /// Indices 232–255: the 24-step greyscale ramp.
    private static let greyscaleRamp: [RGB] = (0..<24).map {
        let level = UInt8(8 + $0 * 10)
        return RGB(r: level, g: level, b: level)
    }
}
