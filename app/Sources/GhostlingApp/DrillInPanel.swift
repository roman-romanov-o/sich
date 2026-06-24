import AppKit
import GhostlingCore

/// A custom-drawn back affordance (US-002 AC#2): a rounded "← board" pill that
/// returns to the board on click. It is the EXACT view kind ``SessionCard``'s
/// `flowBadge` is — a **layer-backed `NSTextField`** that draws its own text *and*
/// background on a single view (`wantsLayer` + a raw `layer.backgroundColor` +
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
    /// Invoked on click — the panel wires this to return to the board.
    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        stringValue = "← board"
        font = BoardTheme.monoBold
        textColor = BoardTheme.textPrimary
        alignment = .center
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false            // the LAYER paints the fill, like flowBadge
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.20, alpha: 1).cgColor
        layer?.cornerRadius = 5
    }

    required init?(coder: NSCoder) { nil }

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

/// The drill-in surface (US-002): when a card is selected, this panel takes over
/// the full window (Altitude-1) hosting that session's embedded ``TerminalSurface``
/// — in-app focus, not an OS window jump (DD-001). While focused the panel *is* the
/// window; the board is hidden behind it. A back affordance returns to the board
/// with state preserved (US-002 AC#2). Single responsibility: present one focused
/// session's live terminal and a way back.
///
/// Built to mirror ``SessionCard`` exactly — `wantsLayer` + a raw
/// `layer.backgroundColor` + an `NSStackView` of labels — because that is the
/// render path the operator demonstrably sees on the board.
@MainActor
final class DrillInPanel: NSView {
    /// Invoked when the operator returns to the board (US-002 AC#2).
    var onClose: (() -> Void)?

    private let header = NSStackView()
    private let titleField = NSTextField(labelWithString: "")
    private let stateField = NSTextField(labelWithString: "")
    // Internal so a real mouseDown-event test can drive the click path (the
    // Interaction-AC Binding Rule: a click AC must be exercised by a dispatched
    // event, never by calling `goBack()` directly).
    let backPill = BackPill()
    private var surface: TerminalSurface?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        backPill.onClick = { [weak self] in self?.goBack() }
        buildHeader()
    }

    required init?(coder: NSCoder) { nil }

    private func buildHeader() {
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 8, right: 16)
        header.translatesAutoresizingMaskIntoConstraints = false
        configureField(titleField, font: BoardTheme.title, color: BoardTheme.textPrimary)
        configureField(stateField, font: BoardTheme.monoSmall, color: BoardTheme.textMuted)
        header.addArrangedSubview(backPill)
        header.addArrangedSubview(titleField)
        header.addArrangedSubview(stateField)
        addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    /// Focus a card's session: show its live embedded terminal, ready for input
    /// (US-002 AC#1). The previous surface is detached first so only the focused
    /// terminal is foreground-rendered (US-002 edge case #2 / TC-E2E-007).
    func focus(card: BoardCard, pty: PTYSession) {
        titleField.stringValue = card.projectDir
        stateField.stringValue = "\(card.sessionID) · \(card.agent.displayName) · \(card.state.rawValue)"
        detachSurface()
        let surface = TerminalSurface(session: pty)
        // The terminal is the first responder, so Esc arrives at its `keyDown`, not
        // the button's `keyEquivalent`. Route Esc back to the board from there — the
        // only place it deterministically lands.
        surface.onEscape = { [weak self] in self?.goBack(); return true }
        mount(surface)
        surface.startReading()
        window?.makeFirstResponder(surface)   // ready for typed input
        self.surface = surface
    }

    private func mount(_ surface: TerminalSurface) {
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            surface.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    private func detachSurface() {
        surface?.stopReading()
        surface?.removeFromSuperview()
        surface = nil
    }

    /// Return to the board (US-002 AC#2). Internal so the interaction is driven by a
    /// real view-level test, not just the `BoardSelection` value type.
    @objc func goBack() {
        detachSurface()
        onClose?()
    }

    private func configureField(_ field: NSTextField, font: NSFont, color: NSColor) {
        field.font = font
        field.textColor = color
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
    }
}
