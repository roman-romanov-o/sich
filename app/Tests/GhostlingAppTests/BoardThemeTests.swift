import AppKit
import Testing

@testable import GhostlingApp

/// The machine-assertable half of "sync with system dark/light on the fly": the
/// palette must be a *dynamic* NSColor that resolves to different RGB under an
/// `.aqua` vs `.darkAqua` appearance. The pixels themselves (does the board look
/// right in light mode?) are a visual AC routed to human eyes — but "the token is
/// genuinely appearance-aware, not a frozen dark constant" is testable here.
@MainActor
@Suite("BoardTheme resolves per system appearance")
struct BoardThemeTests {

    /// Resolve an NSColor's sRGB components under a named appearance.
    private func rgb(_ color: NSColor, in appearance: NSAppearance.Name) -> (CGFloat, CGFloat, CGFloat)? {
        var out: (CGFloat, CGFloat, CGFloat)?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            guard let c = color.usingColorSpace(.sRGB) else { return }
            out = (c.redComponent, c.greenComponent, c.blueComponent)
        }
        return out
    }

    /// Every surface/text token must land on a DIFFERENT colour in light vs dark —
    /// proof the palette follows the system theme rather than being a fixed dark hex.
    @Test("surface + text tokens differ between light and dark appearance", arguments: [
        "canvas", "cardFill", "documentSurface", "cardStroke", "hairline",
        "needsYouColumn", "needsYouCard", "doneStroke",
        "textPrimary", "textMuted", "textFaint", "documentText", "textDim",
        "termBg", "termFg",
    ])
    func tokenIsAppearanceAware(_ name: String) throws {
        let token = try #require(Self.tokens[name], "unknown token \(name)")
        let dark = try #require(rgb(token, in: .darkAqua), "\(name) has no dark resolution")
        let light = try #require(rgb(token, in: .aqua), "\(name) has no light resolution")
        #expect(dark != light, "\(name) resolves to the same colour in both modes — not theme-aware")
    }

    /// A shared accent (Solarized accents are dual-scheme) must resolve IDENTICALLY
    /// in both modes — a regression guard that we didn't accidentally split them.
    @Test("shared accents are identical across appearances", arguments: [
        "brand", "attention", "alert", "codeInline",
    ])
    func accentIsStable(_ name: String) throws {
        let token = try #require(Self.tokens[name], "unknown token \(name)")
        let dark = try #require(rgb(token, in: .darkAqua))
        let light = try #require(rgb(token, in: .aqua))
        #expect(dark == light, "\(name) should be one shared accent, not a light/dark pair")
    }

    /// The canvas is the always-on board background; pin its exact light/dark values
    /// so a future edit can't silently collapse the light theme back to the dark one.
    @Test("canvas is the Osaka-night base in dark, Solarized base2 in light")
    func canvasEndpoints() throws {
        let dark = try #require(rgb(BoardTheme.canvas, in: .darkAqua))
        let light = try #require(rgb(BoardTheme.canvas, in: .aqua))
        #expect(dark.0 < 0.1 && dark.1 < 0.1 && dark.2 < 0.2, "dark canvas is near-black blue")
        #expect(light.0 > 0.8 && light.1 > 0.8 && light.2 > 0.7, "light canvas is warm paper")
    }

    private static let tokens: [String: NSColor] = [
        "canvas": BoardTheme.canvas, "cardFill": BoardTheme.cardFill,
        "documentSurface": BoardTheme.documentSurface, "cardStroke": BoardTheme.cardStroke,
        "hairline": BoardTheme.hairline, "needsYouColumn": BoardTheme.needsYouColumn,
        "needsYouCard": BoardTheme.needsYouCard, "doneStroke": BoardTheme.doneStroke,
        "textPrimary": BoardTheme.textPrimary, "textMuted": BoardTheme.textMuted,
        "textFaint": BoardTheme.textFaint, "documentText": BoardTheme.documentText,
        "textDim": BoardTheme.textDim, "termBg": BoardTheme.termBg, "termFg": BoardTheme.termFg,
        "brand": BoardTheme.brand, "attention": BoardTheme.attention,
        "alert": BoardTheme.alert, "codeInline": BoardTheme.codeInline,
    ]
}
