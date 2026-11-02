import AppKit
import CoreText
import SichCore

/// A **Ghostty-default-inspired** palette in one place so every board view stays
/// consistent. Its dark appearance grows outward from Ghostty's `#282c34`
/// blue-charcoal terminal and uses Ghostty's default ANSI colours for accents.
/// Semantic helpers (`stateColor`/
/// `flowColor`) keep the colour policy here, not smeared across views.
@MainActor
enum BoardTheme {
    // MARK: - Surfaces (theme-aware Ghostty blue-charcoal dark ramp / canonical
    // a neutral high-contrast light ramp — resolved per system appearance so the
    // whole board follows light/dark live, not just the terminal). Accents below are
    // deliberately shared across both modes.
    static let canvas = dynamic(dark: hex(0x20242B), light: hex(0xF1F4F7))          // cool page
    static let canvasSunken = dynamic(dark: hex(0x191D23), light: hex(0xE5EBF0))    // sunken tracks/rails
    static let cardFill = dynamic(dark: hex(0x282C34), light: hex(0xFFFFFF))        // Ghostty default / cards
    static let cardFillRaised = dynamic(dark: hex(0x323842), light: hex(0xF8FBFD))  // raised / hover
    static let cardStroke = dynamic(dark: hex(0x414956), light: hex(0xC8D2DA))      // cool light edge
    static let cardStrokeStrong = dynamic(dark: hex(0x596576), light: hex(0x9EACB8))
    static let hairline = dynamic(dark: hex(0x2C323B), light: hex(0xD3DCE3))

    // One signal. NEEDS YOU is the only column with a hue of its own; every other
    // lane and card sits on the plain canvas/card surface, and column position
    // alone says what a card is. The board's *focus* — where the operator should
    // look next — is a quiet brand tint on exactly one lane (see ``focusColumn``).

    /// The NEEDS YOU column's red-tinted background — the whole column reads red.
    static let needsYouColumn = dynamic(dark: hex(0x271F22), light: hex(0xFFF0F0))
    /// A NEEDS YOU card's red fill; stroke is `needs` (fresh) or `needsStroke` (aging).
    static let needsYouCard = dynamic(dark: hex(0x3A2226), light: hex(0xFFE8E8))
    /// The NEEDS YOU signal red — column title, card edge, "waiting" stamps.
    static let needs = hex(0xE84C3D)
    /// The deeper red an aging NEEDS YOU bar warms toward.
    static let needsStroke = hex(0xB52D22)
    /// The lit lane's surface: the canvas lifted a shade toward the brand blue.
    static let focusColumn = dynamic(
        dark: hex(0x20242B).blended(withFraction: 0.13, of: brand) ?? brand,
        light: hex(0xF1F4F7).blended(withFraction: 0.13, of: brand) ?? brand)
    /// The chosen row in a list you are picking from (the Ctrl+Tab switcher): the card
    /// surface lifted toward the brand blue, edged in it — the board's keyboard focus.
    static let selectionFill = dynamic(
        dark: hex(0x282C34).blended(withFraction: 0.30, of: brand) ?? brand,
        light: hex(0xFFFFFF).blended(withFraction: 0.22, of: brand) ?? brand)
    /// The veil behind the Ctrl+Tab switcher: the board stays readable, a step back.
    static let switcherScrim = dynamic(
        dark: NSColor.black.withAlphaComponent(0.35), light: NSColor.black.withAlphaComponent(0.18))
    /// The lit lane's title and count ink.
    static let focusInk = dynamic(dark: hex(0x7AA6DA), light: hex(0x1E6FB0))
    /// The band Claude paints behind each of the user's own prompts — a saturated
    /// brand blue so a prompt is findable at a glance while scrolling a transcript.
    /// Tuned to keep `termFg` legible on top (white on dark, ink on light).
    static let promptBand = dynamic(dark: hex(0x2F5E99), light: hex(0xC9DFF7))
    /// The unfilled part of a quota gauge — the groove the fill runs in. Must read as
    /// *recessed* against the panel in both modes, so it darkens the dark canvas and
    /// darkens the light one too (a lighter-than-paper groove would vanish).
    static let gaugeTrack = dynamic(dark: hex(0x1B1F26), light: hex(0xCBD5DD))
    /// Gauge fills are neutral and translucent — the text ink at three densities.
    /// A fuller pool is a touch lighter, an empty one a touch denser, so a panel of
    /// bars still says healthy / low / spent without competing with the board.
    static func gaugeFill(_ tone: QuotaCapacityTone) -> NSColor {
        switch tone {
        case .healthy: return textPrimary.withAlphaComponent(0.14)
        case .constrained: return textPrimary.withAlphaComponent(0.20)
        case .critical: return textPrimary.withAlphaComponent(0.30)
        case .unknown: return .clear
        }
    }
    /// The hairline ring around a gauge track, so the track edge stays visible where
    /// a translucent fill ends and two bars side by side never merge into one strip.
    static var gaugeRing: NSColor { textPrimary.withAlphaComponent(0.12) }
    /// Harness logos on cards and quota rows. One neutral ink: the silhouette
    /// already names the harness, and a brand colour per mark put Claude's orange
    /// on nearly every card — the same orange that means NEEDS YOU.
    static let harnessMark = dynamic(dark: hex(0xA3AAB5), light: hex(0x586975))

    // MARK: - Text (dark: light-on-dark; light: deliberately darker than Solarized
    // base greys so dense board labels stay readable on the neutral surface).
    static let textPrimary = dynamic(dark: hex(0xF0F2F5), light: hex(0x24313A))
    static let textMuted = dynamic(dark: hex(0xC5C8C6), light: hex(0x3A4A54))
    static let textFaint = dynamic(dark: hex(0x9299A5), light: hex(0x586975))
    /// Dimmest tier — card meta lines and footnotes.
    static let textDim = dynamic(dark: hex(0x747C89), light: hex(0x4F606B))

    // MARK: - Accents (Ghostty default ANSI family)
    /// The interactive brand blue — create affordance, drop ring. Kept distinct
    /// from the (deeper) running-state blue so a UI accent never reads as a state.
    static let brand = hex(0x7AA6DA)             // Ghostty bright blue
    /// Amber "needs you" accent — attention header/edge.
    static let attention = hex(0xD97A3A)         // solarized orange
    /// Cool cyan for inline `code` spans — deliberately distinct from the amber file-link
    /// color so identifiers and clickable paths never read as the same thing.
    /// Red for blocked/overdue accents.
    static let alert = hex(0xE84C3D)             // solarized red
    /// Muted violet for quota-spent cards — distinct from agent-error red and
    /// attention amber so "pool empty" reads at a glance without looking like
    /// "needs you".
    static let quotaBlocked = hex(0x9B7BB8)

    // MARK: - Terminal surface (Ghostty's zero-config dark console; neutral paper
    // in the light appearance — resolved per system appearance).
    static let termBg = dynamic(dark: hex(0x282C34), light: hex(0xFAFBFC))
    static let termFg = dynamic(dark: hex(0xFFFFFF), light: hex(0x24313A))
    static let termCursor = dynamic(dark: hex(0xFFFFFF), light: hex(0x009966))
    /// Underline ink for URLs/file paths detected in terminal output (item 9, 18.08).
    static let termLink = dynamic(dark: hex(0x61AFEF), light: hex(0x0969DA))

    // MARK: - Terminal ANSI palette
    //
    // The 16 colours a child's SGR indices (`\e[31m`, `ls --color`, any TUI) resolve
    // through. The dark ramp is Ghostty's zero-config palette so the embedded shell
    // looks at home beside a stock Ghostty window.
    //
    // The two ramps are NOT lighter/darker twins of each other. On the dark console a
    // "bright" colour is genuinely brighter; on light paper brightening would erase it,
    // so the light ramp's brights are *deeper and more saturated* instead — the
    // emphasis a program asks for, delivered the way paper delivers it. Same reason
    // light's white/bright-white (7/15) are text greys, not the near-white they are in
    // the dark ramp: canonical Solarized Light maps them onto the paper itself, where
    // `printf '\e[97mhi'` would come out invisible.

    /// ANSI order: black, red, green, yellow, blue, magenta, cyan, white, then the
    /// eight bright variants.
    private static let ansiDark = [
        hex(0x1D1F21), hex(0xCC6666), hex(0xB5BD68), hex(0xF0C674),
        hex(0x81A2BE), hex(0xB294BB), hex(0x8ABEB7), hex(0xC5C8C6),
        hex(0x666666), hex(0xD54E53), hex(0xB9CA4A), hex(0xE7C547),
        hex(0x7AA6DA), hex(0xC397D8), hex(0x70C0B1), hex(0xEAEAEA),
    ]

    private static let ansiLight = [
        hex(0x002B36), hex(0xB52D22), hex(0x4F6F00), hex(0x6F5200),
        hex(0x1E6FB0), hex(0xA8317B), hex(0x0E7C6E), hex(0x657B83),
        hex(0x24313A), hex(0xC93A30), hex(0x617A14), hex(0x866400),
        hex(0x3A9ADE), hex(0xC65A96), hex(0x20A896), hex(0x073642),
    ]

    /// The colour theme to push into a `Terminal` for `appearance`.
    ///
    /// The emulator lives below AppKit and wants plain RGB, so a `dynamic(dark:light:)`
    /// `NSColor` can't reach it — the appearance is resolved explicitly here instead.
    /// libghostty looks a cell's palette index up at read time, so re-applying this on
    /// a light/dark flip re-colours scrollback that was already written.
    static func terminalTheme(for appearance: NSAppearance) -> TerminalTheme {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return TerminalTheme(
            background: rgb(termBg, in: appearance),
            foreground: rgb(termFg, in: appearance),
            cursor: rgb(termCursor, in: appearance),
            ansi: (isDark ? ansiDark : ansiLight).map { rgb($0, in: appearance) }
        )
    }

    /// Resolve a (possibly dynamic) colour to plain sRGB bytes under `appearance`.
    static func rgb(_ color: NSColor, in appearance: NSAppearance) -> RGB {
        var out = RGB(r: 0, g: 0, b: 0)
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = color.usingColorSpace(.sRGB) else { return }
            out = RGB(r: UInt8((srgb.redComponent * 255).rounded()),
                      g: UInt8((srgb.greenComponent * 255).rounded()),
                      b: UInt8((srgb.blueComponent * 255).rounded()))
        }
        return out
    }

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

    /// The operator's manual zoom (⌘+ / ⌘−).
    static var boardFontScale: CGFloat = 1.0
    /// Automatic shrink applied on top of the manual zoom when the window is
    /// narrower than the 1400pt design width, so board text stops overflowing
    /// before it has to truncate. 1.0 on a full-width board, floored at 0.85.
    static var responsiveFontScale: CGFloat = 1.0

    /// The responsive factor for a given window content width, quantized to 0.05
    /// steps so a live resize only reflows the board when it crosses a step, not
    /// on every dragged pixel. Pure, so tests can pin the curve.
    static func responsiveScale(forContentWidth width: CGFloat) -> CGFloat {
        let raw = min(1.0, max(0.85, width / 1400))
        return (raw * 20).rounded(.toNearestOrAwayFromZero) / 20
    }

    /// Half-point steps: the column title (12.5) and card title (13.5) sit between
    /// the integer sizes, and rounding them away lost exactly the step they add.
    private static func scaled(_ size: CGFloat) -> CGFloat {
        (size * boardFontScale * responsiveFontScale * 2).rounded(.toNearestOrAwayFromZero) / 2
    }

    // Type policy: titles, project headers and done rows set in a monospace — the
    // titles are task slugs in a terminal tool, and the face matches the terminal
    // behind every card. Sans carries the remaining prose; numbers (counts, %,
    // durations, countdowns) set in SF Pro with tabular digits so they align and
    // change width-stably.

    static var mono: NSFont { .monospacedSystemFont(ofSize: scaled(11), weight: .regular) }
    static var monoBold: NSFont { .monospacedSystemFont(ofSize: scaled(11), weight: .semibold) }
    static var monoSmall: NSFont { .monospacedSystemFont(ofSize: scaled(10), weight: .regular) }
    /// Numeric data in SF Pro with tabular (fixed-width) digits.
    static var numeric: NSFont { .monospacedDigitSystemFont(ofSize: scaled(11), weight: .regular) }
    static var numericSmall: NSFont { .monospacedDigitSystemFont(ofSize: scaled(10), weight: .regular) }
    /// A countdown that matters now (imminent or exhausted) — weight, not hue, lifts it.
    static var numericSmallStrong: NSFont { .monospacedDigitSystemFont(ofSize: scaled(10), weight: .semibold) }
    /// The percent riding inside a quota bar — semibold so it holds up against the fill.
    static var gaugeLabel: NSFont { .monospacedDigitSystemFont(ofSize: scaled(11), weight: .semibold) }
    /// Column signage reads first: a step larger than card meta, bold, tracked wide
    /// (see ``caps(_:color:font:kern:)``).
    static var columnTitle: NSFont { .systemFont(ofSize: scaled(12.5), weight: .bold) }
    /// The lane's card count beside its title — always shown, `0` included.
    static var laneCount: NSFont { .monospacedDigitSystemFont(ofSize: scaled(12), weight: .medium) }
    /// The card headline — the title face at medium weight, the one line the
    /// operator reads across a full board.
    static var cardTitle: NSFont { titleMono(scaled(13.5), weight: .medium) }
    /// A finished card's title — a step below the live card headline, tracking zoom.
    static var doneTitle: NSFont { titleMono(scaled(13), weight: .regular) }
    /// The project header over a group of cards inside a lane.
    static var projectHeader: NSFont { titleMono(scaled(10.5), weight: .semibold) }

    /// The title face: JetBrains Mono, shipped in the bundle (OFL — see
    /// `Resources/JetBrainsMono-OFL.txt`) and registered for this process the first
    /// time a title font is asked for. SF Mono stands in if the files are missing, so
    /// a stripped bundle still draws every title in *a* mono.
    static func titleMono(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        _ = bundledFontsRegistered
        let face = weight == .semibold ? "JetBrainsMono-SemiBold"
            : weight == .medium ? "JetBrainsMono-Medium" : "JetBrainsMono-Regular"
        return NSFont(name: face, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static let bundledFontsRegistered: Bool = {
        var registered = false
        for face in ["JetBrainsMono-Regular", "JetBrainsMono-Medium", "JetBrainsMono-SemiBold"] {
            guard let url = resourceURL(face, ext: "ttf") else { continue }
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) { registered = true }
        }
        return registered
    }()
    static var sansSmall: NSFont { .systemFont(ofSize: scaled(11), weight: .medium) }
    static var sansTiny: NSFont { .systemFont(ofSize: scaled(10), weight: .regular) }
    /// The small chips on a card footer (host, quota, link).
    static var chip: NSFont { .systemFont(ofSize: scaled(10), weight: .medium) }

    /// An ALL-CAPS wayfinding label with letter tracking, e.g. column headers.
    /// Small caps want *positive* tracking — the one place the board adds it.
    static func caps(
        _ text: String, color: NSColor, font: NSFont = columnTitle, kern: CGFloat = 1.0
    ) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font, .kern: kern, .foregroundColor: color,
        ])
    }

    /// The smaller caps tier — the 5H / WEEKLY captions over the quota gauges.
    static var capsSmall: NSFont { .systemFont(ofSize: scaled(9.5), weight: .semibold) }

    /// The card headline as an attributed string — one font for EVERY title so
    /// the column scans as a uniform list, with slightly loosened leading so a
    /// wrapped mono title stays readable, and the tracking mono wants above 13pt.
    /// Word wrapping keeps slug titles breaking at their hyphens.
    static func cardTitleText(_ title: String, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let lineHeight = (cardTitle.pointSize * 1.3).rounded()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return NSAttributedString(string: title, attributes: [
            .font: cardTitle, .foregroundColor: color,
            .kern: -0.3, .paragraphStyle: paragraph,
        ])
    }

    // MARK: - Semantic colour (the policy lives here)

    /// The colour for a card's state stamp — one signal: only "needs you" carries a
    /// hue; every other state is the faint text ink. Column position says the rest.
    static func stateColor(_ state: CardState) -> NSColor {
        switch state {
        case .waitingForInput: return needs
        case .idle, .parked, .running, .runningTests, .blocked, .done, .unknown, .unreachable:
            return textFaint
        }
    }

    /// The harness's official brand mark — Anthropic's, OpenAI's, and Google
    /// Gemini's actual logos, vendored as vector PDFs under `Resources/` and rendered
    /// tinted by ``HarnessBadge``. Vector so a 16pt badge stays crisp on retina; a
    /// single silhouette per mark so ``harnessMark`` can tint it one neutral ink.
    /// Loaded once and cached — the PDF parse is not repeated per card.
    static func agentMark(_ agent: CardAgent) -> NSImage? {
        if let cached = markCache[agent] { return cached }
        let name: String
        switch agent {
        case .claude: name = "claude"
        case .codex: name = "codex"
        case .gemini: name = "gemini"
        case .cursor: name = "cursor"
        case .antigravity: name = "antigravity"
        }
        guard let url = markURL(name), let image = NSImage(contentsOf: url) else { return nil }
        markCache[agent] = image
        return image
    }

    /// Resolve a vendored mark, preferring the app bundle's own `Contents/Resources`.
    ///
    /// `Bundle.module` is SwiftPM-generated and falls back to the ABSOLUTE `.build`
    /// path of the machine that compiled it — fine under `swift run`, a hard
    /// `fatalError` inside a `.app` copied to anyone else's Mac. `make-app.sh` copies
    /// the marks into `Contents/Resources`, so the packaged app never reaches the
    /// module bundle; dev runs (no such resource in the main bundle) still do.
    private static func markURL(_ name: String) -> URL? { resourceURL(name, ext: "pdf") }

    private static func resourceURL(_ name: String, ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
    }

    private static var markCache: [CardAgent: NSImage] = [:]

    /// A text fallback for the mark, used where a real image can't be mounted (the
    /// creation palette's mono-glyph rows). Variation selectors pin text presentation
    /// so the glyph takes its colour instead of an emoji face.
    static func agentGlyph(_ agent: CardAgent) -> String {
        switch agent {
        case .claude: return "\u{2733}\u{FE0E}"   // ✳ starburst
        case .codex: return "\u{2B21}\u{FE0E}"    // ⬡ hexagon
        case .gemini: return "\u{2726}\u{FE0E}"   // ✦ spark
        case .cursor: return "\u{2B22}\u{FE0E}"   // ⬢ cube-ish hexagon
        case .antigravity: return "\u{25B2}\u{FE0E}"   // ▲ lift-off
        }
    }

    /// Display form of a card's project dir. A deep absolute path collapses to its
    /// leaf — the project name is the only useful part on a narrow card, and the
    /// parent (`/Users/.../MyProjects`) is noise that truncates the leaf off-screen.
    /// A short relative path the seed author chose (`feat/quota`, `~/quota`) is
    /// already legible, so it's kept verbatim. Used where the leaf itself needs to
    /// stay unique (e.g. an untitled card's fallback headline) — for "which repo
    /// is this" chips, see ``projectLabel(_:)`` instead.
    static func shortPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let leaf = (path as NSString).lastPathComponent
        return leaf.isEmpty ? path : leaf
    }

    /// "Which repo" label for a lane's project header. A `git worktree` checkout (this
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

    /// "Which repo" label for a card. A remote card files under the leaf of its
    /// far-side folder, so `box:~/work/a1-os` and `~/MyProjects/a1-os` sit under one
    /// `a1-os` header — the work is the same repo, wherever it runs. A remote card
    /// whose folder is still unknown falls back to its destination.
    static func projectLabel(for card: BoardCard) -> String {
        guard let destination = card.remoteDestination else {
            return projectLabel(card.projectDir)
        }
        return card.remoteDir.map(shortPath) ?? shortDestination(destination)
    }

    /// Display form of an ssh destination. The host keeps only its first DNS label —
    /// `roman@studio.tail00ee33.ts.net:2200` reads `roman@studio:2200` — because the
    /// tailnet / domain suffix is the same on every box and was what the ellipsis ate
    /// on a card. A bare IP keeps all of its dots.
    static func shortDestination(_ destination: String) -> String {
        var rest = Substring(destination)
        var user = ""
        if let at = rest.firstIndex(of: "@") {
            user = String(rest[...at])
            rest = rest[rest.index(after: at)...]
        }
        var port = ""
        if let colon = rest.lastIndex(of: ":") {
            port = String(rest[colon...])
            rest = rest[..<colon]
        }
        let first = rest.prefix { $0 != "." }
        let host = first.contains(where: \.isLetter) ? first : rest
        return user + host + port
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

/// Window-resize etiquette for board chrome. AppKit resolves a user's resize
/// drag at layout priority 510 and the window's "keep my size" preference at
/// 500, so any view defending its intrinsic width at the default 750 becomes an
/// unbreakable window minimum — and the board's equal-width columns multiply the
/// single worst card across all five, once wedging the window at 2053pt on an
/// 1800pt screen. Board text, buttons, and badges therefore yield just below the
/// window (490): they truncate or clip when the operator squeezes the window
/// instead of pinning its size.
extension NSView {
    /// Let a window resize squeeze this view horizontally. Long prose (card
    /// titles) passes `.defaultLow` so it gives way before the short metadata
    /// (ages, counts, chips) that stays legible longest.
    func yieldWidthToWindow(_ priority: NSLayoutConstraint.Priority = .init(490)) {
        setContentCompressionResistancePriority(priority, for: .horizontal)
    }
}
