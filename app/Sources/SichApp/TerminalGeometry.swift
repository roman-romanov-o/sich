import Foundation

/// Checklist 18.08, item 8 ("faster entering the task"): every session used to spawn
/// at the pty default 24×80, so the FIRST drill-in forced a big resize and the child
/// (a full-screen claude TUI, or an ssh+tmux round trip) reflowed while the operator
/// waited. The board remembers the drill-in viewport's real grid instead, and every
/// spawn adopts it — entering a task becomes a no-op resize: the screen is already
/// the right shape and paints on the first frame.
@MainActor
enum TerminalGeometry {

    /// Injectable so tests never read or pollute the operator's real defaults —
    /// the same seam idiom as `BoardTheme.repoColorDefaults`.
    static var defaults: UserDefaults = .standard

    private static let key = "sich.terminalGeometry"

    /// The pty stack's own defaults; used until a drill-in has taught a real size.
    static let fallback: (rows: UInt16, cols: UInt16) = (24, 80)

    /// The grid every new session should spawn at: the last size a real drill-in
    /// terminal settled on, or the classic 24×80 before any has.
    static var preferred: (rows: UInt16, cols: UInt16) {
        guard let dict = defaults.dictionary(forKey: key),
              let rows = dict["rows"] as? Int, let cols = dict["cols"] as? Int,
              (1...512).contains(rows), (1...1024).contains(cols) else { return fallback }
        return (UInt16(rows), UInt16(cols))
    }

    /// Called by the drill-in surface (and only it) whenever its layout settles on
    /// a grid — the next spawn starts life already that shape.
    static func remember(rows: UInt16, cols: UInt16) {
        guard rows > 0, cols > 0 else { return }
        defaults.set(["rows": Int(rows), "cols": Int(cols)], forKey: key)
    }
}
