import AppKit
import GhostlingCore

/// The Deep Slate / Aurora palette in one place so every board view stays
/// consistent (replaces the old near-black HELM greys). Hex tokens straight from
/// the designer deliverable; semantic helpers (`stateColor`/`flowColor`/
/// `agentColor`) keep the colour policy here, not smeared across the views.
@MainActor
enum BoardTheme {
    // MARK: - Surfaces (Mission Control v5 palette)
    static let canvas = hex(0x0B0E12)
    static let canvasSunken = hex(0x0D1117)
    static let cardFill = hex(0x12161C)
    static let cardFillRaised = hex(0x1C232D)
    static let documentSurface = hex(0x11161D)
    static let documentChrome = hex(0x090C10)
    static let cardStroke = hex(0x232A33)
    static let cardStrokeStrong = hex(0x2B3542)
    static let hairline = hex(0x1A212B)
    /// The NEEDS YOU column's warm-tinted background — the whole column reads amber.
    static let needsYouColumn = hex(0x0E0C09)
    /// A NEEDS YOU card's warm fill; stroke is `attention` (fresh) or `needsYouStroke` (aging).
    static let needsYouCard = hex(0x1C1610)
    static let needsYouStroke = hex(0x6B4A1F)
    /// A done card's faint green-tinted stroke.
    static let doneStroke = hex(0x1E2A22)

    // MARK: - Text
    static let textPrimary = hex(0xE6EDF3)
    static let textMuted = hex(0x9AA4B2)
    static let textFaint = hex(0x7D8590)
    static let documentText = hex(0xD7DEE8)
    /// Dimmest tier — card meta lines and footnotes (POC #4d5560).
    static let textDim = hex(0x4D5560)

    // MARK: - Accents
    /// The interactive brand blue — create affordance, drop ring. Kept distinct
    /// from the (deeper) running-state blue so a UI accent never reads as a state.
    static let brand = hex(0x4B8DF8)
    /// Amber "needs you" accent — attention header/edge.
    static let attention = hex(0xE3A13C)
    /// Cool cyan for inline `code` spans — deliberately distinct from the amber file-link
    /// color so identifiers and clickable paths never read as the same thing.
    static let codeInline = hex(0x79C0C9)
    /// Red for blocked/overdue accents.
    static let alert = hex(0xF85149)
    /// Deeper crimson used ONLY as the global attention badge FILL, so its
    /// white text clears WCAG AA (the coral `alert` at white text is only 3.49:1).
    static let attentionBadge = hex(0xB8392E)

    // MARK: - Terminal surface (theme-aware: a rich console in the dark, a clean
    // paper-white one in the light — resolved per the system appearance at draw time).
    static let termBg = dynamic(dark: hex(0x0D1119), light: hex(0xFBFAF7))
    static let termFg = dynamic(dark: hex(0xCDD6E4), light: hex(0x2E3138))
    static let termCursor = dynamic(dark: hex(0x2DD4BF), light: hex(0x0D9488))

    /// An NSColor that resolves to `dark` under a dark appearance and `light` under a
    /// light one — the standard way to be system-theme-aware without duplicating views.
    /// Resolves at draw time in the current view's appearance, so `.setFill()` / a
    /// stored `.foregroundColor` just work.
    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    // MARK: - Fonts
    static let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let monoBold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    static let monoSmall = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let title = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let columnTitle = NSFont.systemFont(ofSize: 13, weight: .heavy)
    /// The card headline (POC: 16px/600; 15pt reads the same at AppKit metrics).
    static let cardTitle = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let sansSmall = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let sansTiny = NSFont.systemFont(ofSize: 10, weight: .regular)

    // MARK: - Semantic colour (the policy lives here)

    /// The colour for a card's state rail / chip — the at-a-glance lifecycle cue.
    static func stateColor(_ state: CardState) -> NSColor {
        switch state {
        case .idle: return hex(0x6B7686)
        case .running: return hex(0x4CC2FF)   // the POC's "working" pulse blue
        case .runningTests: return hex(0xA06BFF)
        case .waitingForInput: return hex(0xE3A13C)
        case .blocked: return hex(0xF85149)
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

    /// Stable per-repo chip colour, assigned first-seen-first-slot. Hash-bucketing
    /// (the old FNV-1a scheme) let two repos on one board collide on a hue; walking
    /// the palette in discovery order guarantees the first 8 distinct repos all
    /// read differently, and only a 9th wraps. Keyed on ``projectLabel(_:)`` (not
    /// ``shortPath(_:)``) so every `git worktree` of the same repo shares one
    /// colour instead of each task/branch minting its own.
    static func repoColor(_ path: String) -> NSColor {
        let key = projectLabel((path as NSString).standardizingPath)
        if let slot = repoColorSlots[key] {
            return repoPalette[slot % repoPalette.count]
        }
        let slot = repoColorSlots.count
        repoColorSlots[key] = slot
        return repoPalette[slot % repoPalette.count]
    }

    private static var repoColorSlots: [String: Int] = [:]
    private static let repoPalette = [
        hex(0x2DD4BF), hex(0x4CC2FF), hex(0xA06BFF), hex(0xE3A13C),
        hex(0x3FB950), hex(0xF778BA), hex(0x79C0C9), hex(0xD9893E),
    ]

    /// Display form of a card's project dir. A deep absolute path collapses to its
    /// leaf — the project name is the only useful part on a narrow card, and the
    /// parent (`/Users/.../MyProjects`) is noise that truncates the leaf off-screen.
    /// A short relative path the seed author chose (`saha/task-03`, `~/quota`) is
    /// already legible, so it's kept verbatim. Used where the leaf itself needs to
    /// stay unique (e.g. an untitled card's fallback headline) — for "which repo
    /// is this" chips, see ``projectLabel(_:)`` instead.
    static func shortPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let leaf = (path as NSString).lastPathComponent
        return leaf.isEmpty ? path : leaf
    }

    /// "Which repo" label for the repo chip. A `git worktree` checkout (this
    /// project's own model for parallel task sessions) has a leaf that's just the
    /// branch/task slug — e.g. `ui-fixes` — which repeats the card's own title
    /// and never says which repo the work is actually in. Resolves through
    /// ``GitWorktree`` to the main repo's name; falls back to ``shortPath(_:)``
    /// for a plain checkout or non-repo dir.
    static func projectLabel(_ path: String) -> String {
        guard path.hasPrefix("/"), let mainRepoRoot = GitWorktree.mainRepoRoot(of: path) else {
            return shortPath(path)
        }
        let repoLeaf = (mainRepoRoot as NSString).lastPathComponent
        return repoLeaf.isEmpty ? shortPath(path) : repoLeaf
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
