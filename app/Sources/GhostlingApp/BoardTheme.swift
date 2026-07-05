import AppKit
import GhostlingCore

/// The Deep Slate / Aurora palette in one place so every board view stays
/// consistent (replaces the old near-black HELM greys). Hex tokens straight from
/// the designer deliverable; semantic helpers (`stateColor`/`flowColor`/
/// `agentColor`) keep the colour policy here, not smeared across the views.
@MainActor
enum BoardTheme {
    // MARK: - Surfaces
    static let canvas = hex(0x0D1117)
    static let canvasSunken = hex(0x090C12)
    static let cardFill = hex(0x161C26)
    static let cardFillRaised = hex(0x1E2733)
    static let cardStroke = hex(0x2A3340)
    static let cardStrokeStrong = hex(0x3A4757)
    static let hairline = hex(0x2A3340)

    // MARK: - Text
    static let textPrimary = hex(0xE6EDF3)
    static let textMuted = hex(0x9DA9B8)
    // Lifted from #6B7686 (≈4.1:1, borderline on the 11/10pt faint labels) to clear
    // WCAG AA ≥4.5:1 on the canvas, while staying visibly dimmer than `textMuted`.
    static let textFaint = hex(0x7E8A9C)

    // MARK: - Accents
    /// The interactive brand blue — create affordance, drop ring. Kept distinct
    /// from the (deeper) running-state blue so a UI accent never reads as a state.
    static let brand = hex(0x4B8DF8)
    /// Amber "needs you" accent — attention header/edge.
    static let attention = hex(0xF5A623)
    /// Brighter red for blocked cards' rail/note (red-on-dark, not a text fill).
    static let alert = hex(0xF0533F)
    /// Deeper crimson used ONLY as the global "N waiting on you" badge FILL, so its
    /// white text clears WCAG AA (the coral `alert` at white text is only 3.49:1).
    static let attentionBadge = hex(0xB8392E)

    // MARK: - Terminal surface (its own near-black so it reads as a real console)
    static let termBg = hex(0x0C1017)
    static let termFg = hex(0xC9D4E0)
    static let termCursor = hex(0x2DD4BF)

    // MARK: - Fonts
    static let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let monoBold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    static let monoSmall = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let title = NSFont.systemFont(ofSize: 13, weight: .semibold)

    // MARK: - Semantic colour (the policy lives here)

    /// The colour for a card's state rail / chip — the at-a-glance lifecycle cue.
    static func stateColor(_ state: CardState) -> NSColor {
        switch state {
        case .idle: return hex(0x6B7686)
        case .running: return hex(0x3B7EF0)   // deeper than `brand` so a state never reads as the create accent
        case .runningTests: return hex(0xA06BFF)
        case .waitingForInput: return hex(0xF5A623)
        case .blocked: return hex(0xF0533F)
        case .done: return hex(0x3FB950)
        case .unknown: return hex(0x7A8998)   // lifted from #5A6573 (2.89:1) to clear WCAG AA on canvas
        }
    }

    /// Flow-A (saha / SDK) violet vs Flow-B (interactive) teal — the two-flow cue.
    static func flowColor(_ flow: CardFlow) -> NSColor {
        flow == .a ? hex(0xA06BFF) : hex(0x2DD4BF)
    }

    /// Which agentic CLI drives the card — a small colour dot on the card face.
    static func agentColor(_ agent: CardAgent) -> NSColor {
        switch agent {
        case .claude: return hex(0xD9893E)
        case .codex: return hex(0x10A37F)
        case .gemini: return hex(0x5B8DEF)
        }
    }

    /// Display form of a card's project dir. A deep absolute path collapses to its
    /// leaf — the project name is the only useful part on a narrow card, and the
    /// parent (`/Users/.../MyProjects`) is noise that truncates the leaf off-screen.
    /// A short relative path the seed author chose (`saha/task-03`, `~/quota`) is
    /// already legible, so it's kept verbatim.
    static func shortPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let leaf = (path as NSString).lastPathComponent
        return leaf.isEmpty ? path : leaf
    }

    /// Build an opaque sRGB colour from a 0xRRGGBB literal.
    static func hex(_ rgb: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
