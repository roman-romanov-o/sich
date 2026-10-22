import AppKit
import SichCore

/// The short pipeline-strip label for a step ("stories", "decide", …) — the design's
/// header segments use the command stem, not the long display name.
extension PlanningStep {
    var shortName: String { String(command.dropFirst("/saha:".count)) }
}

/// One segment of the header pipeline strip: a custom-drawn, layer-backed
/// `NSTextField` (the ``BackPill`` idiom — the only click path proven to composite
/// AND be driven by a real `mouseDown` on this hand-painted dark UI). A stock
/// `NSButton` was the interaction-AC-binding-rule trap: `performClick` isn't a real
/// gesture. This fires `onClick` from an actual dispatched `mouseDown`, nothing else.
@MainActor
final class PlanningStepButton: NSTextField {
    let step: PlanningStep
    var onClick: ((PlanningStep) -> Void)?

    init(step: PlanningStep, status: PlanningStepStatus, isNext: Bool) {
        self.step = step
        super.init(frame: .zero)
        useCenteredTextCell()
        stringValue = step.shortName
        toolTip = "\(step.rawValue) — \(step.command)"
        font = isNext ? BoardTheme.monoBold : BoardTheme.monoSmall
        alignment = .center
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        wantsLayer = true
        layer?.cornerRadius = 4
        let done = BoardTheme.stateColor(.done)
        switch (status, isNext) {
        case (.complete, _):
            textColor = done
            themedBackground = done.withAlphaComponent(0.10)
        case (_, true):
            textColor = BoardTheme.attention
            themedBackground = BoardTheme.attention.withAlphaComponent(0.12)
            layer?.borderWidth = 1
            themedBorder = BoardTheme.attention.withAlphaComponent(0.33)
        case (.malformed, _):
            textColor = BoardTheme.alert
            themedBackground = BoardTheme.alert.withAlphaComponent(0.08)
        default:
            textColor = BoardTheme.textDim
            themedBackground = BoardTheme.cardFill
        }
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 14
        size.height = 20
        return size
    }

    /// Own the whole segment as one click target (like ``BackPill``) so a hit-test
    /// test can assert the segment — not a pane behind it — receives the point.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick?(step) }

    /// Brief attention flash when a click was a no-op (occupied input line, US-004
    /// edge case) — the visible feedback the AC requires, on the segment clicked.
    func flashSkipped() {
        let flash = CABasicAnimation(keyPath: "backgroundColor")
        flash.fromValue = BoardTheme.attention.withAlphaComponent(0.35).cgColor
        flash.toValue = layer?.backgroundColor
        flash.duration = 0.6
        layer?.add(flash, forKey: "skipped")
    }
}

/// One row of the file-review queue: status glyph (✓ approved/reviewed, ○ open),
/// filename, and an amber `N●` comment badge — the design's per-file review state.
@MainActor
final class PlanningReviewButton: NSTextField {
    let step: PlanningStep
    let url: URL?
    /// Stable review identity (saha/v2: a LikeC4 view id like `us-001-flow`; legacy:
    /// the file name). Several v2 items share one `url` (the model file), so clicks
    /// must disambiguate by this key, not the URL.
    let reviewKey: String?
    var onClick: ((PlanningReviewButton) -> Void)?

    init(step: PlanningStep, url: URL?, marker: String, title: String, selected: Bool,
         commentCount: Int, reviewKey: String? = nil) {
        self.step = step
        self.url = url
        self.reviewKey = reviewKey
        super.init(frame: .zero)
        let suffix = commentCount > 0 ? "   \(commentCount)●" : ""
        stringValue = "\(marker)  \(title)\(suffix)"
        font = selected ? BoardTheme.monoBold : BoardTheme.mono
        textColor = selected ? BoardTheme.attention
            : marker == "✓" ? BoardTheme.stateColor(.done) : BoardTheme.textMuted
        alignment = .left
        lineBreakMode = .byTruncatingMiddle
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        wantsLayer = true
        themedBackground = selected
            ? BoardTheme.attention.withAlphaComponent(0.08) : NSColor.clear
        layer?.borderWidth = selected ? 1 : 0
        themedBorder = BoardTheme.attention.withAlphaComponent(0.32)
        layer?.cornerRadius = 4
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 238, height: 28)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(self)
    }
}

@MainActor
final class PlanningActionPill: NSTextField {
    var onClick: (() -> Void)?

    init(title: String, fill: NSColor?, text: NSColor, border: NSColor? = nil) {
        super.init(frame: .zero)
        useCenteredTextCell()
        stringValue = title
        font = BoardTheme.monoBold
        textColor = text
        alignment = .center
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        wantsLayer = true
        themedBackground = fill ?? NSColor.clear
        layer?.borderWidth = border == nil ? 0 : 1
        themedBorder = border
        layer?.cornerRadius = 5
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 24
        size.height = 26
        return size
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// A document reader tuned for review, not terminal density: it keeps Markdown lines
/// near a prose-friendly measure by growing side insets as the center pane widens.
@MainActor
final class PlanningDocumentTextView: NSTextView {
    var baseInset = NSSize(width: 56, height: 32) {
        didSet { updateReadableInsets() }
    }
    var maximumReadableWidth: CGFloat = 840 {
        didSet { updateReadableInsets() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateReadableInsets()
    }

    func setReadingMode(terminalCollapsed: Bool) {
        baseInset = terminalCollapsed
            ? NSSize(width: 72, height: 34)
            : NSSize(width: 56, height: 32)
    }

    private func updateReadableInsets() {
        let horizontal = max(baseInset.width, (bounds.width - maximumReadableWidth) / 2)
        textContainerInset = NSSize(width: horizontal, height: baseInset.height)
    }
}

/// The PR-style planning review surface (design: "Saha Flow Final"): pipeline strip
/// in the header, a file-review queue on the left, the doc viewer + comment composer
/// in the center, and the dockable terminal on the right. Comments and approvals are
/// REAL, persisted per task by ``ReviewStore``; the feedback draft they compose is
/// only ever pre-typed into the terminal — never submitted (suggest-only invariant).
@MainActor
final class PlanningModeView: NSView {
    let stepperPane = NSStackView()
    let reviewPane = NSStackView()
    // TextKit 1: NSTextTable (used for markdown tables) only lays out reliably under the
    // legacy layout manager — TextKit 2 renders table cells linearly, breaking columns.
    let documentPane = PlanningDocumentTextView(usingTextLayoutManager: false)
    /// Hosts the live ``TerminalSurface`` once ``attach(session:)`` mounts one. Always
    /// in the hierarchy so the three-pane layout holds even before a terminal binds
    /// (the file-watch tests exercise `show(card:)` with no session).
    let terminalContainer = NSView()
    let terminalRail = NSView()
    let returnButton = BackPill()
    /// The skip-notice for US-004's occupied-buffer edge case — visible, and a value a
    /// test can read to prove feedback was surfaced without pixel inspection.
    let feedbackField = NSTextField(labelWithString: "")
    let progressField = NSTextField(labelWithString: "")
    let documentHeaderField = NSTextField(labelWithString: "")
    /// Shown only while a source file (opened from a doc link) is on screen — clicking it
    /// pops back to the doc the reader came from.
    let docBackButton = BackPill()
    let reviewSummaryField = NSTextField(labelWithString: "")
    let reviewLeftField = NSTextField(labelWithString: "")
    let terminalStatusField = NSTextField(labelWithString: "")
    let railDraftField = NSTextField(labelWithString: "")
    /// The design's span-comment composer, scoped to the selected file. Editable —
    /// the one stock text field here; typing is not a custom-drawn interaction.
    let commentField = NSTextField()
    let addCommentButton = PlanningActionPill(
        title: "+ Comment", fill: BoardTheme.attention.withAlphaComponent(0.10),
        text: BoardTheme.attention
    )
    let terminalToggle = PlanningActionPill(
        title: "⌘J terminal ▸", fill: BoardTheme.attention.withAlphaComponent(0.08),
        text: BoardTheme.attention
    )
    /// Header toggle folding the left REVIEW NOW rail away so the reader (or the
    /// terminal, via the divider) can take the whole width.
    let railToggle = PlanningActionPill(
        title: "◂ rail", fill: BoardTheme.cardFill, text: BoardTheme.textDim
    )
    /// The draggable boundary between the reader and the terminal panel. Dragging
    /// mutates `terminalWidthConstraint`; the terminal's own `setFrameSize` keeps
    /// the PTY winsize in sync, so no extra plumbing is needed here.
    let paneDivider = PaneDivider()
    /// Header toggle for the optional LikeC4 Architecture pane (spec:
    /// docs/proposals/likec4-architecture-pane.md). Off by default — the pane costs 0 RAM
    /// until this is clicked, and 0 again after it's clicked off.
    let architectureToggle = PlanningActionPill(
        title: "◫", fill: BoardTheme.brand.withAlphaComponent(0.10),
        text: BoardTheme.brand
    )
    let architecturePane = ArchitecturePane()
    /// saha/v2 story/diagram viewer: overlays only the document scroll area so the doc
    /// header (approve) and comment composer stay usable while a LikeC4 view is up.
    /// Torn down with the architecture pane (0 RAM after leaving Planning Mode).
    let storyPane = ArchitecturePane()
    private var showingArchitecture = false
    private weak var panesView: NSView?
    private weak var documentScrollView: NSScrollView?
    let sendFeedbackButton = PlanningActionPill(
        title: "Send feedback → terminal", fill: BoardTheme.attention,
        text: BoardTheme.canvas
    )
    let approveAllButton = PlanningActionPill(
        title: "Approve remaining ✓",
        fill: BoardTheme.stateColor(.done).withAlphaComponent(0.10),
        text: BoardTheme.stateColor(.done)
    )
    let approveFileButton = PlanningActionPill(
        title: "Approve ✓", fill: BoardTheme.stateColor(.done).withAlphaComponent(0.10),
        text: BoardTheme.stateColor(.done)
    )
    private let reader: PlanningStateReader
    private let paneLayout: PaneLayoutStore
    private let mermaid = MermaidRenderer()
    private lazy var renderer = NativeMarkdownRenderer(
        renderMermaid: { [weak self] in self?.mermaid.image(for: $0) })
    private var watchers: [FileWatcher] = []
    private var surface: TerminalSurface?
    private var terminalWidthConstraint: NSLayoutConstraint?
    private var terminalRailWidthConstraint: NSLayoutConstraint?
    private var terminalCollapsed = true
    private weak var reviewRail: NSView?
    /// Terminal width when the current divider drag began; nil outside a drag.
    private var dragStartWidth: CGFloat?
    private(set) var reviewStore: ReviewStore?
    private(set) var cardID: UUID?
    private(set) var state: PlanningState?
    private(set) var selectedStep: PlanningStep?
    private(set) var selectedArtifactURL: URL?
    /// Canonical selection identity (`PlanningArtifactState.reviewKey`): the view id
    /// for saha/v2 diagram items, the file name for markdown items. `selectedArtifactURL`
    /// is kept in sync but is ambiguous for v2 (many views share one model file).
    private(set) var selectedReviewKey: String?
    private(set) var lastFeedback: String?
    /// Roots tried (in order) when resolving a `foo/Bar.swift` doc link to a file on disk.
    private var projectDir: String?
    private var taskFolder: URL?
    /// True while a source file opened from a link is showing instead of the doc.
    private(set) var isViewingFile = false
    var onReturn: (() -> Void)?
    var onSuggestCommand: ((String) -> Void)?

    /// Test seam: the mounted terminal, so a registry/pool-firewall test can assert the
    /// planning pane hosts the very session registered elsewhere (US-004 AC2).
    var terminalSurface: TerminalSurface? { surface }

    /// Marker scraping is the first-class path (state must be derivable without a saha
    /// code change). The reader *supports* preferring saha's `plan-status --json`
    /// (US-003 AC3) via an injected `SahaPlanStatusRunner`, but production stays
    /// marker-only until that command ships saha-side — spawning a doomed subprocess on
    /// every file-watch tick would waste work and trip the no-python-child invariant.
    init(reader: PlanningStateReader = PlanningStateReader(),
         paneLayout: PaneLayoutStore = PaneLayoutStore()) {
        self.reader = reader
        self.paneLayout = paneLayout
        super.init(frame: .zero)
        wantsLayer = true
        themedBackground = BoardTheme.documentChrome
        returnButton.onClick = { [weak self] in self?.onReturn?() }
        // A mermaid diagram renders off-main and swaps in when ready — re-render the
        // current doc so the fallback text is replaced by the finished image.
        mermaid.onReady = { [weak self] in self?.refreshCurrentDoc() }
        stepperPane.orientation = .horizontal
        stepperPane.alignment = .centerY
        stepperPane.spacing = 3
        reviewPane.orientation = .vertical
        reviewPane.alignment = .leading
        reviewPane.spacing = 1
        documentPane.isEditable = false
        documentPane.isSelectable = true   // required for `.link` spans to be clickable
        documentPane.delegate = self
        documentPane.linkTextAttributes = [
            .foregroundColor: BoardTheme.attention,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        documentPane.backgroundColor = BoardTheme.documentSurface
        documentPane.setReadingMode(terminalCollapsed: terminalCollapsed)
        // Canonical NSTextView-in-NSScrollView sizing. Without widthTracksTextView the text
        // container stays zero-width and every glyph lays out off-screen — the blank doc pane.
        documentPane.minSize = .zero
        documentPane.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        documentPane.isVerticallyResizable = true
        documentPane.isHorizontallyResizable = false
        documentPane.autoresizingMask = [.width]
        documentPane.textContainer?.widthTracksTextView = true
        terminalContainer.wantsLayer = true
        terminalContainer.themedBackground = BoardTheme.documentChrome
        terminalRail.wantsLayer = true
        terminalRail.themedBackground = BoardTheme.documentChrome
        feedbackField.font = BoardTheme.monoSmall
        feedbackField.textColor = BoardTheme.attention
        progressField.font = BoardTheme.monoSmall
        progressField.textColor = BoardTheme.textFaint
        documentHeaderField.font = BoardTheme.monoSmall
        documentHeaderField.textColor = BoardTheme.textMuted
        reviewSummaryField.font = BoardTheme.monoSmall
        reviewSummaryField.textColor = BoardTheme.textFaint
        reviewLeftField.font = BoardTheme.monoSmall
        reviewLeftField.textColor = BoardTheme.attention
        terminalStatusField.font = BoardTheme.monoSmall
        terminalStatusField.textColor = BoardTheme.textMuted
        terminalStatusField.alignment = .center
        railDraftField.font = BoardTheme.monoSmall
        railDraftField.textColor = BoardTheme.attention
        railDraftField.alignment = .center
        commentField.placeholderString = "Comment on the selected file…"
        commentField.font = BoardTheme.mono
        commentField.target = self
        commentField.action = #selector(commentFieldEntered)
        terminalToggle.onClick = { [weak self] in self?.toggleTerminal() }
        railToggle.onClick = { [weak self] in self?.toggleRail() }
        architectureToggle.toolTip = "Architecture"
        architectureToggle.onClick = { [weak self] in self?.toggleArchitecture() }
        sendFeedbackButton.onClick = { [weak self] in self?.sendFeedbackDraft() }
        approveAllButton.onClick = { [weak self] in self?.approveRemaining() }
        approveFileButton.onClick = { [weak self] in self?.approveSelectedArtifact() }
        addCommentButton.onClick = { [weak self] in self?.addComment() }
        buildLayout()
    }

    required init?(coder: NSCoder) { nil }

    private func buildLayout() {
        let title = label("Planning", font: BoardTheme.title, color: BoardTheme.textPrimary)
        let divider = NSBox()
        divider.boxType = .separator
        let spacer = NSView()
        let header = NSStackView(views: [
            returnButton, divider, title, stepperPane, progressField, spacer,
            feedbackField, railToggle, terminalToggle, architectureToggle,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Hairline under the header so it reads as a toolbar, not floating text.
        let headerRule = NSBox()
        headerRule.boxType = .separator
        let documentScroll = NSScrollView()
        documentScroll.documentView = documentPane
        documentScroll.hasVerticalScroller = true
        documentScroll.backgroundColor = BoardTheme.documentSurface

        let rail = makeReviewRail()
        reviewRail = rail
        let reader = makeDocumentReader(scroll: documentScroll)
        let terminalPanel = makeTerminalPanel()
        let panes = NSStackView(views: [rail, reader, paneDivider, terminalPanel, terminalRail])
        panes.orientation = .horizontal
        panes.alignment = .top
        panes.spacing = 0
        // The rails/terminal have fixed widths; the reader must absorb ALL spare
        // width or the pane group floats centered with a hugged ~350pt reader —
        // unusable for reviewing story diagrams.
        panes.distribution = .fill
        reader.setContentHuggingPriority(.init(1), for: .horizontal)
        panesView = panes

        let root = NSStackView(views: [header, headerRule, panes])
        root.orientation = .vertical
        root.translatesAutoresizingMaskIntoConstraints = false
        root.spacing = 0
        root.wantsLayer = true
        root.themedBackground = BoardTheme.documentChrome
        root.layer?.borderWidth = 1
        root.themedBorder = BoardTheme.cardStroke
        root.layer?.cornerRadius = 10
        addSubview(root)
        terminalRail.isHidden = true
        rail.isHidden = paneLayout.bool(forKey: PaneLayoutStore.planningRailHiddenKey)
        terminalWidthConstraint = terminalPanel.widthAnchor.constraint(
            equalToConstant: paneLayout.width(
                forKey: PaneLayoutStore.planningTerminalWidthKey, default: 386))
        terminalRailWidthConstraint = terminalRail.widthAnchor.constraint(equalToConstant: 44)
        wireDividerDrag()
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            header.heightAnchor.constraint(equalToConstant: 48),
            headerRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // The root stack's default .centerX alignment would otherwise let the
            // pane row hug its fitting width and float centered.
            panes.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panes.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 16),
            rail.widthAnchor.constraint(equalToConstant: 270),
            terminalWidthConstraint!,
            terminalRailWidthConstraint!,
            terminalRail.topAnchor.constraint(equalTo: panes.topAnchor),
            terminalRail.bottomAnchor.constraint(equalTo: panes.bottomAnchor),
        ])
        buildTerminalRail()
        applyTerminalPresentation()
        applyRailPresentation()
        // The saha/v2 story pane covers only the doc scroll area — the doc header
        // (approve) and comment composer stay interactive around it. It is frame-managed
        // (see `layout()`), NEVER constraint-pinned: any required equality onto the
        // scroll view gives it a tiny defined fitting width from the pane's internal
        // labels, and the reader stack then hugs ~28pt instead of stretching to fill.
        storyPane.autoresizingMask = []
        storyPane.isHidden = true
        documentScroll.addSubview(storyPane)
        documentScrollView = documentScroll
        // The architecture pane overlays the three-pane content region (rail+reader+terminal),
        // added last so it draws on top when toggled on; hidden and weightless otherwise.
        architecturePane.translatesAutoresizingMaskIntoConstraints = false
        architecturePane.isHidden = true
        addSubview(architecturePane)
        NSLayoutConstraint.activate([
            architecturePane.leadingAnchor.constraint(equalTo: panes.leadingAnchor),
            architecturePane.trailingAnchor.constraint(equalTo: panes.trailingAnchor),
            architecturePane.topAnchor.constraint(equalTo: panes.topAnchor),
            architecturePane.bottomAnchor.constraint(equalTo: panes.bottomAnchor),
        ])
    }

    /// Toggle the Architecture pane. Opening resolves + renders the bound project's LikeC4
    /// model (or the graceful degrade); closing tears it down so it returns to 0 RAM.
    func toggleArchitecture() {
        showingArchitecture.toggle()
        architectureToggle.stringValue = showingArchitecture ? "◫✓" : "◫"
        if showingArchitecture {
            architecturePane.isHidden = false
            if state?.isV2 == true, let taskFolder {
                // v2: the task's own LikeC4 project is the architecture to show.
                architecturePane.present(projectDir: taskFolder, modelDir: "model",
                                         deepLinkView: currentArchitectureViewID())
            } else if let projectDir {
                architecturePane.present(
                    projectDir: URL(fileURLWithPath: projectDir),
                    deepLinkView: currentArchitectureViewID())
            }
        } else {
            architecturePane.isHidden = true
            architecturePane.teardown()
        }
    }

    private func currentArchitectureViewID() -> String? {
        if let viewID = selectedArtifact?.viewID { return viewID }
        return taskFolder?.lastPathComponent
    }

    /// The artifact the selection identity currently points at (v2-safe: keyed by
    /// `reviewKey`, never by the shared model-file URL).
    private var selectedArtifact: PlanningArtifactState? {
        guard let selectedReviewKey else { return nil }
        return state?.artifacts.first { $0.reviewKey == selectedReviewKey }
    }

    private func makeReviewRail() -> NSView {
        let reviewTitle = label("REVIEW NOW", font: BoardTheme.monoSmall, color: BoardTheme.textDim)
        let titleRow = NSStackView(views: [reviewTitle, NSView(), reviewLeftField])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        let passTitle = label("THIS REVIEW PASS", font: BoardTheme.monoSmall,
                              color: BoardTheme.textDim)
        let actions = NSStackView(views: [
            passTitle, reviewSummaryField, sendFeedbackButton, approveAllButton,
        ])
        actions.orientation = .vertical
        actions.spacing = 7
        actions.alignment = .leading
        let stack = NSStackView(views: [titleRow, reviewPane, spacer, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 14)
        let view = NSView()
        view.wantsLayer = true
        view.themedBackground = BoardTheme.documentChrome
        view.themedBorder = BoardTheme.hairline
        view.layer?.borderWidth = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return view
    }

    private func makeDocumentReader(scroll: NSScrollView) -> NSView {
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = BoardTheme.documentSurface
        docBackButton.stringValue = "← doc"
        docBackButton.isHidden = true
        docBackButton.onClick = { [weak self] in self?.exitFileView() }
        let header = NSStackView(views: [docBackButton, documentHeaderField, NSView(), approveFileButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        let composer = NSStackView(views: [commentField, addCommentButton])
        composer.orientation = .horizontal
        composer.alignment = .centerY
        composer.spacing = 8
        composer.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        let stack = NSStackView(views: [header, scroll, composer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.wantsLayer = true
        stack.themedBackground = BoardTheme.documentSurface
        stack.themedBorder = BoardTheme.cardStrokeStrong
        stack.layer?.borderWidth = 1
        header.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        header.heightAnchor.constraint(equalToConstant: 40).isActive = true
        composer.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return stack
    }

    private func makeTerminalPanel() -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.themedBackground = BoardTheme.stateColor(.done)
        dot.layer?.cornerRadius = 3
        let title = label("Claude Code · planning", font: BoardTheme.monoSmall,
                          color: BoardTheme.textMuted)
        let collapse = PlanningActionPill(
            title: "⌘J hide ▸", fill: BoardTheme.cardFill, text: BoardTheme.textDim
        )
        collapse.onClick = { [weak self] in self?.toggleTerminal() }
        let spacer = NSView()
        let header = NSStackView(views: [dot, title, spacer, collapse])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        let stack = NSStackView(views: [header, terminalContainer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.wantsLayer = true
        stack.themedBackground = BoardTheme.documentChrome
        stack.themedBorder = BoardTheme.hairline
        stack.layer?.borderWidth = 1
        header.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            header.heightAnchor.constraint(equalToConstant: 40),
        ])
        return stack
    }

    private func buildTerminalRail() {
        let dot = NSView()
        dot.wantsLayer = true
        dot.themedBackground = BoardTheme.stateColor(.done)
        dot.layer?.cornerRadius = 3
        terminalStatusField.stringValue = "Claude Code"
        railDraftField.stringValue = ""
        let stack = NSStackView(views: [dot, terminalStatusField, NSView(), railDraftField])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        terminalRail.addSubview(stack)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            stack.leadingAnchor.constraint(equalTo: terminalRail.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: terminalRail.trailingAnchor),
            stack.topAnchor.constraint(equalTo: terminalRail.topAnchor),
            stack.bottomAnchor.constraint(equalTo: terminalRail.bottomAnchor),
        ])
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func show(card: BoardCard) {
        cardID = card.id
        resetArchitecture()
        watchers.forEach { $0.stop() }
        watchers.removeAll()
        guard let path = card.taskFolder else { return }
        let folder = URL(fileURLWithPath: path)
        projectDir = card.projectDir
        taskFolder = folder
        reviewStore = ReviewStore(taskFolder: folder)
        let state = refresh(folder: folder)
        let paths = Set(
            [folder.appendingPathComponent("README.md").path]
                + state.steps.compactMap(\.artifact?.path)
                + state.artifacts.map(\.url.path)
        )
        watchers = paths.map { watchedPath in
            FileWatcher(path: watchedPath) { [weak self] in
                self?.refresh(folder: folder)
            }
        }
        watchers.forEach { $0.start() }
    }

    /// Mount the card's already-registered interactive session as the planning terminal
    /// (US-004 AC2). This reuses the exact session in ``SessionRegistry`` — no new spawn,
    /// no `claude -p` — the same way ``DrillInPanel/focus(card:pty:)`` reuses one.
    func attach(session: PTYSession, terminalFontSize: CGFloat = 20) {
        detachTerminalSurface(shouldResetArchitecture: false)
        let surface = TerminalSurface(session: session, fontSize: terminalFontSize)
        surface.onBack = { [weak self] in self?.onReturn?(); return true }
        surface.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor, constant: 8),
            surface.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor, constant: -8),
            surface.topAnchor.constraint(equalTo: terminalContainer.topAnchor, constant: 8),
            surface.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor, constant: -8),
        ])
        surface.startReading()
        self.surface = surface
    }

    func updateTerminalFontSize(_ size: CGFloat) {
        guard let session = surface?.ptySession else { return }
        detachTerminalSurface(shouldResetArchitecture: false)
        attach(session: session, terminalFontSize: size)
    }

    /// Release the planning terminal's *view* on return — stop reading and unmount, but
    /// never terminate the session, so it stays registered exactly as drill-in leaves it
    /// (US-004 AC5 / TC-E2E-014).
    func detachSurface() {
        detachTerminalSurface(shouldResetArchitecture: true)
    }

    private func detachTerminalSurface(shouldResetArchitecture: Bool) {
        surface?.stopReading()
        surface?.removeFromSuperview()
        surface = nil
        if shouldResetArchitecture { resetArchitecture() }
    }

    /// Close and free the Architecture pane (0 RAM on leave / card switch).
    private func resetArchitecture() {
        showingArchitecture = false
        architectureToggle.stringValue = "◫"
        architecturePane.isHidden = true
        architecturePane.teardown()
        storyPane.isHidden = true
        storyPane.teardown()
    }

    /// Test seam: fire every armed folder watcher as if the kernel saw a write,
    /// proving "FS event → single re-parse" without a wall-clock race (TC-INT-010).
    func fireWatchersForTesting() { watchers.forEach { $0.fireForTesting() } }

    @discardableResult
    private func refresh(folder: URL) -> PlanningState {
        let state = reader.read(taskFolder: folder)
        self.state = state
        rebuildStepper(state)
        rebuildReviewList(state)
        if let selectedReviewKey,
           let artifact = state.artifacts.first(where: { $0.reviewKey == selectedReviewKey }) {
            selectArtifact(artifact)
        } else {
            selectStep(selectedStep ?? state.nextIncomplete?.step, preferArtifact: true)
        }
        updateSummary()
        return state
    }

    private func rebuildStepper(_ state: PlanningState) {
        clearArrangedSubviews(stepperPane)
        let next = state.nextIncomplete?.step
        for item in state.steps {
            let button = PlanningStepButton(
                step: item.step, status: item.status, isNext: item.step == next
            )
            button.onClick = { [weak self] in self?.handleStep($0) }
            stepperPane.addArrangedSubview(button)
        }
    }

    private func rebuildReviewList(_ state: PlanningState) {
        clearArrangedSubviews(reviewPane)
        let currentStep = selectedStep ?? state.nextIncomplete?.step ?? .research
        let artifacts = state.artifacts(for: currentStep)
        if artifacts.isEmpty {
            let button = PlanningReviewButton(
                step: currentStep, url: nil, marker: "○", title: "\(currentStep.rawValue) draft",
                selected: selectedReviewKey == nil && selectedStep == currentStep,
                commentCount: 0
            )
            button.onClick = { [weak self] in self?.selectReviewItem($0) }
            reviewPane.addArrangedSubview(button)
            return
        }
        for artifact in artifacts {
            let key = artifact.reviewKey
            let approved = reviewStore?.isApproved(key) ?? false
            let comments = reviewStore?.comments(for: key).count ?? 0
            let reviewed = approved || comments > 0 || artifact.status == .complete
            let button = PlanningReviewButton(
                step: artifact.step,
                url: artifact.url,
                marker: reviewed ? "✓" : "○",
                title: artifact.displayTitle,
                selected: selectedReviewKey == key,
                commentCount: comments,
                reviewKey: key
            )
            button.onClick = { [weak self] in self?.selectReviewItem($0) }
            reviewPane.addArrangedSubview(button)
        }
    }

    private func clearArrangedSubviews(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    /// The core suggest-only interaction (US-004 AC3/AC4). Every click selects the
    /// clicked step's doc; only the *next incomplete* step pre-types its command, and
    /// only when the terminal's input line is empty — otherwise it's a no-op with
    /// visible feedback (edge case 1), preserving every byte the user already typed.
    private func handleStep(_ step: PlanningStep) {
        selectStep(step, preferArtifact: true)
        guard step == state?.nextIncomplete?.step else { return }   // done steps: doc only
        clearFeedback()
        if let surface, surface.hasUnsentInput {
            showSkipped(step)
            return
        }
        surface?.insertSuggested(step.command)
        onSuggestCommand?(step.command)
    }

    private func selectReviewItem(_ button: PlanningReviewButton) {
        selectedStep = button.step
        if let key = button.reviewKey,
           let artifact = state?.artifacts.first(where: { $0.reviewKey == key }) {
            selectArtifact(artifact)
        } else {
            selectedArtifactURL = nil
            selectedReviewKey = nil
            selectDoc(for: button.step)
        }
        rebuildReviewListIfPossible()
    }

    private func selectStep(_ step: PlanningStep?, preferArtifact: Bool) {
        selectedStep = step
        if preferArtifact, let step,
           let artifact = state?.artifacts(for: step).first {
            selectArtifact(artifact)
        } else {
            selectedArtifactURL = nil
            selectedReviewKey = nil
            selectDoc(for: step)
        }
        rebuildReviewListIfPossible()
    }

    private func selectArtifact(_ artifact: PlanningArtifactState) {
        clearFileViewChrome()
        selectedArtifactURL = artifact.url
        selectedReviewKey = artifact.reviewKey
        selectedStep = artifact.step
        documentHeaderField.stringValue = artifact.displayTitle
        commentField.placeholderString = "Comment on \(FeedbackDraft.stem(artifact.reviewKey))…"
        if let viewID = artifact.viewID {
            presentStory(viewID)
            return
        }
        hideStoryPane()
        let markdown = (try? String(contentsOf: artifact.url, encoding: .utf8)) ?? ""
        documentPane.textStorage?.setAttributedString(
            renderer.render(markdown.isEmpty ? "_Empty planning artifact._" : markdown)
        )
    }

    private func selectDoc(for step: PlanningStep?) {
        clearFileViewChrome()
        hideStoryPane()
        let markdown = step
            .flatMap { s in state?.steps.first { $0.step == s }?.artifact }
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        documentHeaderField.stringValue = step?.rawValue ?? "Planning"
        documentPane.textStorage?.setAttributedString(
            renderer.render(markdown.isEmpty ? placeholder(for: step) : markdown)
        )
    }

    /// Show a saha/v2 LikeC4 view over the doc area: the task's `model/` project,
    /// deep-linked to the item's view id. Re-presenting the same model with another
    /// view id only renavigates the hash (ArchitecturePane's fast path), so clicking
    /// through stories is cheap.
    private func presentStory(_ viewID: String) {
        guard let taskFolder else { return }
        storyPane.isHidden = false
        if let documentScrollView { storyPane.frame = documentScrollView.bounds }
        storyPane.present(projectDir: taskFolder, modelDir: "model", deepLinkView: viewID)
    }

    /// Keep the frame-managed story pane glued to the doc scroll area (see `buildLayout`
    /// for why it must not be constraint-pinned).
    override func layout() {
        super.layout()
        if let documentScrollView { storyPane.frame = documentScrollView.bounds }
    }

    /// Hide (but keep warm) the story pane while a markdown item is up; `resetArchitecture`
    /// does the real teardown when Planning Mode is left (0-RAM rule).
    private func hideStoryPane() {
        storyPane.isHidden = true
    }

    /// Re-render whatever the doc pane is currently showing (used when a mermaid image
    /// finishes rendering asynchronously and needs to replace its fallback text).
    private func refreshCurrentDoc() {
        if isViewingFile { return }   // a source file is up; don't clobber it
        if let selectedArtifact { selectArtifact(selectedArtifact) }
        else { selectDoc(for: selectedStep) }
    }

    // MARK: - In-doc file viewer (US: "peek at a referenced source file, then go back")

    /// Open a `foo/Bar.swift:48-97` reference from a doc link in the same pane, with the
    /// referenced lines highlighted and a back affordance. The selected doc/step is left
    /// untouched, so `exitFileView()` restores it with no navigation stack.
    func openFileRef(_ ref: String) {
        guard let (url, lines) = resolveFileRef(ref) else {
            documentHeaderField.stringValue = "not found: \(ref)"
            return
        }
        let code = (try? String(contentsOf: url, encoding: .utf8)) ?? "Could not read \(url.path)"
        hideStoryPane()
        documentPane.textStorage?.setAttributedString(renderSource(code, highlight: lines))
        documentHeaderField.stringValue = ref
        isViewingFile = true
        docBackButton.isHidden = false
        approveFileButton.isHidden = true
        if let first = lines?.lowerBound { scrollToSourceLine(first, in: code) }
    }

    private func exitFileView() {
        guard isViewingFile else { return }
        clearFileViewChrome()
        refreshCurrentDoc()
    }

    private func clearFileViewChrome() {
        isViewingFile = false
        docBackButton.isHidden = true
        approveFileButton.isHidden = false
    }

    /// Try each candidate root (project dir, task folder, then task-folder ancestors) until
    /// `root/<path>` is a readable file — handles doc refs like `app/Sources/...` written
    /// relative to a repo root several levels above the task folder.
    private func resolveFileRef(_ ref: String) -> (URL, ClosedRange<Int>?)? {
        let (path, lines) = splitLineSuffix(ref)
        for base in candidateRoots() {
            let candidate = base.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) { return (candidate, lines) }
        }
        return nil
    }

    private func candidateRoots() -> [URL] {
        var roots: [URL] = []
        if let projectDir { roots.append(URL(fileURLWithPath: projectDir)) }
        if var dir = taskFolder {
            roots.append(dir)
            for _ in 0..<8 { dir.deleteLastPathComponent(); roots.append(dir) }
        }
        return roots
    }

    /// Split `Bar.swift:48-97` → ("Bar.swift", 48...97); no suffix → (ref, nil).
    private func splitLineSuffix(_ ref: String) -> (String, ClosedRange<Int>?) {
        let parts = ref.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return (ref, nil) }
        // Take the first comma-segment (`38-39,52` → `38-39`) as the range to reveal.
        let first = parts[1].split(separator: ",").first ?? parts[1]
        let nums = first.split(separator: "-").compactMap { Int($0) }
        guard let lo = nums.first else { return (String(parts[0]), nil) }
        return (String(parts[0]), lo...(nums.count > 1 ? max(lo, nums[1]) : lo))
    }

    /// Line-numbered mono render of a source file, referenced lines tinted.
    private func renderSource(_ code: String, highlight: ClosedRange<Int>?) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let out = NSMutableAttributedString()
        for (idx, line) in code.components(separatedBy: "\n").enumerated() {
            let row = NSMutableAttributedString(
                string: String(format: "%4d  ", idx + 1),
                attributes: [.font: mono, .foregroundColor: BoardTheme.textFaint])
            row.append(NSAttributedString(string: line + "\n",
                attributes: [.font: mono, .foregroundColor: BoardTheme.textPrimary]))
            if let highlight, highlight.contains(idx + 1) {
                row.addAttribute(.backgroundColor, value: BoardTheme.attention.withAlphaComponent(0.16),
                                 range: NSRange(location: 0, length: row.length))
            }
            out.append(row)
        }
        return out
    }

    private func scrollToSourceLine(_ line: Int, in code: String) {
        let lines = code.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return }
        let offset = lines[0..<(line - 1)].reduce(0) { $0 + ($1 as NSString).length + 7 }  // +gutter+\n
        documentPane.scrollRangeToVisible(NSRange(location: offset, length: 0))
    }

    private func rebuildReviewListIfPossible() {
        if let state { rebuildReviewList(state); updateSummary() }
    }

    /// No artifact yet — explain the empty pane instead of leaving a blank box: which
    /// command produces this step's doc, and that its output lands here.
    private func placeholder(for step: PlanningStep?) -> String {
        guard let step else { return "_Select a step to view its planning doc._" }
        return """
        ### \(step.rawValue) — not started

        Click **\(step.shortName)** in the pipeline strip to type `\(step.command)` into
        the terminal, then press **Enter** to run it. Its output will appear here.
        """
    }

    private func showSkipped(_ step: PlanningStep) {
        lastFeedback = "Input in progress — press Enter or clear the line first"
        feedbackField.stringValue = lastFeedback ?? ""
        (stepperPane.arrangedSubviews.compactMap { $0 as? PlanningStepButton }
            .first { $0.step == step })?.flashSkipped()
    }

    private func clearFeedback() {
        lastFeedback = nil
        feedbackField.stringValue = ""
    }

    /// ⌘J dock/collapse. Collapsed = the design's reading mode: the terminal folds to
    /// a 44pt status rail and the doc viewer relaxes into wider margins.
    private func toggleTerminal() {
        terminalCollapsed.toggle()
        applyTerminalPresentation()
    }

    private func applyTerminalPresentation() {
        terminalContainer.superview?.isHidden = terminalCollapsed
        // No expanded terminal → no boundary to drag.
        paneDivider.isHidden = terminalCollapsed
        terminalRail.isHidden = !terminalCollapsed
        terminalToggle.stringValue = terminalCollapsed ? "◂ ⌘J terminal" : "⌘J terminal ▸"
        documentPane.setReadingMode(terminalCollapsed: terminalCollapsed)
    }

    // MARK: - Pane layout (rail fold + draggable reader/terminal boundary)

    /// Test seam: the terminal panel's current width as the drag/persistence sees it.
    var terminalPaneWidth: CGFloat { terminalWidthConstraint?.constant ?? 0 }
    var isRailHidden: Bool { reviewRail?.isHidden ?? false }

    /// Fold the REVIEW NOW rail away so the reader/terminal get its 270pt. Persisted —
    /// an operator who reviews on a laptop shouldn't re-hide it every session.
    func toggleRail() {
        guard let reviewRail else { return }
        reviewRail.isHidden.toggle()
        paneLayout.setBool(reviewRail.isHidden, forKey: PaneLayoutStore.planningRailHiddenKey)
        applyRailPresentation()
    }

    private func applyRailPresentation() {
        railToggle.stringValue = isRailHidden ? "rail ▸" : "◂ rail"
    }

    private func wireDividerDrag() {
        paneDivider.onDragStart = { [weak self] in
            self?.dragStartWidth = self?.terminalWidthConstraint?.constant
        }
        paneDivider.onDrag = { [weak self] delta in
            guard let self, let dragStartWidth else { return }
            // The divider sits left of the terminal: dragging LEFT (negative delta)
            // grows the terminal.
            setTerminalWidth(dragStartWidth - delta)
        }
        paneDivider.onDragEnd = { [weak self] in
            guard let self else { return }
            dragStartWidth = nil
            paneLayout.setWidth(terminalPaneWidth,
                                forKey: PaneLayoutStore.planningTerminalWidthKey)
        }
    }

    private func setTerminalWidth(_ proposed: CGFloat) {
        guard let constraint = terminalWidthConstraint, let panesView else { return }
        let minTerminal: CGFloat = 280
        let minReader: CGFloat = 300
        let railWidth: CGFloat = isRailHidden ? 0 : 270
        let ceiling = panesView.bounds.width - PaneDivider.thickness - railWidth - minReader
        guard ceiling > minTerminal else { return }
        constraint.constant = min(max(proposed, minTerminal), ceiling)
        panesView.layoutSubtreeIfNeeded()
    }

    // MARK: - Review actions (comments + approvals, persisted via ReviewStore)

    @objc private func commentFieldEntered() { addComment() }

    private func addComment() {
        guard let selectedReviewKey, let reviewStore else { return }
        let text = commentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reviewStore.addComment(file: selectedReviewKey, text: text)
        commentField.stringValue = ""
        rebuildReviewListIfPossible()
    }

    private func approveSelectedArtifact() {
        guard let selectedReviewKey else { return }
        reviewStore?.approve(selectedReviewKey)
        if let artifact = state?.artifacts.first(where: { $0.reviewKey == selectedReviewKey }) {
            writeBackApproval(of: [artifact], step: artifact.step)
        }
        rebuildReviewListIfPossible()
    }

    private func approveRemaining() {
        guard let state, let reviewStore else { return }
        let step = selectedStep ?? state.nextIncomplete?.step ?? .research
        let artifacts = state.artifacts(for: step)
        for artifact in artifacts {
            reviewStore.approve(artifact.reviewKey)
        }
        writeBackApproval(of: artifacts, step: step)
        rebuildReviewListIfPossible()
    }

    /// saha/v2: approvals also land in progress.yaml — the file the saha loop treats
    /// as the single tracking surface. A story approval flips it `draft → ready`; once
    /// every artifact of a step is approved the step's planning entry flips to `done`.
    /// The writer itself refuses outside `status: planning`, so execution-phase files
    /// (where the saha manager agent is the only writer) are never touched. `verify`
    /// is excluded: its status/result belong to `/saha:verify`.
    private func writeBackApproval(of artifacts: [PlanningArtifactState], step: PlanningStep) {
        guard let state, state.isV2, let taskFolder else { return }
        var changed = false
        for artifact in artifacts where artifact.step == .userStories {
            if PlanningProgressWriteback.approveStory(taskFolder: taskFolder,
                                                      reviewKey: artifact.reviewKey) {
                changed = true
            }
        }
        let stepArtifacts = state.artifacts(for: step)
        if step != .verify, !stepArtifacts.isEmpty,
           stepArtifacts.allSatisfy({ reviewStore?.isApproved($0.reviewKey) ?? false }),
           PlanningProgressWriteback.markStepDone(taskFolder: taskFolder, step: step) {
            changed = true
        }
        if changed { refresh(folder: taskFolder) }
    }

    /// Compose the queued comments into a single-line revision command and PRE-TYPE it
    /// (never submit — the operator reads it and presses Enter). No comments → suggest
    /// the bare step command instead.
    private func sendFeedbackDraft() {
        guard let step = selectedStep ?? state?.nextIncomplete?.step else { return }
        let queued = currentQueuedComments()
        let command = FeedbackDraft.compose(command: step.command, comments: queued)
            ?? step.command
        if let surface, surface.hasUnsentInput {
            showSkipped(step)
            return
        }
        surface?.insertSuggested(command)
        onSuggestCommand?(command)
        if !queued.isEmpty { reviewStore?.markQueuedSent() }
        lastFeedback = queued.isEmpty
            ? "No comments; queued \(step.command)"
            : "Feedback draft queued in terminal — unsent until you press Enter"
        feedbackField.stringValue = lastFeedback ?? ""
        rebuildReviewListIfPossible()
    }

    // MARK: - Keyboard (design: ↑↓/j·k next file, a approve)

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "[":
            onReturn?()
            return true
        case "j":
            // The chips have promised ⌘J since the first mockup — honor it.
            toggleTerminal()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "j": moveFileSelection(by: 1)
        case "k": moveFileSelection(by: -1)
        case "a": approveSelectedArtifact()
        default:
            switch event.keyCode {
            case 125: moveFileSelection(by: 1)   // ↓
            case 126: moveFileSelection(by: -1)  // ↑
            default: super.keyDown(with: event)
            }
        }
    }

    private func moveFileSelection(by delta: Int) {
        guard let state else { return }
        let step = selectedStep ?? state.nextIncomplete?.step ?? .research
        let items = state.artifacts(for: step)
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.reviewKey == selectedReviewKey } ?? -1
        let next = min(max(current + delta, 0), items.count - 1)
        selectArtifact(items[next])
        rebuildReviewListIfPossible()
    }

    // MARK: - Summary

    private func updateSummary() {
        guard let state else {
            progressField.stringValue = ""
            reviewSummaryField.stringValue = ""
            reviewLeftField.stringValue = ""
            return
        }
        let step = selectedStep ?? state.nextIncomplete?.step ?? .research
        let position = (PlanningStep.allCases.firstIndex(of: step) ?? 0) + 1
        let artifacts = state.artifacts(for: step)
        let files = artifacts.map(\.reviewKey)
        let reviewed = files.filter {
            (reviewStore?.isApproved($0) ?? false) || !(reviewStore?.comments(for: $0).isEmpty ?? true)
        }.count
        let queued = currentQueuedComments().count
        progressField.stringValue =
            "\(state.taskFolder.lastPathComponent) · reviewing: \(step.shortName) \(position)/\(state.steps.count)"
        reviewLeftField.stringValue = files.isEmpty ? "" : "\(files.count - reviewed) left"
        reviewSummaryField.stringValue =
            "\(reviewed)/\(max(files.count, 1)) files · \(queued) comments"
        terminalStatusField.stringValue = "Claude Code"
        railDraftField.stringValue = queued > 0 ? "draft \(queued)●" : ""
        terminalToggle.stringValue = terminalCollapsed
            ? "◂ ⌘J terminal" : queued > 0 ? "⌘J terminal · \(queued)● ▸" : "⌘J terminal ▸"
    }

    private func currentQueuedComments() -> [ReviewComment] {
        guard let state, let reviewStore else { return [] }
        let step = selectedStep ?? state.nextIncomplete?.step ?? .research
        let files = Set(state.artifacts(for: step).map(\.reviewKey))
        return reviewStore.queued.filter { files.contains($0.file) }
    }
}

extension PlanningModeView: NSTextViewDelegate {
    /// A `sich-file:` link (emitted by the markdown renderer for source-path code
    /// spans) opens the file in the doc pane; returning true suppresses the default
    /// "open in browser" handling. Other links fall through to the system.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = link as? URL ?? (link as? String).flatMap { URL(string: $0) }
        guard url?.scheme == "sich-file", let url else { return false }
        let ref = String(url.absoluteString.dropFirst("sich-file:".count))
            .removingPercentEncoding ?? ""
        openFileRef(ref)
        return true
    }
}
