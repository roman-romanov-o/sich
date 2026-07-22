import AppKit
import GhostlingCore

/// One durable backlog task on the board's leading rail: title, free-form
/// description, and an optional project chip. Custom-drawn layer-backed chrome
/// like ``SessionCard`` (stock controls composite unreliably on this hand-painted
/// dark UI). Double-click or the context menu promotes the task onto the board;
/// deletion also goes through the context menu.
@MainActor
final class BacklogCard: NSView {
    let record: TaskRecord
    /// Start this task: the host picks agent/mode and promotes it to a live card.
    var onPromote: ((TaskRecord) -> Void)?
    /// Remove the durable record (the task never ran; nothing else to tear down).
    var onDelete: ((TaskRecord) -> Void)?

    private let stack = NSStackView()

    init(record: TaskRecord) {
        self.record = record
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        themedBackground = BoardTheme.cardFill
        themedBorder = BoardTheme.cardStroke
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContent() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addWrappingTitle(record.title, maxLines: 3)
        if !record.details.isEmpty {
            addWrappingLabel(
                record.details, font: BoardTheme.sansSmall,
                color: BoardTheme.textMuted, maxLines: 3)
        }
        if let projectDir = record.projectDir {
            let chip = label(
                BoardTheme.shortPath(projectDir), font: BoardTheme.monoSmall,
                color: BoardTheme.repoColor(projectDir))
            stack.setCustomSpacing(8, after: stack.arrangedSubviews.last ?? chip)
            stack.addArrangedSubview(chip)
        }
    }

    private func addWrappingLabel(
        _ text: String, font: NSFont, color: NSColor, maxLines: Int
    ) {
        let field = label(text, font: font, color: color)
        addWrapping(field, maxLines: maxLines)
    }

    /// The headline gets the shared card-title treatment (mono for slug titles,
    /// tightened two-line leading for prose ones).
    private func addWrappingTitle(_ text: String, maxLines: Int) {
        let field = NSTextField(labelWithAttributedString:
            BoardTheme.cardTitleText(text, color: BoardTheme.textPrimary))
        addWrapping(field, maxLines: maxLines)
    }

    private func addWrapping(_ field: NSTextField, maxLines: Int) {
        field.maximumNumberOfLines = maxLines
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = true
        field.cell?.truncatesLastVisibleLine = true
        field.yieldWidthToWindow(.defaultLow)   // longest text squeezes first
        stack.addArrangedSubview(field)
        field.widthAnchor.constraint(
            equalTo: stack.widthAnchor, constant: -28).isActive = true
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

    // MARK: - Promote (double-click) + context menu

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { onPromote?(record) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let start = NSMenuItem(
            title: "Start Task…", action: #selector(promoteTapped), keyEquivalent: "")
        start.target = self
        menu.addItem(start)
        menu.addItem(.separator())
        let delete = NSMenuItem(
            title: "Delete from Backlog", action: #selector(deleteTapped), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        return menu
    }

    @objc private func promoteTapped() { onPromote?(record) }
    @objc private func deleteTapped() { onDelete?(record) }
}
