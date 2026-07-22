import AppKit
import GhostlingCore

/// The backlog as its own full-window page. It used to be a rail on the board's
/// leading edge, which cost a whole column of width during active work; now the
/// board keeps that space and the backlog is one keystroke away (⌘B, or the
/// "Backlog" button in the board header). Esc or the "← board" pill returns.
///
/// Durable ``TaskRecord``s render as ``BacklogCard``s in a single readable
/// column that scrolls; promote/delete flow through the same host callbacks the
/// rail used.
@MainActor
final class BacklogPage: NSView {
    /// Leave the page (Esc / the back pill) — the host un-hides the board.
    var onReturn: (() -> Void)?
    /// The "+ backlog task" affordance was tapped — the host prompts and adds.
    var onAdd: (() -> Void)?
    /// A card asked to start — the host picks agent/mode and promotes it.
    var onPromote: ((TaskRecord) -> Void)?
    /// A card's delete context item was picked — the host removes the record.
    var onDelete: ((TaskRecord) -> Void)?

    private let back = BackPill()
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyHint = NSTextField(labelWithString: "Nothing queued — add a task to pick up later.")
    private var addButton: NSButton?
    private let cardStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        themedBackground = BoardTheme.canvas
        build()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Scaffold

    private func build() {
        back.onClick = { [weak self] in self?.onReturn?() }
        back.translatesAutoresizingMaskIntoConstraints = false
        addSubview(back)
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            back.topAnchor.constraint(equalTo: topAnchor, constant: 10),
        ])

        let column = buildColumn()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scroll.documentView = column
        column.translatesAutoresizingMaskIntoConstraints = false
        // A centered reading column: full width minus margins on a small window,
        // capped at 560pt on a wide one. The preference must sit BELOW the window's
        // own 500 size priority — combined with the required 560 cap, anything
        // higher would squeeze the whole window down (the 750-priority trap).
        let preferred = column.widthAnchor.constraint(
            equalTo: scroll.contentView.widthAnchor, constant: -80)
        preferred.priority = NSLayoutConstraint.Priority(490)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 4),
            column.centerXAnchor.constraint(equalTo: scroll.contentView.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            preferred,
        ])
    }

    /// Header row + add affordance + the card container, as one vertical stack
    /// (the scroll document).
    private func buildColumn() -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10

        let header = NSStackView()
        header.spacing = 8
        let title = NSTextField(labelWithString: "BACKLOG")
        title.attributedStringValue = BoardTheme.caps("BACKLOG", color: BoardTheme.textFaint)
        header.addArrangedSubview(title)
        header.addArrangedSubview(NSView())   // flexible spacer
        countLabel.font = BoardTheme.mono
        countLabel.textColor = BoardTheme.textFaint
        header.addArrangedSubview(countLabel)
        column.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        let button = NSButton(title: "+ backlog task", target: self, action: #selector(addTapped))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.contentTintColor = BoardTheme.brand
        button.font = BoardTheme.sansSmall
        button.yieldWidthToWindow()
        addButton = button
        column.addArrangedSubview(button)

        emptyHint.font = BoardTheme.sansSmall
        emptyHint.textColor = BoardTheme.textFaint
        column.addArrangedSubview(emptyHint)

        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 10
        column.addArrangedSubview(cardStack)
        cardStack.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    @objc private func addTapped() { onAdd?() }

    // MARK: - Render

    /// Rebuild the card column from the durable records.
    func render(_ backlog: [TaskRecord]) {
        cardStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for record in backlog {
            let view = BacklogCard(record: record)
            view.onPromote = { [weak self] in self?.onPromote?($0) }
            view.onDelete = { [weak self] in self?.onDelete?($0) }
            cardStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        }
        countLabel.stringValue = backlog.isEmpty ? "" : "\(backlog.count)"
        emptyHint.isHidden = !backlog.isEmpty
    }

    // MARK: - Keyboard (Esc leaves, same as drill-in)

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onReturn?() } else { super.keyDown(with: event) }
    }

    // MARK: - Test seams

    /// The rendered backlog cards, top→bottom.
    func cardsForTesting() -> [BacklogCard] {
        cardStack.arrangedSubviews.compactMap { $0 as? BacklogCard }
    }

    /// The "+ backlog task" affordance (interaction-AC dispatch tests).
    func addButtonForTesting() -> NSButton? { addButton }

    /// The "← board" pill (interaction-AC dispatch tests).
    func backPillForTesting() -> BackPill { back }
}
