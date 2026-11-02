import AppKit

/// A custom-drawn back affordance (US-002 AC#2): a rounded "← board" pill that
/// returns to the board on click. It is the EXACT view kind ``SessionCard``'s
/// `flowBadge` is — a **layer-backed `NSTextField`** that draws its own text *and*
/// background on a single view (`wantsLayer` + a `themedBackground` layer fill +
/// `cornerRadius`, `drawsBackground = false`). That is the only render path proven
/// to composite on this hand-painted dark UI: every card shows its flow badge this
/// way.
///
/// The previous attempt was a container `NSView` with a *child* label. It laid out
/// (so it was clickable — `hitTest` returns `self` for any in-bounds point) but did
/// not paint, which is exactly the "I can't see the pill, but clicking its area
/// works" defect the operator reported in iter 4. Collapsing it back to the single
/// layer-backed text field removes the container/child indirection entirely.
/// Single responsibility: look like a button and report its click.
@MainActor
final class BackPill: NSTextField {
    /// Invoked on click — the page wires this to return to the board.
    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        useCenteredTextCell()              // 26pt pill around a 15pt line — centre it
        stringValue = "← board"
        font = BoardTheme.monoBold
        textColor = BoardTheme.textPrimary
        alignment = .center
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false            // the LAYER paints the fill, like flowBadge
        wantsLayer = true
        themedBackground = BoardTheme.cardFillRaised
        layer?.cornerRadius = 6
        layer?.borderWidth = 0
    }

    required init?(coder: NSCoder) { nil }

    /// Pointing-hand cursor over the whole pill so it reads as clickable.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Pad the intrinsic text size into a pill shape (the badge uses a fixed width;
    /// the back affordance sizes to its label + horizontal padding instead).
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 24
        size.height = 26
        return size
    }

    /// Treat the whole pill as one click target, the way a button behaves — so a
    /// hit-test test can assert the pill (not the surface) owns the point.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// The click path (US-002 AC#2). `SessionCard.mouseDown` proves this idiom
    /// works on screen — the operator drills in by clicking a card the same way.
    /// (A non-editable, non-selectable label does not start editing on click, so
    /// overriding without calling `super` is safe.)
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
