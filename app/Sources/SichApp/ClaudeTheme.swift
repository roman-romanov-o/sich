import AppKit
import SichCore

/// Claude Code's own TUI palette, scoped to Sich-owned terminals.
///
/// Claude resolves `theme` out of its merged settings, and the Sich `claude`
/// shim already hands it a per-invocation `--settings` blob that exists only
/// inside a managed terminal (`SICH_CARD_ID`). Riding that same blob is what
/// makes this a *board* theme rather than a machine-wide one — the operator's
/// own terminal Claude keeps whatever they picked in `/theme`.
///
/// A custom Claude theme is a file: `~/.claude/themes/<slug>.json`, shaped
/// `{name, base, overrides}`, referenced from settings as `custom:<slug>`
/// (the bare slug is not a valid reference). Claude watches that directory, so
/// rewriting the file re-colours sessions that are already open.
///
/// The palette is derived from ``BoardTheme`` instead of being authored a
/// second time. The child draws on OUR terminal background with OUR ANSI ramp,
/// so accents chosen anywhere else would be contrast-checked against a surface
/// that isn't there — and would strand light-console colours on dark paper the
/// moment the system appearance flips.
@MainActor
enum ClaudeTheme {
    /// Theme file name and the `custom:` reference share this one slug.
    nonisolated static let slug = "sich"

    /// What the shim injects as Claude's `theme` setting.
    nonisolated static let settingsRef = "custom:\(slug)"

    static func themeFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".claude/themes/\(slug).json")
    }

    /// The theme document for `appearance`.
    ///
    /// Only tokens the board actually has an opinion about are overridden; the
    /// rest (diff fills, subagent hues, rate-limit bars) inherit from `base`,
    /// which already tracks light/dark.
    static func document(for appearance: NSAppearance) -> [String: Any] {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ramp = BoardTheme.terminalTheme(for: appearance).palette
        func hue(_ ansiIndex: Int) -> String { css(ramp[ansiIndex]) }
        func token(_ color: NSColor) -> String { css(BoardTheme.rgb(color, in: appearance)) }

        return [
            "name": "Sich",
            "base": isDark ? "dark" : "light",
            "overrides": [
                // Ink and paper: the same pair the emulator is painting with.
                "text": token(BoardTheme.termFg),
                "inverseText": token(BoardTheme.termBg),
                "inactive": token(BoardTheme.textDim),
                "inactiveShimmer": token(BoardTheme.textFaint),
                "subtle": token(BoardTheme.textFaint),
                "promptBorder": token(BoardTheme.cardStrokeStrong),
                "promptBorderShimmer": token(BoardTheme.cardStroke),
                // Claude's own brand mark stays the board's attention orange, so a
                // card that wants you and the spinner that made it want you match.
                "claude": token(BoardTheme.attention),
                "claudeShimmer": token(BoardTheme.attention),
                // Hues come from the ANSI ramp this terminal already resolves for
                // the appearance, so they are contrast-tuned for its background.
                "permission": hue(4),
                "permissionShimmer": hue(12),
                "suggestion": hue(4),
                "ide": hue(4),
                "remember": hue(5),
                "bashBorder": hue(5),
                "merged": hue(5),
                "planMode": hue(6),
                "success": hue(2),
                "error": hue(1),
                "warning": hue(3),
                "warningShimmer": hue(11),
            ],
        ]
    }

    /// Write the theme for `appearance`, creating `~/.claude/themes` if needed.
    ///
    /// Skips the write when the bytes are unchanged — Claude watches the themes
    /// directory, and a rewrite on every appearance query would have every open
    /// session reload its palette for nothing.
    ///
    /// - Returns: true when the file was (re)written.
    @discardableResult
    static func install(for appearance: NSAppearance,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let file = themeFile(home: home)
        guard let data = try? JSONSerialization.data(
            withJSONObject: document(for: appearance),
            options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        if let existing = try? Data(contentsOf: file), existing == data { return false }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    /// Claude parses theme colours as `rgb(r,g,b)`, the same syntax its built-in
    /// themes are written in.
    private static func css(_ color: RGB) -> String {
        "rgb(\(color.r),\(color.g),\(color.b))"
    }
}
