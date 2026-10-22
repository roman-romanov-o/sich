import AppKit
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
    static let documentSurface = dynamic(dark: hex(0x282C34), light: hex(0xFFFFFF))
    static let documentChrome = dynamic(dark: hex(0x171A20), light: hex(0xE7EDF2))  // chrome below the canvas
    static let cardStroke = dynamic(dark: hex(0x414956), light: hex(0xC8D2DA))      // cool light edge
    static let cardStrokeStrong = dynamic(dark: hex(0x596576), light: hex(0x9EACB8))
    static let hairline = dynamic(dark: hex(0x2C323B), light: hex(0xD3DCE3))
    /// The NEEDS YOU column's warm-tinted background — the whole column reads amber.
    static let needsYouColumn = dynamic(dark: hex(0x272220), light: hex(0xFFF7E8))
    /// A NEEDS YOU card's warm fill; stroke is `attention` (fresh) or `needsYouStroke` (aging).
    static let needsYouCard = dynamic(dark: hex(0x3A2A1C), light: hex(0xFFF1D9))
    static let needsYouStroke = hex(0xB35C1F)   // orange700 — shared accent
    /// PARKED — shelved / deferred; quieter than QUEUE.
    static let parkedColumn = dynamic(dark: hex(0x1A1D22), light: hex(0xECEFF2))
    static let parkedCard = dynamic(dark: hex(0x252930), light: hex(0xF4F6F8))
    /// BLOCKED — waiting on someone/something outside the session (PR review, upstream).
    static let blockedColumn = dynamic(dark: hex(0x271F22), light: hex(0xFFF0F0))
    static let blockedCard = dynamic(dark: hex(0x3A2226), light: hex(0xFFE8E8))
    /// A card's surface carries its column's meaning: a WORKING card sits on a cool
    /// blue tint, a DONE card on a green one — so state reads before the title does.
    /// Only fills here; outlines are reserved for states that ask for the operator.
    static let workingCard = dynamic(dark: hex(0x252D3A), light: hex(0xEEF5FC))
    static let doneCard = dynamic(dark: hex(0x262C25), light: hex(0xF2F8EA))
    /// The unfilled part of a quota gauge — the groove the fill runs in. Must read as
    /// *recessed* against the panel in both modes, so it darkens the dark canvas and
    /// darkens the light one too (a lighter-than-paper groove would vanish).
    static let gaugeTrack = dynamic(dark: hex(0x1B1F26), light: hex(0xCBD5DD))
    /// Text drawn *on top of* a gauge fill. Every fill colour the bar can take (green
    /// `done`, orange `attention`, red `alert`) is bright in both appearances, so this
    /// stays a fixed near-black rather than flipping with the theme.
    static let gaugeLabelOnFill = hex(0x08121C)
    /// "Plenty left" — a calm sage, not the done-lime. Healthy capacity is the
    /// normal state of the quota panel, so it must be the quietest fill there;
    /// the orange/red tones are what the eye should find.
    static let healthy = hex(0x7FA06F)
    /// Harness logos on cards and quota rows. One neutral ink: the silhouette
    /// already names the harness, and a brand colour per mark put Claude's orange
    /// on nearly every card — the same orange that means NEEDS YOU.
    static let harnessMark = dynamic(dark: hex(0xA3AAB5), light: hex(0x586975))

    // MARK: - Text (dark: light-on-dark; light: deliberately darker than Solarized
    // base greys so dense board labels stay readable on the neutral surface).
    static let textPrimary = dynamic(dark: hex(0xF0F2F5), light: hex(0x24313A))
    static let textMuted = dynamic(dark: hex(0xC5C8C6), light: hex(0x3A4A54))
    static let textFaint = dynamic(dark: hex(0x9299A5), light: hex(0x586975))
    static let documentText = dynamic(dark: hex(0xE2E5E9), light: hex(0x24313A))
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
    static let codeInline = hex(0x20A896)        // solarized cyan
    /// Red for blocked/overdue accents.
    static let alert = hex(0xE84C3D)             // solarized red
    /// Muted violet for quota-spent cards — distinct from agent-error red and
    /// attention amber so "pool empty" reads at a glance without looking like
    /// "needs you".
    static let quotaBlocked = hex(0x9B7BB8)
    /// Deeper crimson used ONLY as the global attention badge FILL, so its
    /// white text clears WCAG AA (the bright `alert` red at white text falls short).
    static let attentionBadge = hex(0xB0302A)

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

    private static func scaled(_ size: CGFloat) -> CGFloat {
        (size * boardFontScale * responsiveFontScale).rounded(.toNearestOrAwayFromZero)
    }

    // Type policy: sans carries prose; numbers (counts, %, durations, countdowns)
    // set in SF Pro with tabular digits so they align and change width-stably
    // without switching typeface mid-line; SF Mono is reserved for code-shaped
    // text (commands, pool ids, the terminal). The card title anchors by SIZE, not weight — it is
    // the largest text on a card face at REGULAR weight. The title is the one
    // line the operator actually reads across a full board, and at medium a
    // column of them read as a wall of emphasis (8 Sep type study).

    static var mono: NSFont { .monospacedSystemFont(ofSize: scaled(11), weight: .regular) }
    static var monoBold: NSFont { .monospacedSystemFont(ofSize: scaled(11), weight: .semibold) }
    static var monoSmall: NSFont { .monospacedSystemFont(ofSize: scaled(10), weight: .regular) }
    /// Numeric data in SF Pro with tabular (fixed-width) digits.
    static var numeric: NSFont { .monospacedDigitSystemFont(ofSize: scaled(11), weight: .regular) }
    static var numericBold: NSFont { .monospacedDigitSystemFont(ofSize: scaled(11), weight: .semibold) }
    static var numericSmall: NSFont { .monospacedDigitSystemFont(ofSize: scaled(10), weight: .regular) }
    /// The percent riding inside a quota bar — semibold so it holds up against the fill.
    static var gaugeLabel: NSFont { .monospacedDigitSystemFont(ofSize: scaled(11), weight: .semibold) }
    static var title: NSFont { .systemFont(ofSize: scaled(13), weight: .semibold) }
    /// Column wayfinding caps — tracking (see ``caps(_:color:)``), not weight,
    /// does the work, so headers stop competing with card titles.
    static var columnTitle: NSFont { .systemFont(ofSize: scaled(11), weight: .semibold) }
    /// The card headline — the size anchor on a card face (see type policy above).
    static var cardTitle: NSFont { .systemFont(ofSize: scaled(15), weight: .regular) }
    /// A finished card's title — a step below the live card headline, tracking zoom.
    static var doneTitle: NSFont { .systemFont(ofSize: scaled(13), weight: .regular) }
    static var sansSmall: NSFont { .systemFont(ofSize: scaled(11), weight: .medium) }
    static var sansTiny: NSFont { .systemFont(ofSize: scaled(10), weight: .regular) }
    /// Sans prose emphasis — advisory headlines. Prose never sets in mono.
    static var sansStrong: NSFont { .systemFont(ofSize: scaled(12), weight: .semibold) }
    /// Sans prose body — advisory detail lines.
    static var sansBody: NSFont { .systemFont(ofSize: scaled(11), weight: .regular) }
    /// The project chip on a card — tiny; the project colour carries the identity.
    static var chip: NSFont { .systemFont(ofSize: scaled(10), weight: .medium) }

    /// An ALL-CAPS wayfinding label with letter tracking, e.g. column headers.
    /// Small caps want *positive* tracking — the one place the board adds it.
    static func caps(_ text: String, color: NSColor, font: NSFont = columnTitle) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font, .kern: 0.6, .foregroundColor: color,
        ])
    }

    /// The smaller caps tier — table headers inside a panel (quota LEFT / 5H / WEEKLY).
    static var capsSmall: NSFont { .systemFont(ofSize: scaled(10), weight: .semibold) }

    /// The card headline as an attributed string — one font for EVERY title so
    /// the column scans as a uniform list, with tightened two-line leading (SF
    /// wants slightly negative tracking above 13pt, and the default leading lets
    /// a wrapped title float apart). Word wrapping keeps slug titles breaking at
    /// their hyphens.
    static func cardTitleText(_ title: String, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let lineHeight = (cardTitle.pointSize * 1.15).rounded()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return NSAttributedString(string: title, attributes: [
            .font: cardTitle, .foregroundColor: color,
            .kern: -0.2, .paragraphStyle: paragraph,
        ])
    }

    /// Prose set in sans with its embedded tokens picked out: `/commands` in SF
    /// Mono (they are code), percentages and durations in tabular-digit SF Pro
    /// (they are numbers — same face as the prose, steady width).
    static func prose(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color])
        let range = NSRange(text.startIndex..., in: text)
        let styles: [(pattern: String, font: NSFont)] = [
            (#"/[\w:-]+"#, .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)),
            (#"\d+(?:\.\d+)?%|\d+[dhm]\b"#,
             .monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)),
        ]
        for style in styles {
            guard let regex = try? NSRegularExpression(pattern: style.pattern) else { continue }
            for match in regex.matches(in: text, range: range) {
                result.addAttribute(.font, value: style.font, range: match.range)
            }
        }
        return result
    }

    // MARK: - Semantic colour (the policy lives here)

    /// The colour for a card's state rail / chip — the at-a-glance lifecycle cue.
    static func stateColor(_ state: CardState) -> NSColor {
        switch state {
        case .idle: return hex(0x667980)      // base01
        case .parked: return hex(0x728797)   // base00 — shelved, not loud
        case .running: return hex(0x3A9ADE)   // solarized blue — the "working" pulse
        case .runningTests: return hex(0x7A5FB8) // solarized violet
        case .waitingForInput: return hex(0xD97A3A) // solarized orange
        case .blocked: return hex(0xE84C3D)   // solarized red
        case .done: return hex(0x99CC00)      // solarized green
        case .unknown: return hex(0x728797)   // base00 — clears WCAG AA on the canvas
        // A dead link reads in the alert red — the same "something is wrong" ink as
        // `blocked`, and deliberately nowhere near `done`'s green or `unknown`'s
        // grey, which are the two readings it must never be mistaken for (US-007 AC-4).
        case .unreachable: return alert
        }
    }

    /// Flow-A (saha / SDK) violet vs Flow-B (interactive) cyan — the two-flow cue.
    static func flowColor(_ flow: CardFlow) -> NSColor {
        flow == .a ? hex(0x7A5FB8) : hex(0x20A896)
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
    private static func markURL(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "pdf") { return url }
        return Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "Resources")
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

    /// Stable per-repo chip colour, assigned first-seen-first-slot. Hash-bucketing
    /// (the old FNV-1a scheme) let two repos on one board collide on a hue; walking
    /// the palette in discovery order guarantees the first 8 distinct repos all
    /// read differently, and only a 9th wraps. Keyed on ``projectLabel(_:)`` (not
    /// ``shortPath(_:)``) so every `git worktree` of the same repo shares one
    /// colour instead of each task/branch minting its own.
    static func repoColor(_ path: String) -> NSColor {
        color(forKey: projectLabel((path as NSString).standardizingPath))
    }

    /// The card-aware variant. An owned remote-tmux card's `projectDir` is its
    /// `user@host` label, so keying on it would give every session on one box the
    /// same hue and never the hue of the project itself. A card linked via
    /// ``linkProject(card:toDirectory:)`` keys on the REMOTE directory's trailing
    /// name instead — the same key a local checkout of that project produces — so
    /// "sahaidachny here" and "sahaidachny on the mac studio" read as one project.
    static func repoColor(for card: BoardCard) -> NSColor {
        if let key = projectLinkByCard[card.id] { return color(forKey: key) }
        return repoColor(card.projectDir)
    }

    /// Link a remote card to its project by the trailing name of its far-side
    /// working directory. A `nil`/root/`~` dir carries no project name — the card
    /// keeps its host-label hue.
    static func linkProject(card id: UUID, toDirectory dir: String?) {
        let leaf = ((dir ?? "") as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != "~", leaf != "/" else { return }
        projectLinkByCard[id] = leaf
    }

    private static var projectLinkByCard: [UUID: String] = [:]

    /// One key → one palette slot, first-seen-first-slot, and the assignment is
    /// durable: the slot map persists in `UserDefaults`, so a project keeps its
    /// colour across relaunches instead of re-rolling by discovery order.
    private static func color(forKey key: String) -> NSColor {
        var slots = repoColorSlots
            ?? (repoColorDefaults.dictionary(forKey: repoColorSlotsKey) as? [String: Int] ?? [:])
        defer { repoColorSlots = slots }
        if let slot = slots[key] {
            return repoPalette[slot % repoPalette.count]
        }
        let slot = slots.count
        slots[key] = slot
        repoColorDefaults.set(slots, forKey: repoColorSlotsKey)
        return repoPalette[slot % repoPalette.count]
    }

    /// Injectable store (same seam as `RecentFolderStore`) so tests run against a
    /// throwaway suite instead of the developer's real defaults.
    static var repoColorDefaults: UserDefaults = .standard {
        didSet { repoColorSlots = nil }
    }
    private static let repoColorSlotsKey = "sich.repoColorSlots"
    private static var repoColorSlots: [String: Int]?
    /// Muted identity hues that stay clear of every *semantic* hue on the board —
    /// no attention orange, alert red, done green, running blue or test violet — so
    /// a project label can never be read as a card's state.
    private static let repoPalette = [
        hex(0x4FB3A9), hex(0xC678A8), hex(0xC9A64B), hex(0x9C8FD6),
        hex(0x5FA8B8), hex(0x93A97A), hex(0xC98F91), hex(0xB39E82),
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
