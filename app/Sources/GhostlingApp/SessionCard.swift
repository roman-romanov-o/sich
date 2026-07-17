import AppKit
import GhostlingCore

/// A Mission Control v5 board card (US-003 AC#2): faint project line, big task
/// title with an age stamp, and a dim meta footer naming the flow + agent. Done
/// cards collapse to a compact ✓ row. Single responsibility: present one
/// ``BoardCard``, report clicks for drill-in (US-002 AC#1), and act as the drag
/// source for a manual column move. Board logic stays in `GhostlingCore`.
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
    /// Distinguishes a click (drill-in) from a drag (column move): a drag sets
    /// this, so `mouseUp` does not also fire `onSelect`.
    private var didDrag = false

    init(card: BoardCard) {
        self.card = card
        super.init(frame: .zero)
        wantsLayer = true
        configureLayer()
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Appearance

    private func configureLayer() {
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0
        switch card.state {
        case .waitingForInput:
            // The freshest attention style: warm fill, full amber edge + soft ring.
            themedBackground = BoardTheme.needsYouCard
            themedBorder = BoardTheme.attention
            layer?.masksToBounds = false
            themedShadow = BoardTheme.attention
            layer?.shadowRadius = 4
            layer?.shadowOpacity = 0.25
            layer?.shadowOffset = .zero
        case .blocked:
            themedBackground = BoardTheme.needsYouCard
            themedBorder = BoardTheme.needsYouStroke
        case .done:
            themedBackground = BoardTheme.cardFill
            themedBorder = BoardTheme.doneStroke
        default:
            themedBackground = BoardTheme.cardFill
            themedBorder = BoardTheme.cardStroke
        }
    }

    /// Keyboard-focus ring (arrow-key board navigation): a brand-coloured 2pt
    /// edge while focused; un-focusing restores the state-derived border.
    func setKeyboardFocus(_ focused: Bool) {
        if focused {
            layer?.borderWidth = 2
            themedBorder = BoardTheme.brand
        } else {
            layer?.borderWidth = 1
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

    /// The full card face: project → title + age → meta.
    private func buildFullCard() {
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.addArrangedSubview(repoChip())
        let title = titleRow()
        stack.addArrangedSubview(title)
        title.widthAnchor.constraint(
            equalTo: stack.widthAnchor, constant: -28).isActive = true
        let meta = label(metaText, font: BoardTheme.sansTiny, color: BoardTheme.textDim)
        stack.setCustomSpacing(8, after: title)
        stack.addArrangedSubview(meta)
    }

    /// A DONE card is a compact row: ✓ + title over project, age on the right.
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
            text.addArrangedSubview(label(
                card.title ?? BoardTheme.shortPath(card.projectDir),
                font: NSFont.systemFont(ofSize: 13, weight: .medium), color: BoardTheme.textMuted))
        if card.title != nil {
            text.addArrangedSubview(repoText(font: BoardTheme.sansTiny))
        }
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())   // flexible spacer
        row.addArrangedSubview(label(ageText, font: BoardTheme.monoSmall, color: BoardTheme.textDim))
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    }

    /// The card headline — the human task title ("Fix login redirect") with the
    /// age stamp right-aligned. Falls back to the project-dir leaf for an
    /// untitled (hook-observed) session.
    private func titleRow() -> NSView {
        let row = NSStackView()
        row.alignment = .firstBaseline
        row.spacing = 8
        let title = label(
            card.title ?? BoardTheme.shortPath(card.projectDir),
            font: BoardTheme.cardTitle, color: BoardTheme.textPrimary)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.cell?.wraps = true
        title.cell?.truncatesLastVisibleLine = true
        row.addArrangedSubview(title)
        row.addArrangedSubview(NSView())   // flexible spacer
        let ageColor: NSColor = card.state.needsAttention
            ? (card.state == .blocked ? BoardTheme.alert : BoardTheme.attention)
            : BoardTheme.textFaint
        let age = label(ageText, font: BoardTheme.mono, color: ageColor)
        row.addArrangedSubview(age)
        return row
    }

    /// The dim footer: flow + agent, e.g. "terminal · Claude Code" / "autonomous ·
    /// Claude Code". This is where the two-flow cue lives now (no more lane rows).
    private var metaText: String {
        let flow = card.flow == .a ? "autonomous" : "terminal"
        return "\(flow) · \(card.agent.displayName)"
    }

    /// Compact "12m" / "1h 04m" age from the card's last observation; empty when
    /// the card carries no observation time (`.distantPast`).
    private var ageText: String {
        guard card.updatedAt > .distantPast else { return "" }
        let minutes = max(0, Int(Date().timeIntervalSince(card.updatedAt)) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        return field
    }

    private func repoText(font: NSFont) -> NSTextField {
        label(BoardTheme.projectLabel(card.projectDir), font: font, color: BoardTheme.repoColor(card.projectDir))
    }

    private func repoChip() -> NSTextField {
        let chip = ChipLabel(text: BoardTheme.projectLabel(card.projectDir))
        chip.font = BoardTheme.sansSmall
        let color = BoardTheme.repoColor(card.projectDir)
        chip.textColor = color
        chip.wantsLayer = true
        chip.themedBackground = color.withAlphaComponent(0.12)
        chip.themedBorder = color.withAlphaComponent(0.34)
        chip.layer?.borderWidth = 1
        chip.layer?.cornerRadius = 5
        return chip
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

/// A layer-backed text field that pads its text into a small rounded chip — the
/// same "the label draws its own fill" render path as the back pill. A container
/// `NSView` with a *child* label does NOT paint reliably on this hand-painted
/// dark UI (the iter-4 invisible-pill defect), so the chip IS the label.
@MainActor
final class ChipLabel: NSTextField {
    init(text: String) {
        super.init(frame: .zero)
        stringValue = text
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false   // the LAYER paints the fill
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
