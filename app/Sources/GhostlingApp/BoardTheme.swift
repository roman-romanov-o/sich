import AppKit

/// The HELM POC's visual palette, in one place so the board views stay
/// consistent with the rendering reference (`research/UI_POC.html`): near-black
/// canvas, dim hairlines, amber attention accent, muted metadata grey.
@MainActor
enum BoardTheme {
    static let canvas = NSColor(white: 0.05, alpha: 1)
    static let cardFill = NSColor(white: 0.10, alpha: 1)
    static let cardStroke = NSColor(white: 0.22, alpha: 1)
    static let hairline = NSColor(white: 0.18, alpha: 1)

    static let textPrimary = NSColor(white: 0.92, alpha: 1)
    static let textMuted = NSColor(white: 0.52, alpha: 1)
    static let textFaint = NSColor(white: 0.38, alpha: 1)

    /// The amber "needs you" accent — the attention column header, the badge,
    /// and a blocked/waiting card's left edge.
    static let attention = NSColor(
        red: 0.95, green: 0.62, blue: 0.20, alpha: 1
    )
    /// A brighter red used only for the global "N waiting on you" badge.
    static let alert = NSColor(red: 0.86, green: 0.30, blue: 0.24, alpha: 1)

    static let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let monoBold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    static let monoSmall = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
    static let title = NSFont.systemFont(ofSize: 13, weight: .semibold)
}
