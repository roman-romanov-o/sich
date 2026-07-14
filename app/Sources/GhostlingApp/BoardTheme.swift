import AppKit
import GhostlingCore

/// The **Solarized Osaka Night** palette in one place so every board view stays
/// consistent. Base tones and accents are the canonical Solarized Osaka Night
/// tokens (craftzdog's colour scheme): a blue-black base ramp (base04→base02)
/// under the classic Solarized accents. Semantic helpers (`stateColor`/
/// `flowColor`/`agentColor`) keep the colour policy here, not smeared across views.
@MainActor
enum BoardTheme {
    // MARK: - Surfaces (theme-aware Solarized: Osaka Night dark ramp / canonical
    // Solarized-light `base3→base2` ramp — resolved per system appearance so the
    // whole board follows light/dark live, not just the terminal). Accents below are
    // deliberately shared across both modes (Solarized accents are dual-scheme).
    static let canvas = dynamic(dark: hex(0x000D1A), light: hex(0xEEE8D5))          // base04 / base2
    static let canvasSunken = dynamic(dark: hex(0x00111F), light: hex(0xE4DCC5))    // sunken tracks/rails
    static let cardFill = dynamic(dark: hex(0x001A2E), light: hex(0xFDF6E3))        // cards above the canvas (base3 in light)
    static let cardFillRaised = dynamic(dark: hex(0x00304A), light: hex(0xFFFDF5))  // raised / hover
    static let documentSurface = dynamic(dark: hex(0x00182B), light: hex(0xFDF6E3))
    static let documentChrome = dynamic(dark: hex(0x00080F), light: hex(0xE4DCC5))  // chrome below the canvas
    static let cardStroke = dynamic(dark: hex(0x003D52), light: hex(0xD8CFB4))       // base02 / warm light edge
    static let cardStrokeStrong = dynamic(dark: hex(0x0A506B), light: hex(0xC4B998))
    static let hairline = dynamic(dark: hex(0x00263D), light: hex(0xDDD5BD))
    /// The NEEDS YOU column's warm-tinted background — the whole column reads amber.
    static let needsYouColumn = dynamic(dark: hex(0x1A0F03), light: hex(0xFBF0DC))
    /// A NEEDS YOU card's warm fill; stroke is `attention` (fresh) or `needsYouStroke` (aging).
    static let needsYouCard = dynamic(dark: hex(0x2B1908), light: hex(0xF7E6C8))
    static let needsYouStroke = hex(0xB35C1F)   // orange700 — shared accent
    /// A done card's faint green-tinted stroke.
    static let doneStroke = dynamic(dark: hex(0x1E2E0A), light: hex(0xCFE0A8))

    // MARK: - Text (Solarized base tones — dark: light-on-dark; light: base01→base1 on paper)
    static let textPrimary = dynamic(dark: hex(0xB3BAC4), light: hex(0x586E75))      // base1 / base01
    static let textMuted = dynamic(dark: hex(0x8794A0), light: hex(0x657B83))         // / base00
    static let textFaint = dynamic(dark: hex(0x667980), light: hex(0x93A1A1))         // base01 / base1
    static let documentText = dynamic(dark: hex(0xA6ADBA), light: hex(0x586E75))      // base0 / base01
    /// Dimmest tier — card meta lines and footnotes.
    static let textDim = dynamic(dark: hex(0x4A5A63), light: hex(0x93A1A1))

    // MARK: - Accents (Solarized accents)
    /// The interactive brand blue — create affordance, drop ring. Kept distinct
    /// from the (deeper) running-state blue so a UI accent never reads as a state.
    static let brand = hex(0x3A9ADE)             // solarized blue
    /// Amber "needs you" accent — attention header/edge.
    static let attention = hex(0xD97A3A)         // solarized orange
    /// Cool cyan for inline `code` spans — deliberately distinct from the amber file-link
    /// color so identifiers and clickable paths never read as the same thing.
    static let codeInline = hex(0x20A896)        // solarized cyan
    /// Red for blocked/overdue accents.
    static let alert = hex(0xE84C3D)             // solarized red
    /// Deeper crimson used ONLY as the global attention badge FILL, so its
    /// white text clears WCAG AA (the bright `alert` red at white text falls short).
    static let attentionBadge = hex(0xB0302A)

    // MARK: - Terminal surface (theme-aware: a rich Solarized console in the dark,
    // a warm Solarized-light paper one in the light — resolved per system appearance).
    static let termBg = dynamic(dark: hex(0x001F33), light: hex(0xF5F1E8))   // base03 / base3
    static let termFg = dynamic(dark: hex(0xA6ADBA), light: hex(0x556B72))   // base0 / base01
    static let termCursor = dynamic(dark: hex(0x20A896), light: hex(0x009966)) // cyan / cyan700

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
        case .idle: return hex(0x667980)      // base01
        case .running: return hex(0x3A9ADE)   // solarized blue — the "working" pulse
        case .runningTests: return hex(0x7A5FB8) // solarized violet
        case .waitingForInput: return hex(0xD97A3A) // solarized orange
        case .blocked: return hex(0xE84C3D)   // solarized red
        case .done: return hex(0x99CC00)      // solarized green
        case .unknown: return hex(0x728797)   // base00 — clears WCAG AA on the canvas
        }
    }

    /// Flow-A (saha / SDK) violet vs Flow-B (interactive) cyan — the two-flow cue.
    static func flowColor(_ flow: CardFlow) -> NSColor {
        flow == .a ? hex(0x7A5FB8) : hex(0x20A896)
    }

    /// Which agentic CLI drives the card — a small colour dot on the card face.
    static func agentColor(_ agent: CardAgent) -> NSColor {
        switch agent {
        case .claude: return hex(0xD97A3A)    // solarized orange
        case .codex: return hex(0x99CC00)     // solarized green
        case .gemini: return hex(0x3A9ADE)    // solarized blue
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
        hex(0x20A896), hex(0x3A9ADE), hex(0x7A5FB8), hex(0xD97A3A),
        hex(0x99CC00), hex(0xD4599F), hex(0xB39900), hex(0xE84C3D),
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
