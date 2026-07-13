import AppKit
import GhostlingCore

/// The board-header attention signal (US-005 AC#1). It renders the
/// `Attention.count` and reads quiet/zero with no false alarm when nothing needs
/// the operator (AC#3). Clicking it (when non-zero) routes to the waiting/blocked
/// cards (AC#2) via ``onActivate``. Single responsibility: present the count and
/// report activation — it derives nothing it isn't handed.
@MainActor
final class AttentionIndicator: NSView {
    /// Invoked when the operator activates a non-zero indicator (US-005 AC#2).
    var onActivate: (() -> Void)?

    /// The last count handed to ``update(count:)``. The always-visible attention
    /// badge is what US-005 asserts stays correct while drilled in, so this is the
    /// deterministic seam a test reads to prove the board re-rendered on a live
    /// change — no wall-clock latency (TC-INT-015).
    private(set) var renderedCount = 0

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        buildLabel()
        update(count: 0)
    }

    required init?(coder: NSCoder) { nil }

    private func buildLabel() {
        label.font = BoardTheme.monoBold
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Re-render for a new count. Zero is the quiet state: muted text, no badge
    /// fill, not clickable — the explicit no-false-alarm read (US-005 AC#3).
    func update(count: Int) {
        renderedCount = count
        if count == 0 {
            label.stringValue = ""
            label.textColor = BoardTheme.textFaint
            layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            label.stringValue = "⚠ \(count)"
            label.textColor = NSColor.white
            layer?.backgroundColor = BoardTheme.attentionBadge.cgColor  // white-on-fill clears AA
        }
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }
}
