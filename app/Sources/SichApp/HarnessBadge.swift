import AppKit
import SichCore

/// The visual harness identity: the agent's **official brand mark** (Anthropic /
/// OpenAI / Google Gemini, vendored as vector PDFs — see ``BoardTheme/agentMark(_:)``)
/// in one neutral ink (``BoardTheme/harnessMark``), replacing textual "Claude Code" / "Codex" labels
/// so which CLI drives a session is spottable at a glance without adding another chip.
///
/// It draws the mark itself in ``draw(_:)`` — a container view with a stock image
/// control does not paint reliably on this hand-painted UI (the iter-4 invisible-pill
/// defect), so the mark is composited directly by the view. The full name survives
/// as the tooltip.
@MainActor
final class HarnessBadge: NSView {
    private(set) var agent: CardAgent
    private var mark: NSImage?
    private var tint: NSColor = .clear

    init(agent: CardAgent) {
        self.agent = agent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 0
        yieldWidthToWindow()
        set(agent: agent)
    }

    required init?(coder: NSCoder) { nil }

    /// The silhouette stands alone at icon size; no repeated badge container.
    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    /// Re-point the badge at another harness (the drill-in header keeps one badge
    /// across focused cards).
    func set(agent: CardAgent) {
        self.agent = agent
        toolTip = agent.displayName
        mark = BoardTheme.agentMark(agent)
        tint = BoardTheme.harnessMark
        themedBackground = nil
        themedBorder = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let mark else { return }
        let side = min(15, min(bounds.width, bounds.height))
        let markRect = NSRect(
            x: (bounds.width - side) / 2, y: (bounds.height - side) / 2,
            width: side, height: side)
        // Tint in an isolated transparent image. Applying `.sourceAtop` directly in
        // this view would use the already-opaque card as its destination and paint a
        // solid square instead of respecting the PDF silhouette's alpha mask.
        let tinted = NSImage(size: markRect.size, flipped: false) { rect in
            mark.draw(in: rect)
            self.tint.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: markRect)
    }
}
