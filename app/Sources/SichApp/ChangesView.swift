import AppKit
import SichCore

/// The drill-in's diff review pane, restyled after the "Task View" POC:
/// ← Terminal back link, the file path, a scope control (this iter / whole task)
/// and the +/− stats — over the gutter-and-ribbon DiffTextView.
@MainActor
final class ChangesView: NSView {
    /// Invoked when the user leaves the diff pane (← Terminal link) to return to
    /// the live terminal surface in the drill-in.
    var onClose: (() -> Void)?
    private let back = NSButton(title: "← Terminal", target: nil, action: nil)
    private let title = NSTextField(labelWithString: "Changes")
    private let scope = NSSegmentedControl(
        labels: ["This iter", "Whole task"], trackingMode: .selectOne,
        target: nil, action: nil)
    private let stats = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "No changes recorded for this task yet")
    private let diffView = DiffTextView()
    private var turns: [TurnDiff] = []
    private var selectedIteration: Int?
    private var filePath: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        themedBackground = BoardTheme.canvas
        scope.target = self
        scope.action = #selector(selectionChanged)
        scope.font = BoardTheme.sansSmall
        scope.segmentStyle = .roundRect
        back.target = self
        back.action = #selector(close)
        back.isBordered = false
        back.font = BoardTheme.sansSmall
        back.contentTintColor = BoardTheme.textFaint
        title.font = BoardTheme.monoSmall
        title.textColor = BoardTheme.textMuted
        title.lineBreakMode = .byTruncatingMiddle
        stats.font = BoardTheme.monoSmall
        stats.textColor = BoardTheme.textMuted
        empty.font = BoardTheme.sansSmall
        empty.textColor = BoardTheme.textFaint
        empty.alignment = .center
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        let spring = NSView()
        spring.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [back, title, spring, stats, scope])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        bar.wantsLayer = true
        bar.themedBackground = BoardTheme.canvasSunken

        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.themedBackground = BoardTheme.hairline

        for view in [bar, hairline, diffView, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.topAnchor.constraint(equalTo: bar.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            diffView.leadingAnchor.constraint(equalTo: leadingAnchor),
            diffView.trailingAnchor.constraint(equalTo: trailingAnchor),
            diffView.topAnchor.constraint(equalTo: hairline.bottomAnchor),
            diffView.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        showEmpty()
    }

    func render(turns: [TurnDiff], filePath: String? = nil, selectedIteration: Int? = nil) {
        self.filePath = filePath
        title.stringValue = filePath ?? "All changed files"
        self.turns = turns.sorted { $0.iteration < $1.iteration }
        guard !self.turns.isEmpty else { showEmpty(); return }
        self.selectedIteration = selectedIteration ?? self.turns.last?.iteration
        if let iteration = self.selectedIteration {
            scope.setLabel("Iter \(iteration)", forSegment: 0)
        }
        scope.isHidden = self.turns.count < 2
        scope.selectedSegment = 0
        empty.isHidden = true
        diffView.isHidden = false
        selectionChanged()
    }

    @objc private func close() { onClose?() }

    private func showEmpty() {
        empty.isHidden = false
        diffView.isHidden = true
        scope.isHidden = true
        stats.stringValue = "Waiting for the next completed turn"
    }

    @objc private func selectionChanged() {
        guard !turns.isEmpty else { return }
        let rendered: String
        if scope.isHidden || scope.selectedSegment == 0 {
            let turn = turns.first { $0.iteration == selectedIteration } ?? turns[turns.count - 1]
            rendered = turn.unifiedDiff
        } else {
            rendered = turns.last?.sessionDiff
                ?? turns.map(\.unifiedDiff).joined(separator: "\n")
        }
        diffView.render(rendered, filePath: filePath)
        // Stats describe the whole rendered diff — the pane now shows every file
        // (review-style), with `filePath` only choosing where the scroll lands.
        let renderedFiles = UnifiedDiffParser.parse(rendered)
        let lines = renderedFiles.flatMap(\.hunks).flatMap(\.lines)
        stats.stringValue = "\(renderedFiles.count) files  " +
            "+\(lines.filter { $0.kind == .addition }.count)  " +
            "−\(lines.filter { $0.kind == .deletion }.count)"
    }
}
