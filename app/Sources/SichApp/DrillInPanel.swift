import AppKit
import SichCore

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
    /// Invoked on click — the panel wires this to return to the board.
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

/// The header's live status chip (POC "working · needs you" pill): state-coloured
/// text, tinted fill, and a pulse while the session is active or waiting. Same
/// single layer-backed-text-field render path as ``BackPill``.
@MainActor
final class StatusPill: NSTextField {
    init() {
        super.init(frame: .zero)
        useCenteredTextCell()
        font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        alignment = .center
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 0
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 22
        size.height = 22
        return size
    }

    func show(text: String, color: NSColor, pulsing: Bool) {
        stringValue = "● \(text)"
        textColor = color
        themedBackground = color.withAlphaComponent(0.08)
        layer?.removeAnimation(forKey: "pulse")
        guard pulsing else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.55
        pulse.duration = 1.0
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        layer?.add(pulse, forKey: "pulse")
    }
}

/// Amber "you're on a worktree" pill for the drill-in header — the same single
/// layer-backed text-field render path as ``BackPill``/``StatusPill`` (the only one
/// proven to composite on this hand-painted dark UI). Shown only while the focused
/// card's checkout is a linked git worktree, so the operator sees at a glance that
/// edits land on a side branch, not the shared main tree.
@MainActor
final class WorktreePill: NSTextField {
    init() {
        super.init(frame: .zero)
        useCenteredTextCell()
        font = BoardTheme.monoSmall
        alignment = .center
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        wantsLayer = true
        textColor = BoardTheme.attention
        layer?.cornerRadius = 5
        layer?.borderWidth = 0
        themedBackground = BoardTheme.attention.withAlphaComponent(0.10)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 18
        size.height = 20
        return size
    }
}

/// The drill-in surface (US-002): when a card is selected, this panel takes over
/// the full window (Altitude-1) hosting that session's embedded ``TerminalSurface``
/// — in-app focus, not an OS window jump (DD-001). A breadcrumb header with a
/// live status pill, an amber "waiting on you" banner, and the terminal filling
/// the rest. Single responsibility: present one focused session and a way back.
///
/// Built to mirror ``SessionCard`` exactly — `wantsLayer` + a `themedBackground`
/// layer fill + stacks of label fields — because that is the render path the
/// operator demonstrably sees on the board.
@MainActor
final class DrillInPanel: NSView {
    /// Invoked when the operator returns to the board (US-002 AC#2).
    var onClose: (() -> Void)?

    // Internal so a real mouseDown-event test can drive the click path (the
    // Interaction-AC Binding Rule: a click AC must be exercised by a dispatched
    // event, never by calling `goBack()` directly).
    let backPill = BackPill()
    private let dirField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let statusPill = StatusPill()
    private let quotaField = NSTextField(labelWithString: "")
    private let tagField = NSTextField(labelWithString: "")
    /// Which harness runs in the focused terminal — the visual chip beside the tag.
    private let harnessBadge = HarnessBadge(agent: .claude)
    // Internal so a focus test can assert the worktree indicator is shown/hidden.
    let worktreeTag = WorktreePill()
    private let banner = NSView()
    private let bannerField = NSTextField(labelWithString:
        "Waiting on you — answer in the terminal below")
    private let termContainer = NSView()
    private var surface: TerminalSurface?

    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    /// The mounted terminal, so an E2E can read what the operator actually sees.
    var surfaceForTesting: TerminalSurface? { surface }
    private var focusedCard: BoardCard?
    private var terminalFontSize: CGFloat = 20

    /// Item 8 (18.08): true only in the production shell — drill-in surfaces then
    /// teach TerminalGeometry their settled grid so future spawns are born pre-sized.
    /// Tests and E2E captures leave it false and never touch the real defaults.
    var teachesGeometry = false

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
        themedBackground = BoardTheme.canvas
        backPill.onClick = { [weak self] in self?.goBack() }
        build()
    }

    required init?(coder: NSCoder) { nil }

    /// Root column: header / banner (collapses when hidden — NSStackView detaches
    /// hidden arranged views) / the terminal.
    private func build() {
        let column = NSStackView(views: [buildHeader(), buildBanner(), termContainer])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for view in column.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    /// POC header: ← board / dir · title, the live status pill, then quota and the
    /// `libghostty · agent` tag on the right.
    private func buildHeader() -> NSView {
        // Long paths and the live quota readout must truncate — default 750 compression
        // resistance on label fields pins the window wider than a laptop screen (the
        // drill-in header showed "interactive … antigravity … co…" cut off with no
        // way to edge-resize smaller).
        configure(dirField, font: BoardTheme.sansTiny, color: BoardTheme.textFaint,
                  yieldPriority: .defaultLow)
        configure(titleField, font: BoardTheme.cardTitle, color: BoardTheme.textPrimary,
                  yieldPriority: .defaultLow)
        configure(quotaField, font: BoardTheme.monoSmall, color: BoardTheme.textMuted,
                  yieldPriority: .defaultLow)
        configure(tagField, font: BoardTheme.monoSmall, color: BoardTheme.textDim)

        let slash = NSTextField(labelWithString: "/")
        configure(slash, font: BoardTheme.sansSmall, color: BoardTheme.textDim)
        let spring = NSView()
        spring.setContentHuggingPriority(.init(1), for: .horizontal)

        worktreeTag.isHidden = true
        let header = NSStackView(views: [
            backPill, slash, dirField, titleField, statusPill, spring,
            worktreeTag, quotaField, tagField, harnessBadge,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        return withBottomHairline(header)
    }

    /// The amber attention bar (POC "Waiting on you"), shown only while the session
    /// is waiting for input. Warm card fill + attention text, like a NEEDS YOU card.
    private func buildBanner() -> NSView {
        banner.wantsLayer = true
        banner.themedBackground = BoardTheme.needsYouCard
        configure(bannerField, font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                  color: BoardTheme.attention)
        bannerField.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(bannerField)
        NSLayoutConstraint.activate([
            bannerField.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 20),
            bannerField.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            banner.heightAnchor.constraint(equalToConstant: 34),
        ])
        banner.isHidden = true
        return banner
    }

    /// Focus a card's session: show its live embedded terminal, ready for input
    /// (US-002 AC#1). The previous surface is detached first so only the focused
    /// terminal is foreground-rendered (US-002 edge case #2 / TC-E2E-007).
    func focus(card: BoardCard, pty: PTYSession, terminalFontSize: CGFloat = 20) {
        focusedCard = card
        self.terminalFontSize = terminalFontSize
        titleField.stringValue = card.title ?? BoardTheme.shortPath(card.projectDir)
        dirField.stringValue = BoardTheme.projectLabel(card.projectDir)
        tagField.stringValue = "libghostty"
        harnessBadge.set(agent: card.agent)
        showWorktreeTag(for: card.projectDir)
        update(state: card.state)
        detachSurface()
        let surface = TerminalSurface(session: pty, fontSize: terminalFontSize)
        surface.teachesGeometry = teachesGeometry
        surface.workingDirectory = card.projectDir   // relative file links resolve here
        // Esc belongs to the child (Claude Code interrupt / edit), so "back to board"
        // is ⌘[ — routed via the surface's `performKeyEquivalent`. The click pill is
        // the other way back.
        surface.onBack = { [weak self] in self?.goBack(); return true }
        mount(surface)
        surface.startReading()
        window?.makeFirstResponder(surface)   // ready for typed input
        self.surface = surface
    }

    /// Surface the amber worktree pill (with the branch name when readable) only when
    /// the focused card's checkout is a linked git worktree, so "you're editing a side
    /// branch, not main" is legible without leaving the task.
    private func showWorktreeTag(for projectDir: String) {
        let path = (projectDir as NSString).expandingTildeInPath
        guard GitWorktree.isWorktree(path) else {
            worktreeTag.isHidden = true
            return
        }
        let branch = GitWorktree.currentBranch(of: path)
        worktreeTag.stringValue = branch.map { "WORKTREE · \($0)" } ?? "WORKTREE"
        worktreeTag.isHidden = false
    }

    /// Track the drilled card's live detected state (BoardShell pushes it on every
    /// refresh): the status pill recolours and the waiting banner comes and goes.
    func update(state: CardState) {
        statusPill.show(
            text: Self.statusLabel(state),
            color: BoardTheme.stateColor(state),
            pulsing: state == .running || state == .runningTests || state == .waitingForInput
        )
        banner.isHidden = state != .waitingForInput
    }

    /// The word in the drill-in pill. Internal (not private) so US-007 can assert the
    /// dead-link reading is its own sentence here too, not a borrowed one.
    static func statusLabel(_ state: CardState) -> String {
        switch state {
        case .idle: return "idle"
        case .parked: return "parked"
        case .running: return "working"
        case .runningTests: return "testing"
        case .waitingForInput: return "needs you"
        case .blocked: return "blocked"
        case .done: return "done"
        case .unknown: return "unknown"
        case .unreachable: return "unreachable"
        }
    }

    private func mount(_ surface: TerminalSurface) {
        surface.translatesAutoresizingMaskIntoConstraints = false
        termContainer.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: termContainer.leadingAnchor, constant: 16),
            surface.trailingAnchor.constraint(equalTo: termContainer.trailingAnchor, constant: -16),
            surface.topAnchor.constraint(equalTo: termContainer.topAnchor, constant: 12),
            surface.bottomAnchor.constraint(equalTo: termContainer.bottomAnchor, constant: -16),
        ])
    }

    func detachSurface() {
        surface?.stopReading()
        surface?.removeFromSuperview()
        surface = nil
    }

    /// Compact quota readout for the header — the full panel is covered by the
    /// takeover, so the operator keeps capacity awareness without leaving the task.
    func updateQuota(_ gauges: [QuotaGauge]) {
        quotaField.stringValue = gauges
            .compactMap { g in g.remainingFraction.map { "\(g.pool) \(Int($0 * 100))%" } }
            .joined(separator: " · ")
    }

    /// Show the end-of-session banner on the mounted surface (the child died while
    /// drilled in) and reflect it in the status pill, so the terminal never reads
    /// as hung.
    func markEnded(_ disposition: SessionDisposition) {
        surface?.markEnded(disposition)
        statusPill.show(text: disposition.shortLabel, color: BoardTheme.textFaint, pulsing: false)
        banner.isHidden = true
    }

    func updateTerminalFontSize(_ size: CGFloat) {
        terminalFontSize = size
        guard let card = focusedCard, let pty = surface?.ptySession else { return }
        focus(card: card, pty: pty, terminalFontSize: size)
    }

    /// Return to the board (US-002 AC#2). Internal so the interaction is driven by a
    /// real view-level test, not just the `BoardSelection` value type.
    @objc func goBack() {
        detachSurface()
        focusedCard = nil
        onClose?()
    }

    /// Wrap a view with a 1pt hairline pinned under it (the POC's section rule).
    private func withBottomHairline(_ view: NSView) -> NSView {
        let holder = NSView()
        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.themedBackground = BoardTheme.hairline
        for sub in [view, hairline] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            view.topAnchor.constraint(equalTo: holder.topAnchor),
            hairline.topAnchor.constraint(equalTo: view.bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            hairline.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        return holder
    }

    private func configure(
        _ field: NSTextField, font: NSFont, color: NSColor,
        yieldPriority: NSLayoutConstraint.Priority = .init(490)
    ) {
        field.font = font
        field.textColor = color
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.lineBreakMode = .byTruncatingTail
        field.yieldWidthToWindow(yieldPriority)
    }
}
