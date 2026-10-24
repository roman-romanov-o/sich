import AppKit
import Testing

@testable import SichApp

/// The bug these pin down: every pill on this UI forces a fixed
/// `intrinsicContentSize.height` (26 for the back pill, 22 for the status pill, …) to
/// get its shape, and `NSTextFieldCell` spends all of that slack *above* the line — so
/// the text sat low inside its own fill. On the 26pt back pill: 13pt of gap above the
/// ink, 3pt below it.
///
/// These measure where the glyphs actually land, by rendering each pill through the
/// production draw path (`cell.draw(withFrame:in:)` — the entry `NSTextField` itself
/// uses) and finding the topmost and bottommost inked row. Asserting on a layout rect
/// instead would be non-evidence: an earlier version of this suite compared
/// `titleRect.midY` to `bounds.midY`, which is trivially equal for the *unfixed* cell
/// too, and so passed against known-broken code.
///
/// ``inkGaps`` is self-checked by ``theProbeItselfIsHonest`` — a probe that can't see a
/// real miscentring would make every test here pass for the wrong reason.
@MainActor
@Suite("Pill labels draw their text vertically centred")
struct PillTextCenteringTests {

    /// Points of blank space above and below the drawn glyphs, when the field is drawn
    /// at `height` (default: the height it asks for).
    ///
    /// The bitmap context is flipped to match the field's own flipped coordinates;
    /// without that, row 0 is the *bottom* edge and every reading comes out mirrored.
    private func inkGaps(_ field: NSTextField, height forced: CGFloat? = nil) -> (top: Int, bottom: Int)? {
        var size = field.intrinsicContentSize
        if let forced { size.height = forced }
        field.frame = NSRect(origin: .zero, size: size)
        let width = Int(field.bounds.width), height = Int(field.bounds.height)
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if field.isFlipped {
            context.cgContext.translateBy(x: 0, y: CGFloat(height))
            context.cgContext.scaleBy(x: 1, y: -1)
        }
        NSGraphicsContext.current = context
        field.cell?.draw(withFrame: field.bounds, in: field)

        let inked = (0..<height).filter { y in
            (0..<width).contains { x in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 }
        }
        guard let first = inked.first, let last = inked.last else { return nil }
        return (first, height - 1 - last)
    }

    /// Assert the pill's padding is spent evenly above and below its line.
    ///
    /// Measured against the pill's OWN tight-sized baseline rather than against a bare
    /// "gapTop == gapBottom", because glyph ink is not symmetric about the line: a word
    /// with a descender ("Approve") inks lower in its line box than one without
    /// ("← board"), so a correctly centred pill can still show a 2pt ink skew. Taking
    /// the difference cancels that out and leaves only the imbalance the padding added
    /// — which is the defect, and which was ~10pt.
    private func expectPaddingSpentEvenly(_ field: NSTextField, _ name: String) {
        let line = (field.cell?.cellSize.height).map { ($0).rounded(.up) } ?? 0
        guard let padded = inkGaps(field), let tight = inkGaps(field, height: line) else {
            Issue.record("\(name): nothing was drawn")
            return
        }
        let added = (padded.top - padded.bottom) - (tight.top - tight.bottom)
        #expect(abs(added) <= 1,
                """
                \(name) text is off-centre by \(added)pt: \(padded.top)pt above the ink \
                and \(padded.bottom)pt below, where its own line only skews \
                \(tight.top - tight.bottom)pt.
                """)
    }

    /// The probe has to be able to SEE a miscentring, or every test below passes for
    /// free. A stock label padded to 26pt is the known-broken case this whole suite
    /// exists for, so it must read as badly off-centre.
    @Test("the probe itself is honest: a stock padded label reads as badly off-centre")
    func theProbeItselfIsHonest() {
        let stock = StubPill(height: 26)
        guard let padded = inkGaps(stock), let tight = inkGaps(stock, height: 15) else {
            Issue.record("probe drew nothing")
            return
        }
        let added = (padded.top - padded.bottom) - (tight.top - tight.bottom)
        #expect(added > 4,
                """
                The probe must SEE the unfixed render path as broken, or every test here \
                passes for free. A stock 26pt label skewed only \(added)pt.
                """)
    }

    @Test("the back pill's label sits in the middle of its 26pt frame")
    func backPillIsCentered() {
        expectPaddingSpentEvenly(BackPill(), "BackPill")
    }

    @Test("the status pill's label sits in the middle of its 22pt frame")
    func statusPillIsCentered() {
        let pill = StatusPill()
        pill.show(text: "unknown", color: BoardTheme.textDim, pulsing: false)
        expectPaddingSpentEvenly(pill, "StatusPill")
    }

    @Test("the worktree pill's label sits in the middle of its 20pt frame")
    func worktreePillIsCentered() {
        let pill = WorktreePill()
        pill.stringValue = "worktree"
        expectPaddingSpentEvenly(pill, "WorktreePill")
    }
}

/// A label styled like a pill but WITHOUT the centring cell — the unfixed render path,
/// kept only so ``PillTextCenteringTests/theProbeItselfIsHonest`` has a known-broken
/// case to hold the probe against.
@MainActor
private final class StubPill: NSTextField {
    private let forcedHeight: CGFloat?

    init(height: CGFloat?) {
        forcedHeight = height
        super.init(frame: .zero)
        stringValue = "← board"
        font = BoardTheme.monoBold
        textColor = BoardTheme.textPrimary
        alignment = .center
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if let forcedHeight { size.height = forcedHeight }
        return size
    }
}
