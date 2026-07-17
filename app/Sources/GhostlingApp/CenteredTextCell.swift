import AppKit

/// Draws a single-line label's text in the vertical centre of its frame.
///
/// Every pill on this UI (``BackPill``, ``StatusPill``, ``WorktreePill``,
/// ``ChooserButton``, ``PlanningStepButton``, ``PlanningActionPill``) is a
/// layer-backed `NSTextField` that pins a fixed `intrinsicContentSize.height` to get
/// its pill shape — 26pt around a 15pt line, say. `NSTextFieldCell` spends that slack
/// entirely above the line, so the text sits low in its own fill: measured on the
/// 26pt back pill, 13pt of gap above the ink and 3pt below it.
///
/// Enclosing the pills in a `.centerY` stack does not help — the drill-in header
/// already does — because each pill's *frame* is centred correctly. It is the text
/// inside the frame that is not. Assigning this cell centres the line; the fill,
/// border and radius are untouched.
final class CenteredTextCell: NSTextFieldCell {
    /// Shrink the drawing rect to one line and re-centre it. Every other layout the
    /// cell does (the title rect, the editor's frame) derives from this one rect, so
    /// overriding here centres drawing *and* keeps hit-testing consistent — where
    /// overriding `titleRect` alone only moved the text and left the rest behind.
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawing = super.drawingRect(forBounds: rect)
        let slack = drawing.height - cellSize(forBounds: rect).height
        guard slack > 0 else { return drawing }
        drawing.size.height -= slack
        drawing.origin.y += slack / 2
        return drawing
    }
}

@MainActor
extension NSTextField {
    /// Centre this field's text vertically within its frame.
    ///
    /// Call it FIRST, immediately after `super.init(frame:)`: assigning `cell` replaces
    /// the field's entire cell, so any styling set beforehand would be discarded.
    func useCenteredTextCell() {
        let centered = CenteredTextCell()
        centered.isBezeled = false
        centered.isEditable = false
        centered.isSelectable = false
        centered.drawsBackground = false
        // NOT `usesSingleLineMode` — it switches the cell to a layout path that pins the
        // baseline and ignores `drawingRect`, which measures as text jammed against the
        // pill's bottom edge (gapTop 17 / gapBot 0 on the 26pt back pill).
        centered.lineBreakMode = .byTruncatingTail
        cell = centered
    }
}
