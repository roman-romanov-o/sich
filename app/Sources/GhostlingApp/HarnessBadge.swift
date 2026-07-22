import AppKit
import GhostlingCore

/// The visual harness identity: the agent's **official brand mark** (Anthropic /
/// OpenAI / Google Gemini, vendored as vector PDFs — see ``BoardTheme/agentMark(_:)``)
/// tinted to its two-flow colour on a rounded chip, replacing textual "Claude Code" /
/// "Codex" labels so which CLI drives a session is spottable at a glance.
///
/// It draws the mark itself in ``draw(_:)`` — a container view with a stock image
/// control does not paint reliably on this hand-painted UI (the iter-4 invisible-pill
/// defect), so the chip fill rides ``themedBackground`` (a CALayer fill, flip-safe)
/// and the mark is composited on top. The full name survives as the tooltip.
@MainActor
final class HarnessBadge: NSView {
    private(set) var agent: CardAgent
    private var mark: NSImage?
    private var tint: NSColor = .clear

    init(agent: CardAgent) {
        self.agent = agent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 5
        yieldWidthToWindow()
        set(agent: agent)
    }

    required init?(coder: NSCoder) { nil }

    /// A fixed chip a touch wider than tall, giving the square mark side padding.
    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 16) }

    /// Re-point the badge at another harness (the drill-in header keeps one badge
    /// across focused cards).
    func set(agent: CardAgent) {
        self.agent = agent
        toolTip = agent.displayName
        mark = BoardTheme.agentMark(agent)
        tint = BoardTheme.agentColor(agent)
        themedBackground = tint.withAlphaComponent(0.14)
        themedBorder = tint.withAlphaComponent(0.40)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let mark else { return }
        // Square the mark inside the chip, inset so it never kisses the border.
        let side = min(bounds.width, bounds.height) - 5
        let markRect = NSRect(
            x: (bounds.width - side) / 2, y: (bounds.height - side) / 2,
            width: side, height: side)
        mark.draw(in: markRect)              // the black silhouette (with alpha)
        tint.set()
        markRect.fill(using: .sourceAtop)    // recolour only where the mark is opaque
    }
}
