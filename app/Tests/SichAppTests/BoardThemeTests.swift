import AppKit
import Testing

@testable import SichApp

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

    /// A shared accent must resolve IDENTICALLY
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
    @Test("canvas is Ghostty blue-charcoal in dark, neutral paper in light")
    func canvasEndpoints() throws {
        let dark = try #require(rgb(BoardTheme.canvas, in: .darkAqua))
        let light = try #require(rgb(BoardTheme.canvas, in: .aqua))
        #expect(dark.0 > 0.1 && dark.0 < 0.2, "dark canvas keeps the visible Ghostty lift")
        #expect(dark.2 > dark.0 && dark.2 > dark.1, "dark canvas remains blue-charcoal")
        #expect(light.0 > 0.9 && light.1 > 0.9 && light.2 > 0.9, "light canvas is neutral paper")
        #expect(abs(light.0 - light.2) < 0.04, "light canvas drifted back toward yellow paper")
    }

    @Test("light text tiers clear contrast on light surfaces", arguments: [
        "textPrimary", "textMuted", "textFaint", "textDim", "documentText",
    ])
    func lightTextContrast(_ name: String) throws {
        let text = try #require(Self.tokens[name], "unknown token \(name)")
        let fg = try #require(rgb(text, in: .aqua), "\(name) has no light resolution")
        let card = try #require(rgb(BoardTheme.cardFill, in: .aqua))
        let canvas = try #require(rgb(BoardTheme.canvas, in: .aqua))

        #expect(contrast(fg, card) >= 4.5, "\(name) is too faint on cardFill")
        #expect(contrast(fg, canvas) >= 4.5, "\(name) is too faint on canvas")
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

    private func contrast(
        _ a: (CGFloat, CGFloat, CGFloat),
        _ b: (CGFloat, CGFloat, CGFloat)
    ) -> CGFloat {
        let lighter = max(luminance(a), luminance(b))
        let darker = min(luminance(a), luminance(b))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ rgb: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.0) + 0.7152 * channel(rgb.1) + 0.0722 * channel(rgb.2)
    }
}

/// Card-title typography policy: ONE font for every title (slug or prose) so a
/// column scans as a uniform list, with tightened leading for the multi-line
/// wrap. The attributes are pure logic worth pinning — the pixels stay a visual AC.
@MainActor
@Suite("Card title typography")
struct CardTitleTextTests {

    @Test("every title sets in the same sans anchor", arguments: [
        "Work on Fonts and Style", "task-06-generations-per-link", "/",
    ])
    func uniformFont(_ title: String) throws {
        let text = BoardTheme.cardTitleText(title, color: .white)
        let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font == BoardTheme.cardTitle, "no per-title font forks — uniformity won")
    }

    @Test("titles carry tightened line height for the multi-line wrap")
    func tightLeading() throws {
        let text = BoardTheme.cardTitleText("Work on Fonts and Style", color: .white)
        let style = try #require(
            text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(style.maximumLineHeight > 0, "leading must be pinned, not default")
        #expect(style.maximumLineHeight < font.ascender - font.descender + font.leading,
                "pinned leading tightens vs the font default")
        #expect(style.lineBreakMode == .byWordWrapping, "wrapping must survive the paragraph style")
    }
}
