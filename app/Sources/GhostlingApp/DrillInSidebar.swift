import AppKit
import GhostlingCore

/// The terminal's review rail, restyled after the "Task View" POC: a FILES
/// CHANGED list for the selected iteration on top, and a CHECKPOINTS timeline of
/// iterations (newest first, ● live dot on the latest, ✓ on the rest) below.
/// Clicking a checkpoint re-scopes the file list; clicking a file opens the diff.
@MainActor
final class DrillInSidebar: NSView {
    /// (all turns for the card, selected iteration, file path or nil for all).
    var onOpenDiff: (([TurnDiff], Int?, String?) -> Void)?

    private let headerField = NSTextField(labelWithString: "FILES CHANGED")
    private let checkpointsField = NSTextField(labelWithString: "CHECKPOINTS")
    private let rows = NSStackView()
    private let checkpointRows = NSStackView()
    private let emptyField = NSTextField(wrappingLabelWithString:
        "Changes from the next completed iteration will appear here.")
    private let hintField = NSTextField(labelWithString: "Click a file to review its diff")
    private var turns: [TurnDiff] = []
    private var selectedIteration: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        themedBackground = BoardTheme.canvasSunken
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        for field in [headerField, checkpointsField] {
            field.font = BoardTheme.sansSmall
            field.textColor = BoardTheme.textFaint
        }
        emptyField.font = BoardTheme.sansTiny
        emptyField.textColor = BoardTheme.textDim
        emptyField.maximumNumberOfLines = 3
        hintField.font = BoardTheme.sansTiny
        hintField.textColor = BoardTheme.textDim

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 7
        checkpointRows.orientation = .vertical
        checkpointRows.alignment = .leading
        checkpointRows.spacing = 2

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = rows
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let column = NSStackView(views: [
            headerField, scroll, hintField, checkpointsField, checkpointRows,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 9
        column.setCustomSpacing(14, after: hintField)
        column.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 14, right: 14)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.themedBackground = BoardTheme.hairline
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -28),
            checkpointRows.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -28),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    func render(turns: [TurnDiff]) {
        let previous = selectedIteration
        self.turns = turns.sorted { $0.iteration < $1.iteration }
        guard !self.turns.isEmpty else {
            headerField.stringValue = "FILES CHANGED"
            replaceRows(in: rows, with: [emptyField])
            replaceRows(in: checkpointRows, with: [])
            checkpointsField.isHidden = true
            hintField.isHidden = true
            return
        }
        selectedIteration = self.turns.contains { $0.iteration == previous }
            ? previous : self.turns.last?.iteration
        checkpointsField.isHidden = false
        renderCheckpoints()
        renderSelection()
    }

    // MARK: - Files list

    private func renderSelection() {
        let files = selectedTurn().map(\.files) ?? []
        headerField.stringValue = "FILES CHANGED · \(files.count)"
        hintField.isHidden = files.isEmpty
        if files.isEmpty {
            emptyField.stringValue = "No code changes in this iteration."
            replaceRows(in: rows, with: [emptyField])
            return
        }
        replaceRows(in: rows, with: files.map(fileCard))
    }

    private func selectedTurn() -> TurnDiff? {
        turns.first { $0.iteration == selectedIteration } ?? turns.last
    }

    private func fileCard(_ file: DiffFile) -> NSView {
        let button = SidebarRowButton()
        button.target = self
        button.action = #selector(openFile(_:))
        button.filePath = file.displayPath

        let lines = file.hunks.flatMap(\.lines)
        let additions = lines.filter { $0.kind == .addition }.count
        let deletions = lines.filter { $0.kind == .deletion }.count

        let mark = NSTextField(labelWithString: deletions == 0 ? "+" : "~")
        mark.font = BoardTheme.monoBold
        mark.textColor = deletions == 0
            ? BoardTheme.stateColor(.done) : BoardTheme.attention
        let title = NSTextField(labelWithString: file.displayPath)
        title.font = BoardTheme.mono
        title.textColor = BoardTheme.textMuted
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.init(2), for: .horizontal)
        let spring = NSView()
        spring.setContentHuggingPriority(.init(1), for: .horizontal)
        let adds = NSTextField(labelWithString: additions > 0 ? "+\(additions)" : "")
        adds.font = BoardTheme.monoSmall
        adds.textColor = BoardTheme.stateColor(.done)
        let dels = NSTextField(labelWithString: deletions > 0 ? "−\(deletions)" : "")
        dels.font = BoardTheme.monoSmall
        dels.textColor = BoardTheme.alert

        let content = NSStackView(views: [mark, title, spring, adds, dels])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 7
        content.edgeInsets = NSEdgeInsets(top: 6, left: 9, bottom: 6, right: 9)
        content.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(content)
        pin(content, to: button)
        return button
    }

    @objc private func openFile(_ sender: SidebarRowButton) {
        onOpenDiff?(turns, selectedIteration, sender.filePath)
    }

    // MARK: - Checkpoints timeline

    private func renderCheckpoints() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let latest = turns.last?.iteration
        let nodes = turns.reversed().map { turn -> NSView in
            let button = SidebarRowButton()
            button.target = self
            button.action = #selector(selectCheckpoint(_:))
            button.iteration = turn.iteration
            button.isFlat = true

            let live = turn.iteration == latest
            let marker = NSTextField(labelWithString: live ? "●" : "✓")
            marker.font = BoardTheme.monoSmall
            marker.textColor = live
                ? BoardTheme.stateColor(.running) : BoardTheme.stateColor(.done)
            let title = NSTextField(labelWithString: "iter \(turn.iteration)")
            title.font = BoardTheme.sansSmall
            let selected = turn.iteration == selectedIteration
            title.textColor = selected ? BoardTheme.textPrimary : BoardTheme.textMuted
            let spring = NSView()
            spring.setContentHuggingPriority(.init(1), for: .horizontal)
            let meta = NSTextField(labelWithString:
                "\(formatter.string(from: turn.timestamp)) · +\(turn.additions) −\(turn.deletions)")
            meta.font = BoardTheme.monoSmall
            meta.textColor = BoardTheme.textDim

            if selected {
                button.themedBackground = BoardTheme.cardFillRaised
            }
            let content = NSStackView(views: [marker, title, spring, meta])
            content.orientation = .horizontal
            content.alignment = .centerY
            content.spacing = 7
            content.edgeInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
            content.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(content)
            pin(content, to: button)
            return button
        }
        replaceRows(in: checkpointRows, with: nodes)
    }

    @objc private func selectCheckpoint(_ sender: SidebarRowButton) {
        selectedIteration = sender.iteration
        renderCheckpoints()
        renderSelection()
    }

    // MARK: - Plumbing

    private func pin(_ content: NSView, to container: NSView) {
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func replaceRows(in stack: NSStackView, with views: [NSView]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach {
            stack.addArrangedSubview($0)
            // Constraints may only be activated after both views share the stack's
            // hierarchy. Activating this earlier raises NSGenericException.
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

@MainActor
private final class SidebarRowButton: NSControl {
    var filePath: String?
    var iteration: Int?
    /// Flat rows (checkpoints) skip the card border; file rows keep it.
    var isFlat = false {
        didSet {
            layer?.borderWidth = isFlat ? 0 : 1
            if isFlat { themedBackground = .clear }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        themedBackground = BoardTheme.cardFill
        themedBorder = BoardTheme.cardStroke
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        themedBorder = BoardTheme.brand
    }

    override func mouseUp(with event: NSEvent) {
        themedBorder = BoardTheme.cardStroke
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
    }
}
