import AppKit
import SichCore

/// The dedicated view for archived tasks — the checklist's "DONE column need to
/// be archived time to time". A task done in a previous app session auto-archives
/// on the next launch: its record stays durable in the task book, but it stops
/// renting a card (and a per-refresh rebuild) on the board. This page is where
/// those records remain readable. Read-only on purpose: the archive is a ledger,
/// not a work surface. Esc or the "← board" pill returns.
@MainActor
final class ArchivePage: NSView {
    /// Leave the page (Esc / the back pill) — the host un-hides the board.
    var onReturn: (() -> Void)?

    private let back = BackPill()
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyHint = NSTextField(
        labelWithString: "Nothing archived yet — tasks finished in a previous session land here.")
    private let rowStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        themedBackground = BoardTheme.canvas
        build()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Scaffold (same reading-column shape as ``BacklogPage``)

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
        // The centered reading column, preference BELOW the window's own 500 size
        // priority — the same 750-priority-trap dodge BacklogPage documents.
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

    private func buildColumn() -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10

        let header = NSStackView()
        header.spacing = 8
        let title = NSTextField(labelWithString: "ARCHIVE")
        title.attributedStringValue = BoardTheme.caps("ARCHIVE", color: BoardTheme.textFaint)
        header.addArrangedSubview(title)
        header.addArrangedSubview(NSView())   // flexible spacer
        countLabel.font = BoardTheme.mono
        countLabel.textColor = BoardTheme.textFaint
        header.addArrangedSubview(countLabel)
        column.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        emptyHint.font = BoardTheme.sansSmall
        emptyHint.textColor = BoardTheme.textFaint
        column.addArrangedSubview(emptyHint)

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 10
        column.addArrangedSubview(rowStack)
        rowStack.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    // MARK: - Render

    /// Rebuild the ledger from the archived records, newest first.
    func render(_ archived: [TaskRecord]) {
        rowStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let ordered = archived.sorted {
            ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast)
        }
        for record in ordered {
            let row = ArchiveRow(record: record)
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        countLabel.stringValue = archived.isEmpty ? "" : "\(archived.count)"
        emptyHint.isHidden = !archived.isEmpty
    }

    // MARK: - Keyboard (Esc leaves, same as drill-in)

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onReturn?() } else { super.keyDown(with: event) }
    }

    // MARK: - Test seams

    /// The rendered archive rows, top→bottom.
    func rowsForTesting() -> [ArchiveRow] {
        rowStack.arrangedSubviews.compactMap { $0 as? ArchiveRow }
    }

    /// The "← board" pill (interaction-AC dispatch tests).
    func backPillForTesting() -> BackPill { back }
}

/// One archived task: title, project chip, and when it was archived. Custom-drawn
/// layer-backed chrome like ``BacklogCard`` (stock controls composite unreliably
/// on this hand-painted UI). No interactions — the archive is read-only.
@MainActor
final class ArchiveRow: NSView {
    let record: TaskRecord

    private static let archivedDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    init(record: TaskRecord) {
        self.record = record
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        themedBackground = BoardTheme.cardFill
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContent() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let title = NSTextField(labelWithAttributedString:
            BoardTheme.cardTitleText(record.title, color: BoardTheme.textPrimary))
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(490), for: .horizontal)
        stack.addArrangedSubview(title)

        let meta = NSStackView()
        meta.spacing = 10
        if let projectDir = record.projectDir {
            meta.addArrangedSubview(label(
                BoardTheme.shortPath(projectDir), font: BoardTheme.monoSmall,
                color: BoardTheme.repoColor(projectDir)))
        }
        if let archivedAt = record.archivedAt {
            meta.addArrangedSubview(label(
                "archived \(Self.archivedDate.string(from: archivedAt))",
                font: BoardTheme.sansSmall, color: BoardTheme.textFaint))
        }
        stack.addArrangedSubview(meta)
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        return field
    }
}
