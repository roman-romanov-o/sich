import AppKit
import GhostlingCore

/// One recent project the palette offers on stage 1.
struct PaletteProject: Equatable {
    let path: String
    let activeCards: Int
    var leaf: String { (path as NSString).lastPathComponent }
    var display: String { (path as NSString).abbreviatingWithTildeInPath }
}

/// A clickable palette row (layer-backed, owns its whole rect for hit-testing +
/// real `mouseDown` — the only click path that both composites and receives events
/// on this dark UI; stock `NSButton` fails on both counts here). Renders a leading
/// glyph, a title (+ optional mono id / subtitle), an optional trailing meta, and
/// an optional 8-segment progress bar — enough for every row the three stages use.
final class PaletteRow: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { restyle() } }

    private let glyph = makeMono(9)
    private let idChip = makeMono(11)
    private let title = makeSans(12, weight: .semibold)
    private let subtitle = makeMono(10)
    private let meta = makeMono(9)
    private var bar: NSStackView?
    private let accent: NSColor

    /// `accent` tints the selected fill/glyph — amber for tasks/projects, done-green
    /// for "create new". `progress` (when non-nil) adds the segmented bar below.
    init(glyph: String, idChip: String? = nil, title: String, subtitle: String? = nil,
         meta: String? = nil, accent: NSColor = BoardTheme.attention,
         progress: TaskFolderProgress? = nil, titleColor: NSColor? = nil) {
        self.accent = accent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        self.glyph.stringValue = glyph
        self.title.stringValue = title
        self.title.textColor = titleColor ?? BoardTheme.textPrimary
        idChip.map { self.idChip.stringValue = $0 }
        subtitle.map { self.subtitle.stringValue = $0 }
        meta.map { self.meta.stringValue = $0 }
        buildLayout(hasID: idChip != nil, hasSubtitle: subtitle != nil,
                    hasMeta: meta != nil, progress: progress)
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    // A plain NSView reports it can move the window, so the window steals the click
    // as a background-drag and never delivers mouseDown. This row IS the control.
    override var mouseDownCanMoveWindow: Bool { false }
    // …and act on the very first click even when the window wasn't key (a plain
    // NSView, unlike NSControl, otherwise eats it as window-activation).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildLayout(hasID: Bool, hasSubtitle: Bool, hasMeta: Bool,
                             progress: TaskFolderProgress?) {
        let head = NSStackView(views: [glyph] + (hasID ? [idChip] : []) + [title]
            + (hasMeta ? [meta] : []))
        head.spacing = 10
        head.alignment = .centerY
        glyph.widthAnchor.constraint(equalToConstant: 14).isActive = true
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var rows: [NSView] = [head]
        if hasSubtitle { rows.append(indented(subtitle, by: hasID || hasSubtitle ? 24 : 24)) }
        if let progress { bar = makeBar(progress); rows.append(indented(bar!, by: 24)) }
        let col = NSStackView(views: rows)
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 4
        col.edgeInsets = NSEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        pin(col, to: self)
    }

    private func restyle() {
        themedBackground = isSelected ? accent.withAlphaComponent(0.08) : .clear
        layer?.borderWidth = isSelected ? 1 : 0
        themedBorder = isSelected ? accent.withAlphaComponent(0.27) : nil
        glyph.textColor = isSelected ? accent : BoardTheme.textDim
        subtitle.textColor = isSelected ? BoardTheme.hex(0xB39A6E) : BoardTheme.textDim
        meta.textColor = isSelected ? BoardTheme.hex(0xB39A6E) : BoardTheme.textDim
        idChip.textColor = BoardTheme.textMuted
    }

    private func makeBar(_ progress: TaskFolderProgress) -> NSStackView {
        let (done, total): (Int, Int) = {
            if case let .known(c, t) = progress, t > 0 { return (c, t) }
            return (0, 8)
        }()
        let segs = (0..<max(total, 1)).map { i -> NSView in
            let s = NSView()
            s.wantsLayer = true
            s.layer?.cornerRadius = 2
            // ponytail: pure completion bar — green done vs empty. No amber "next"
            // segment: we have no in-progress signal, so it just contradicted the N/M badge.
            s.themedBackground = i < done ? BoardTheme.stateColor(.done)
                : BoardTheme.cardStroke
            s.heightAnchor.constraint(equalToConstant: 4).isActive = true
            return s
        }
        let stack = NSStackView(views: segs)
        stack.spacing = 3
        stack.distribution = .fillEqually
        stack.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return stack
    }

    private func indented(_ v: NSView, by pad: CGFloat) -> NSView {
        let wrap = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: pad),
            v.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            v.topAnchor.constraint(equalTo: wrap.topAnchor),
            v.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
        return wrap
    }
}

/// A Saha / Interactive radio-card (stage 3). Same click idiom as ``PaletteRow``.
final class FlowOptionCard: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { restyle() } }
    private let dot = NSView()
    private let title: NSTextField
    private let desc: NSTextField

    init(title: String, desc: String) {
        self.title = makeSans(13, weight: .bold)
        self.desc = makeSans(10.5, weight: .regular)
        self.title.stringValue = title
        self.desc.stringValue = desc
        // A label factory makes a single-line field; without word-wrap the description
        // truncates ("…docs/tasks/ fol") instead of flowing to the 3 lines it's given.
        self.desc.maximumNumberOfLines = 3
        self.desc.lineBreakMode = .byWordWrapping
        self.desc.cell?.usesSingleLineMode = false
        self.desc.cell?.wraps = true
        self.desc.preferredMaxLayoutWidth = 230
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 7
        dot.widthAnchor.constraint(equalToConstant: 14).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let head = NSStackView(views: [dot, self.title])
        head.spacing = 7
        head.alignment = .centerY
        let col = NSStackView(views: [head, self.desc])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 5
        col.edgeInsets = NSEdgeInsets(top: 11, left: 13, bottom: 11, right: 13)
        pin(col, to: self)
        self.desc.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func restyle() {
        let a = BoardTheme.attention
        // Quieter wash than a focused list row (0.08): the filled radio dot carries the
        // "committed pick" signal, so this doesn't fight the arrow-key cursor for amber.
        themedBackground = isSelected ? a.withAlphaComponent(0.05) : .clear
        layer?.borderWidth = isSelected ? 1 : 1
        themedBorder = isSelected ? a : BoardTheme.cardFillRaised
        dot.layer?.borderWidth = isSelected ? 4 : 1
        dot.themedBorder = isSelected ? a : BoardTheme.textDim
        title.textColor = isSelected ? BoardTheme.textPrimary : BoardTheme.textMuted
        desc.textColor = isSelected ? BoardTheme.hex(0xB39A6E) : BoardTheme.textDim
    }
}

/// The interactive-flow "own git worktree" switch (stage 3). A custom-drawn toggle,
/// NOT `NSButton(checkboxWithTitle:)`: the stock checkbox rendered near-invisible on
/// this hand-painted dark UI — a washed-out glyph beside low-contrast grey text — the
/// same composite failure ``PaletteRow`` and ``FlowOptionCard`` were built to dodge.
/// This reuses their proven idiom: layer-backed, owns its whole rect, real
/// `mouseDown`. A 20pt box fills amber with a check when on, so the state reads at a
/// glance. Off by default — a worktree is an opt-IN, never a surprise side branch.
final class WorktreeToggle: NSView {
    var onToggle: ((Bool) -> Void)?
    private(set) var isOn: Bool
    private let box = NSView()
    private let check = makeMono(13)
    private let title = makeSans(12, weight: .semibold)
    private let subtitle = makeMono(10)

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        title.stringValue = "Own git worktree"
        subtitle.stringValue = "fresh task/<name> branch · isolated checkout"
        check.stringValue = "✓"
        check.alignment = .center
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        box.layer?.borderWidth = 1.5
        box.widthAnchor.constraint(equalToConstant: 20).isActive = true
        box.heightAnchor.constraint(equalToConstant: 20).isActive = true
        check.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(check)
        NSLayoutConstraint.activate([
            check.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            check.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        let col = NSStackView(views: [title, subtitle])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 2
        let row = NSStackView(views: [box, col])
        row.alignment = .centerY
        row.spacing = 11
        row.edgeInsets = NSEdgeInsets(top: 11, left: 13, bottom: 11, right: 13)
        pin(row, to: self)
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { toggle() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Flip and notify — the seam a real `mouseDown` drives (the interaction-AC
    /// binding rule: click ACs are exercised by a dispatched event, not a state poke).
    func toggle() {
        isOn.toggle()
        restyle()
        onToggle?(isOn)
    }

    private func restyle() {
        let a = BoardTheme.attention
        themedBackground = isOn ? a.withAlphaComponent(0.06) : BoardTheme.canvas
        layer?.borderWidth = 1
        themedBorder = isOn ? a.withAlphaComponent(0.4) : BoardTheme.cardStrokeStrong
        box.themedBackground = isOn ? a : NSColor.clear
        box.themedBorder = isOn ? a : BoardTheme.textFaint
        check.textColor = isOn ? BoardTheme.canvas : .clear
        check.isHidden = !isOn
        title.textColor = isOn ? BoardTheme.textPrimary : BoardTheme.textMuted
        subtitle.textColor = BoardTheme.textDim
    }
}

// MARK: - shared makers

@MainActor func makeMono(_ size: CGFloat) -> NSTextField {
    let l = NSTextField(labelWithString: "")
    l.font = .monospacedSystemFont(ofSize: size, weight: .regular)
    l.textColor = BoardTheme.textDim
    return l
}
@MainActor func makeSans(_ size: CGFloat, weight: NSFont.Weight) -> NSTextField {
    let l = NSTextField(labelWithString: "")
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = BoardTheme.textPrimary
    return l
}
@MainActor func pin(_ v: NSView, to parent: NSView) {
    v.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(v)
    NSLayoutConstraint.activate([
        v.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
        v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        v.topAnchor.constraint(equalTo: parent.topAnchor),
        v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
    ])
}

/// The ⌘N create-card palette: a floating, keyboard-first wizard —
/// project → harness → task — replacing the old NSAlert + bare task-chooser.
/// A dumb view: the shell wires the four confirm closures to its card-creation
/// logic (which owns the pool firewall + binding invariants). Reaching the "create"
/// action for a saha task hands off to the shell, which enters planning mode.
final class CreateCardPalette: NSView, NSTextFieldDelegate {
    enum Stage { case project, harness, task }
    enum Flow { case saha, interactive }
    enum Harness: CaseIterable {
        case claude
        case codex
        case shell

        var title: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .shell: return "Interactive shell"
            }
        }

        var subtitle: String {
            switch self {
            case .claude: return "claude · supports /saha:* commands"
            case .codex: return "codex · OpenAI coding agent CLI"
            case .shell: return "bare login shell · run any CLI yourself"
            }
        }

        var cardAgent: CardAgent? {
            switch self {
            case .claude: return .claude
            case .codex: return .codex
            case .shell: return nil
            }
        }
    }

    // Shell wires these. Each saha confirm returns an error string (nil = success,
    // shell has dismissed us + entered planning); interactive never fails visibly.
    var confirmInteractive: ((_ title: String, _ dir: String, _ harness: Harness, _ inWorktree: Bool) -> Void)?
    var confirmSahaNew: ((_ title: String, _ dir: String) -> String?)?
    var confirmSahaExisting: ((_ folder: URL, _ dir: String) -> String?)?
    var browse: (() -> String?)?
    var onCancel: (() -> Void)?
    // Discover the task folders under a chosen project dir (shell injects
    // TaskFolderIndex) — called when the task stage opens so the saha bind-list is live.
    var discoverFolders: ((_ dir: String) -> [TaskFolderSummary])?

    // Test seams — the real gestures the integration tests dispatch.
    private(set) var navRows: [PaletteRow] = []
    private(set) var flowCards: [FlowOptionCard] = []
    let nameField = NSTextField()
    private let nameBox = NSView()
    let errorLabel = makeMono(11)
    private(set) var stage: Stage = .project

    private let recents: [PaletteProject]
    private var projectDir: String
    private var harness: Harness = .claude
    /// Off by default: a worktree is an explicit opt-IN. When on, the task gets its
    /// own git worktree (fresh `task/<slug>` branch) so parallel cards on one repo
    /// don't share a checkout — but that's a deliberate choice, not a surprise.
    private(set) var inWorktree = false
    private(set) var worktreeToggle: WorktreeToggle?
    private var flow: Flow = .saha
    private var folders: [TaskFolderSummary] = []
    private var selected = 0

    private let card = NSView()
    private let body = NSStackView()
    private let header = NSStackView()
    private let footer = makeMono(9)

    init(recents: [PaletteProject]) {
        self.recents = recents
        self.projectDir = recents.first?.path ?? ""
        super.init(frame: .zero)
        buildChrome()
        renderStage()
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    // MARK: chrome

    private func buildChrome() {
        wantsLayer = true
        themedBackground = NSColor.black.withAlphaComponent(0.62)
        card.wantsLayer = true
        card.themedBackground = BoardTheme.cardFill
        card.themedBorder = BoardTheme.cardStrokeStrong
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = 12
        card.layer?.shadowColor = .black
        card.layer?.shadowOpacity = 0.55
        card.layer?.shadowRadius = 32
        card.layer?.shadowOffset = CGSize(width: 0, height: -12)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 560),
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 13, left: 16, bottom: 13, right: 16)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 2
        body.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        footer.textColor = BoardTheme.textMuted   // the keyboard legend must clear AA; 0x39414C didn't
        errorLabel.textColor = BoardTheme.alert
        errorLabel.isHidden = true
        let hairline = { () -> NSView in
            let v = NSView(); v.wantsLayer = true
            v.themedBackground = BoardTheme.hairline
            v.heightAnchor.constraint(equalToConstant: 1).isActive = true
            return v
        }
        let stack = NSStackView(views: [header, hairline(), body, errorLabel, hairline(), footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        pin(stack, to: card)
        for v in [header, body] { v.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true }
        footer.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
    }

    private func sectionLabel(_ text: String) -> NSView {
        let l = makeMono(9)
        l.stringValue = text
        l.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        l.textColor = BoardTheme.textFaint   // AA-legible eyebrow (textDim was 2.4:1)
        let wrap = NSView()
        l.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10),
            l.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 6),
            l.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -3),
            l.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor),
        ])
        return wrap
    }

    private func chip(_ text: String, done: Bool, accent: NSColor? = nil) -> NSView {
        let l = makeMono(10)
        l.stringValue = text
        l.textColor = accent ?? (done ? BoardTheme.textFaint : BoardTheme.textDim)
        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.cornerRadius = 4
        wrap.layer?.borderWidth = 1
        wrap.themedBorder = accent?.withAlphaComponent(0.5)
            ?? (done ? BoardTheme.cardStroke : BoardTheme.cardStrokeStrong)
        wrap.themedBackground = accent?.withAlphaComponent(0.10)
            ?? (done ? BoardTheme.canvas : .clear)
        l.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 7),
            l.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -7),
            l.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 3),
            l.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -3),
        ])
        return wrap
    }

    // MARK: stage rendering

    private func renderStage() {
        errorLabel.isHidden = true
        selected = 0
        header.arrangedSubviews.forEach { $0.removeFromSuperview() }
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        navRows = []
        flowCards = []
        switch stage {
        case .project: renderProject()
        case .harness: renderHarness()
        case .task: renderTask()
        }
        highlight()
        window?.makeFirstResponder(stage == .task ? nameField : self)
    }

    private func addHeader(_ chipText: String, completed: [String]) {
        header.addArrangedSubview(chip(chipText, done: false, accent: BoardTheme.attention))
        completed.forEach { header.addArrangedSubview(chip($0, done: true)) }
        // No trailing corner hint: it duplicated the footer legend and a lone glyph
        // ("⌫ back") read as ambiguous. The footer is the single source of shortcuts.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(spacer)
    }

    private func setFooter(_ hints: [String]) {
        footer.stringValue = hints.joined(separator: "    ")
    }

    private func add(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(v)
        v.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 8).isActive = true
        v.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -8).isActive = true
    }

    private func addNav(_ row: PaletteRow) {
        navRows.append(row)
        let idx = navRows.count - 1
        row.onClick = { [weak self] in self?.activate(idx) }
        add(row)
    }

    // MARK: stage 1 — project

    private func renderProject() {
        addHeader("1/3 project", completed: [])
        add(sectionLabel("RECENT PROJECTS"))
        for p in recents {
            // Fixed two-part template every row, incl. the zero case, so the scanned
            // list has even info density (a bare path next to a "· N active" one snags the eye).
            let tail = p.activeCards == 0
                ? "no active cards"
                : "\(p.activeCards) active card\(p.activeCards == 1 ? "" : "s")"
            let sub = "\(p.display) · \(tail)"
            addNav(PaletteRow(glyph: "", title: p.leaf, subtitle: sub))
        }
        // An action, not a project-pick: neutral title + leading glyph, amber-on-select
        // like every other row. (Was system-blue — the one accent breaking the palette.)
        let browseRow = PaletteRow(glyph: "+", title: "Browse folder…", meta: "",
                                   titleColor: BoardTheme.textMuted)
        browseRow.onClick = { [weak self] in self?.doBrowse() }
        navRows.append(browseRow)   // navigable, but not a project-pick
        add(browseRow)
        setFooter(["↵ next: harness", "↑↓ navigate", "esc cancel"])
    }

    // MARK: stage 2 — harness

    private func renderHarness() {
        addHeader("2/3 harness", completed: [projLeaf])
        add(sectionLabel("HARNESS — RUNS THE SESSION"))
        for option in Harness.allCases {
            let glyph = option.cardAgent.map { BoardTheme.agentGlyph($0) } ?? ""
            addNav(PaletteRow(glyph: glyph, title: option.title, subtitle: option.subtitle))
        }
        setFooter(["↵ next: task", "↑↓ navigate", "← back", "esc cancel"])
    }

    // MARK: stage 3 — task

    private func renderTask() {
        addHeader("3/3 task", completed: [projLeaf, harness.title])
        buildNameField()
        buildFlowGrid()
        if flow == .saha { buildFolderList() } else { buildWorktreeToggle() }
        // ponytail: ← / ↔ not ⌫ / ⇥ — the mono glyph font lacks U+232B & U+21E5
        // (they fall back to unrelated substitutes); basic arrows render clean.
        setFooter(flow == .saha
            ? ["↵ create / bind", "↑↓ folder", "↔ flow", "← back", "esc cancel"]
            : ["↵ create", "↔ flow", "← back", "esc cancel"])
    }

    private func buildNameField() {
        nameField.placeholderString = "Name this task — e.g. Fix the login redirect"
        nameField.font = .systemFont(ofSize: 13)
        nameField.textColor = BoardTheme.textPrimary
        nameField.drawsBackground = false
        nameField.isBordered = false
        nameField.focusRingType = .none
        nameField.delegate = self
        // A real input box (inset fill + stroke, amber on focus) — a bare underline read
        // as a section label, so first-timers couldn't tell the most important field apart.
        nameBox.wantsLayer = true
        nameBox.layer?.cornerRadius = 8
        nameBox.themedBackground = BoardTheme.canvas
        nameBox.layer?.borderWidth = 1
        styleNameBox(focused: false)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameBox.addSubview(nameField)
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: nameBox.leadingAnchor, constant: 11),
            nameField.trailingAnchor.constraint(equalTo: nameBox.trailingAnchor, constant: -11),
            nameField.topAnchor.constraint(equalTo: nameBox.topAnchor, constant: 9),
            nameField.bottomAnchor.constraint(equalTo: nameBox.bottomAnchor, constant: -9),
        ])
        add(nameBox)
    }

    private func styleNameBox(focused: Bool) {
        nameBox.themedBorder =
            focused ? BoardTheme.attention : BoardTheme.cardStrokeStrong
    }

    func controlTextDidBeginEditing(_ obj: Notification) { styleNameBox(focused: true) }
    func controlTextDidEndEditing(_ obj: Notification) { styleNameBox(focused: false) }

    private func buildFlowGrid() {
        let saha = FlowOptionCard(title: "Saha",
            desc: "Structured pipeline. Binds a docs/tasks/ folder; you review each artifact.")
        let interactive = FlowOptionCard(title: "Interactive",
            desc: "Straight into a live terminal. No pipeline, no folder — you drive.")
        saha.isSelected = flow == .saha
        interactive.isSelected = flow == .interactive
        saha.onClick = { [weak self] in self?.pick(flow: .saha) }
        interactive.onClick = { [weak self] in self?.pick(flow: .interactive) }
        flowCards = [saha, interactive]
        let grid = NSStackView(views: [saha, interactive])
        grid.distribution = .fillEqually
        grid.spacing = 8
        add(grid)
    }

    private func buildFolderList() {
        add(sectionLabel("BIND TO TASK FOLDER"))
        for f in folders {
            addNav(PaletteRow(glyph: "", idChip: f.url.lastPathComponent, title: Self.normalizeTitle(f.title),
                              meta: progressText(f.progress), progress: f.progress))
        }
        let createRow = PaletteRow(glyph: "+", title: "Create new — scaffolds \(nextTaskID)",
                                   accent: BoardTheme.stateColor(.done),
                                   titleColor: BoardTheme.textMuted)
        addNav(createRow)
    }

    /// Interactive flow only: the opt-in "own git worktree" switch (off by default).
    /// Saha tasks stay in the repo checkout — their scaffolded docs/tasks folder
    /// lives there.
    private func buildWorktreeToggle() {
        add(sectionLabel("ISOLATION"))
        let toggle = WorktreeToggle(isOn: inWorktree)
        toggle.onToggle = { [weak self] on in self?.inWorktree = on }
        worktreeToggle = toggle
        add(toggle)
    }

    // MARK: selection + actions

    private func highlight() {
        for (i, r) in navRows.enumerated() { r.isSelected = (i == selected) }
    }

    private func move(_ delta: Int) {
        guard !navRows.isEmpty else { return }
        selected = (selected + delta + navRows.count) % navRows.count
        highlight()
    }

    /// Enter / click on nav row `idx`.
    private func activate(_ idx: Int) {
        selected = idx
        highlight()
        switch stage {
        case .project:
            if idx == navRows.count - 1 { doBrowse(); return }   // last = Browse…
            projectDir = recents[idx].path
            stage = .harness; renderStage()
        case .harness:
            harness = Harness.allCases[idx]
            folders = discoverFolders?(projectDir) ?? []
            stage = .task; renderStage()
        case .task:
            confirmTask(folderIndex: idx)
        }
    }

    private func confirmTask(folderIndex: Int?) {
        let title = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if flow == .interactive {
            confirmInteractive?(title, projectDir, harness, inWorktree)
            return
        }
        // saha: the last nav row is "Create new"; earlier rows are existing folders.
        let idx = folderIndex ?? selected
        let err: String?
        if idx == folders.count {   // create-new row
            guard !title.isEmpty else { showError("Name the task first."); return }
            err = confirmSahaNew?(title, projectDir)
        } else {
            err = confirmSahaExisting?(folders[idx].url, projectDir)
        }
        if let err { showError(err) }
    }

    private func pick(flow newFlow: Flow) {
        guard flow != newFlow else { return }
        flow = newFlow
        renderStage()   // rebuilds the folder list on/off
    }

    private func doBrowse() {
        guard let path = browse?(), !path.isEmpty else { return }
        projectDir = path
        stage = .harness; renderStage()
    }

    private func showError(_ text: String) {
        errorLabel.stringValue = text
        errorLabel.isHidden = false
    }

    private func back() {
        switch stage {
        case .project: onCancel?()
        case .harness: stage = .project; renderStage()
        case .task: stage = .harness; renderStage()
        }
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()                       // esc
        case 51: back()                            // ⌫
        case 125: move(1)                          // ↓
        case 126: move(-1)                         // ↑
        case 36, 76: activate(selected)            // ↵
        default: super.keyDown(with: event)
        }
    }

    /// Task-stage key routing while the name field holds focus.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): confirmTask(folderIndex: nil); return true
        case #selector(NSResponder.cancelOperation(_:)): onCancel?(); return true
        case #selector(NSResponder.insertTab(_:)):
            pick(flow: flow == .saha ? .interactive : .saha); return true
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.deleteBackward(_:)):
            guard nameField.stringValue.isEmpty else { return false }
            back(); return true                       // ⌫ on an empty field steps back
        default: return false
        }
    }

    // MARK: derived text

    private var projLeaf: String { (projectDir as NSString).lastPathComponent }

    /// Uppercase a leading `task-NN:` id prefix so one lowercase source heading doesn't
    /// read as a bug beside its ALL-CAPS siblings. ponytail: regex, no title parser.
    static func normalizeTitle(_ t: String) -> String {
        guard let r = t.range(of: #"(?i)^task-\d+:"#, options: .regularExpression) else { return t }
        return t.replacingCharacters(in: r, with: t[r].uppercased())
    }

    private func progressText(_ p: TaskFolderProgress) -> String {
        if case let .known(c, t) = p { return "\(c)/\(t)" }
        return "unknown"
    }

    /// Next `task-NN` id the scaffolder will mint (max existing + 1, min 01).
    private var nextTaskID: String {
        let nums = folders.compactMap { f -> Int? in
            let name = f.url.lastPathComponent          // task-08-slug
            let parts = name.split(separator: "-")
            return parts.count >= 2 ? Int(parts[1]) : nil
        }
        return String(format: "task-%02d", (nums.max() ?? 0) + 1)
    }

    /// Called by the shell after the project is fixed so stage 3 can list its folders.
    func loadFolders(_ list: [TaskFolderSummary]) { folders = list }

    /// Capture seam: jump to the harness stage for a known project.
    func presentHarnessStage(projectDir: String) {
        self.projectDir = projectDir
        self.stage = .harness
        renderStage()
    }

    /// Test/entry seam: jump straight to the saha task stage for a known project
    /// (mirrors the old `beginSahaCreation` entry the invariant tests use).
    func presentSahaTaskStage(projectDir: String, folders: [TaskFolderSummary]) {
        self.projectDir = projectDir
        self.folders = folders
        self.harness = .claude
        self.flow = .saha
        self.stage = .task
        renderStage()
    }
}
