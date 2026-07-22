import AppKit
import SichCore

/// A Mission Control v5 board card (US-003 AC#2): project line with the
/// harness badge top-right, then the task title; cards with active work add a
/// quiet minute-level duration in the bottom-right corner. Done
/// cards collapse to a compact ✓ row. Single responsibility: present one
/// ``BoardCard``, report clicks for drill-in (US-002 AC#1), and act as the drag
/// source for a manual column move. Board logic stays in `SichCore`.
@MainActor
final class SessionCard: NSView, NSDraggingSource {
    let card: BoardCard
    /// Invoked on click — the board wires this to drill into the session (US-002).
    var onSelect: ((BoardCard) -> Void)?
    /// Invoked from the right-click "Rename Task…" item — the board bubbles this
    /// to the host, which prompts for the new title and mutates the card.
    var onRename: ((BoardCard) -> Void)?
    /// Invoked from the right-click "Delete Task…" item — the board bubbles this to
    /// the host, which confirms, tears down the session + worktree, and drops the card.
    var onDelete: ((BoardCard) -> Void)?

    private let stack = NSStackView()
    private let now: () -> Date
    private weak var durationLabel: NSTextField?
    private let durationTicker = DurationTicker()
    /// Distinguishes a click (drill-in) from a drag (column move): a drag sets
    /// this, so `mouseUp` does not also fire `onSelect`.
    private var didDrag = false

    init(card: BoardCard, now: @escaping () -> Date = Date.init) {
        self.card = card
        self.now = now
        super.init(frame: .zero)
        wantsLayer = true
        configureLayer()
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Appearance

    private func configureLayer() {
        layer?.cornerRadius = 10
        layer?.borderWidth = 0
        layer?.masksToBounds = false
        themedBorder = nil
        themedShadow = .black
        layer?.shadowRadius = 3
        layer?.shadowOpacity = 0.12
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        switch card.state {
        case .waitingForInput:
            // The freshest attention style: warm fill, full amber edge + soft ring.
            themedBackground = BoardTheme.needsYouCard
            themedBorder = BoardTheme.attention
            layer?.borderWidth = 1
            themedShadow = BoardTheme.attention
            layer?.shadowRadius = 4
            layer?.shadowOpacity = 0.25
            layer?.shadowOffset = .zero
        case .blocked:
            themedBackground = BoardTheme.needsYouCard
            themedBorder = BoardTheme.alert
            layer?.borderWidth = 1
        case .done, .idle, .running, .runningTests, .unknown:
            themedBackground = BoardTheme.cardFill
        }
    }

    /// Keyboard-focus ring (arrow-key board navigation): a brand-coloured 2pt
    /// edge while focused; un-focusing restores the state-derived border.
    func setKeyboardFocus(_ focused: Bool) {
        if focused {
            layer?.borderWidth = 2
            themedBorder = BoardTheme.brand
        } else {
            configureLayer()
        }
    }

    // MARK: - Content

    private func buildContent() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if card.state == .done {
            buildDoneRow()
        } else {
            buildFullCard()
        }
    }

    /// The full card face: project + harness badge → title → duration.
    private func buildFullCard() {
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let header = headerRow()
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(
            equalTo: stack.widthAnchor, constant: -28).isActive = true
        let title = titleRow()
        stack.addArrangedSubview(title)
        title.widthAnchor.constraint(
            equalTo: stack.widthAnchor, constant: -28).isActive = true
        if shouldShowDuration {
            let duration = durationRow()
            stack.addArrangedSubview(duration)
            duration.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        if card.state.isWorking { startDurationTimer() }
    }

    /// A DONE card is a compact row: ✓ + title over project, total work on the right.
    private func buildDoneRow() {
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let row = NSStackView()
        row.spacing = 10
        row.alignment = .centerY
        row.addArrangedSubview(label("✓", font: BoardTheme.mono, color: BoardTheme.stateColor(.done)))
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let doneTitle = label(
            card.title ?? BoardTheme.shortPath(card.projectDir),
            font: NSFont.systemFont(ofSize: 13, weight: .medium), color: BoardTheme.textMuted)
        doneTitle.yieldWidthToWindow(.defaultLow)   // longest text squeezes first
        text.addArrangedSubview(doneTitle)
        if card.title != nil {
            text.addArrangedSubview(repoText(font: BoardTheme.sansTiny))
        }
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())   // flexible spacer
        if shouldShowDuration { row.addArrangedSubview(durationReadout()) }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    }

    /// The card headline — the human task title ("Fix login redirect"). Falls
    /// back to the project-dir leaf for an untitled (hook-observed) session.
    private func titleRow() -> NSView {
        let row = NSStackView()
        row.alignment = .leading
        // An untitled (hook-observed) card shows its project-dir leaf dimmed, so
        // a path never masquerades as a task name.
        let titleColor: NSColor = card.title == nil ? BoardTheme.textMuted : BoardTheme.textPrimary
        let title = NSTextField(labelWithAttributedString: BoardTheme.cardTitleText(
            card.title ?? BoardTheme.shortPath(card.projectDir), color: titleColor))
        // The card grows for a long title rather than cutting it off — but only
        // to an extent: three lines, then truncation.
        title.maximumNumberOfLines = 3
        title.lineBreakMode = .byTruncatingTail
        title.cell?.wraps = true
        title.cell?.truncatesLastVisibleLine = true
        title.yieldWidthToWindow(.defaultLow)   // longest text squeezes first
        row.addArrangedSubview(title)
        return row
    }

    /// A deliberately quiet footer anchored to the free bottom-right corner.
    private func durationRow() -> NSView {
        let row = NSStackView()
        row.alignment = .centerY
        row.addArrangedSubview(NSView())   // flexible spacer → bottom-right
        row.addArrangedSubview(durationReadout())
        return row
    }

    /// WORKING gets a pulsing live-activity glyph + current interval. Every
    /// resting column with recorded work gets a clock + cumulative active time.
    private func durationReadout() -> NSView {
        let row = NSStackView()
        row.alignment = .centerY
        row.spacing = 4
        let symbolName = card.state.isWorking ? "waveform.path.ecg" : "clock"
        if let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: card.state.isWorking
                ? "Current working interval" : "Total working time"
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) {
            let icon = NSImageView(image: image)
            icon.identifier = NSUserInterfaceItemIdentifier(
                card.state.isWorking ? "duration-working-pulse" : "duration-clock")
            icon.contentTintColor = card.state.isWorking
                ? BoardTheme.stateColor(.running) : BoardTheme.textFaint
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.yieldWidthToWindow(.defaultLow)   // the live glyph yields before the window grows
            let width = icon.widthAnchor.constraint(equalToConstant: 11)
            width.priority = .defaultLow
            NSLayoutConstraint.activate([
                width,
                icon.heightAnchor.constraint(equalToConstant: 11),
            ])
            row.addArrangedSubview(icon)
            if card.state.isWorking { startWorkingPulse(on: icon) }
        }

        let duration = label("", font: BoardTheme.monoSmall, color: BoardTheme.textFaint)
        duration.identifier = NSUserInterfaceItemIdentifier("task-duration")
        duration.setAccessibilityLabel(
            card.state.isWorking ? "Current working interval" : "Total working time")
        durationLabel = duration
        row.addArrangedSubview(duration)
        updateDuration()
        return row
    }

    /// Do not spend card space or attention on an empty cumulative timer. An
    /// active interval remains visible from its first minute (`0m`) so the user
    /// can tell that this is the live, per-iteration clock.
    private var shouldShowDuration: Bool {
        card.state.isWorking || Int(card.totalWorkingTime(at: now())) / 60 > 0
    }

    private func startWorkingPulse(on icon: NSImageView) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        icon.wantsLayer = true

        let beat = CAKeyframeAnimation(keyPath: "transform.scale")
        beat.values = [1.0, 1.2, 0.96, 1.1, 1.0]
        beat.keyTimes = [0, 0.12, 0.24, 0.38, 1]

        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = [0.72, 1.0, 0.8, 1.0, 0.72]
        glow.keyTimes = beat.keyTimes

        let heartbeat = CAAnimationGroup()
        heartbeat.animations = [beat, glow]
        heartbeat.duration = 1.35
        heartbeat.repeatCount = .infinity
        heartbeat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        icon.layer?.add(heartbeat, forKey: "working-heartbeat")
    }

    private func startDurationTimer() {
        durationTicker.timer = Timer.scheduledTimer(
            withTimeInterval: 60, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDuration() }
        }
    }

    private func updateDuration() {
        let instant = now()
        let interval = card.state.isWorking
            ? card.currentWorkingTime(at: instant)
            : card.totalWorkingTime(at: instant)
        let text = Self.formatDuration(interval)
        durationLabel?.stringValue = text
        durationLabel?.toolTip = card.state.isWorking
            ? "Current working interval: \(text)"
            : "Total working time: \(text)"
    }

    /// The top line: project identity left, harness badge in the top-right
    /// corner. The flow is labelled only when it's the exception — a small
    /// "auto" for an autonomous run; a terminal session (the default) carries
    /// no flow text at all.
    private func headerRow() -> NSView {
        let row = NSStackView()
        row.spacing = 6
        row.alignment = .centerY
        row.addArrangedSubview(repoChip())
        row.addArrangedSubview(NSView())   // flexible spacer
        if card.flow == .a {
            row.addArrangedSubview(label("auto", font: BoardTheme.sansTiny, color: BoardTheme.textDim))
        }
        row.addArrangedSubview(HarnessBadge(agent: card.agent))
        return row
    }

    /// Whole-minute display used by the footer. Beyond a day, minute precision
    /// stops being useful and the compact form becomes `2d 3h`.
    static func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval) / 60)
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 {
            return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
        }
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.lineBreakMode = .byTruncatingTail
        field.yieldWidthToWindow()
        return field
    }

    private func repoText(font: NSFont) -> NSTextField {
        label(BoardTheme.projectLabel(card.projectDir), font: font, color: BoardTheme.repoColor(card.projectDir))
    }

    /// The project line — colour alone carries the project identity (one coding
    /// channel; the old fill+stroke+colour pill triple-coded it and made the
    /// queue read as a wall of badges before any title).
    private func repoChip() -> NSTextField {
        label(BoardTheme.projectLabel(card.projectDir),
              font: BoardTheme.chip, color: BoardTheme.repoColor(card.projectDir))
    }

    // MARK: - Drill-in (click) + drag (move) + rename (right-click)

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename Task…", action: #selector(renameTapped), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        menu.addItem(.separator())
        let delete = NSMenuItem(title: "Delete Task…", action: #selector(deleteTapped), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        return menu
    }

    @objc private func renameTapped() { onRename?(card) }
    @objc private func deleteTapped() { onDelete?(card) }

    override func mouseDown(with event: NSEvent) { didDrag = false }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        let item = NSPasteboardItem()
        item.setString(card.id.uuidString, forType: BoardCell.cardType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onSelect?(card) }
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .move }

    /// A bitmap of the card to drag under the cursor — a visual handle only, so the
    /// known-unfaithful `cacheDisplay` is fine here (not screenshot evidence).
    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return image }
        cacheDisplay(in: bounds, to: rep)
        image.addRepresentation(rep)
        return image
    }
}

/// Owns the repeating Foundation timer outside the main-actor view. Its deinit
/// cancels the run-loop registration when a rebuilt card view is discarded.
private final class DurationTicker {
    var timer: Timer?
    deinit { timer?.invalidate() }
}

/// A layer-backed text field that pads its text into a small rounded chip — the
/// same "the label draws its own fill" render path as the back pill. A container
/// `NSView` with a *child* label does NOT paint reliably on this hand-painted
/// dark UI (the iter-4 invisible-pill defect), so the chip IS the label.
@MainActor
class ChipLabel: NSTextField {
    init(text: String) {
        super.init(frame: .zero)
        stringValue = text
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false   // the LAYER paints the fill
        lineBreakMode = .byTruncatingTail
        yieldWidthToWindow()
    }

    required init?(coder: NSCoder) { nil }

    /// Pad the intrinsic text size so the rounded fill has horizontal breathing room.
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 12
        size.height += 3
        return size
    }
}
