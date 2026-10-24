import AppKit
import SichCore

/// One recent folder the palette offers, HOST-QUALIFIED (US-009 AC-2): `host` is the
/// ssh destination it lives on, and `nil` means THIS Mac. The same path on two boxes
/// is two entries, and a remote path never shows up under local.
///
/// `activeCards` is live board state, so it is deliberately outside `CodingKeys`:
/// what persists is *where a folder is*, never how busy it was last launch.
struct PaletteProject: Equatable, Codable {
    var host: String?
    var path: String
    var activeCards: Int = 0

    private enum CodingKeys: String, CodingKey { case host, path }

    var leaf: String { (path as NSString).lastPathComponent }
    var display: String {
        host == nil ? (path as NSString).abbreviatingWithTildeInPath : path
    }

    /// Same folder on the same machine — the recents store's dedup key.
    func isSameLocation(as other: PaletteProject) -> Bool {
        host == other.host && path == other.path
    }
}

/// The palette's recents MRU, persisted in `UserDefaults` (six entries per host need
/// no file or db). Host-qualification is enforced here rather than at the call sites:
/// every read and write carries the host, so no path can leak between machines.
///
/// Reads tolerate the pre-US-009 plain-`[String]` array — those entries predate remote
/// cards, so each one is a LOCAL folder by definition.
struct RecentFolderStore {
    let defaults: UserDefaults
    let key: String
    /// Per host, NOT global: six local folders must never evict the one folder you
    /// use on a remote box.
    var perHostLimit = 6

    func load() -> [PaletteProject] {
        (defaults.array(forKey: key) ?? []).compactMap(Self.decode)
    }

    func remember(host: String?, path: String) {
        // Only a local path has a local `~` to expand; a remote one is the far side's.
        let folder = host == nil ? (path as NSString).expandingTildeInPath : path
        guard !folder.isEmpty else { return }
        let fresh = PaletteProject(host: host, path: folder)
        var all = load().filter { !$0.isSameLocation(as: fresh) }
        all.insert(fresh, at: 0)
        defaults.set(capped(all).compactMap(Self.encode), forKey: key)
    }

    private func capped(_ all: [PaletteProject]) -> [PaletteProject] {
        var seen: [String: Int] = [:]
        return all.filter {
            let count = (seen[$0.host ?? ""] ?? 0) + 1
            seen[$0.host ?? ""] = count
            return count <= perHostLimit
        }
    }

    private static func decode(_ element: Any) -> PaletteProject? {
        if let legacy = element as? String {
            return legacy.isEmpty ? nil : PaletteProject(host: nil, path: legacy)
        }
        guard let data = element as? Data else { return nil }
        return try? JSONDecoder().decode(PaletteProject.self, from: data)
    }

    private static func encode(_ project: PaletteProject) -> Data? {
        try? JSONEncoder().encode(project)
    }
}

/// A clickable palette row (layer-backed, owns its whole rect for hit-testing +
/// real `mouseDown` — the only click path that both composites and receives events
/// on this dark UI; stock `NSButton` fails on both counts here). Renders a leading
/// glyph, a title (+ optional mono id / subtitle), and an optional trailing meta —
/// enough for every row the stages use.
final class PaletteRow: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { restyle() } }

    private let glyph = makeMono(9)
    private let idChip = makeMono(11)
    private let title = makeSans(12, weight: .semibold)
    private let subtitle = makeMono(10)
    private let meta = makeMono(9)
    private let accent: NSColor

    /// `accent` tints the selected fill/glyph — amber for tasks/projects.
    init(glyph: String, idChip: String? = nil, title: String, subtitle: String? = nil,
         meta: String? = nil, accent: NSColor = BoardTheme.attention,
         titleColor: NSColor? = nil) {
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
        buildLayout(hasID: idChip != nil, hasSubtitle: subtitle != nil, hasMeta: meta != nil)
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    /// What this row actually says on screen — read by tests so an assertion is about
    /// the rendered row rather than the array that produced it.
    // periphery:ignore - test-only entry (scan runs with exclude_tests)
    var titleText: String { title.stringValue }
    // A plain NSView reports it can move the window, so the window steals the click
    // as a background-drag and never delivers mouseDown. This row IS the control.
    override var mouseDownCanMoveWindow: Bool { false }
    // …and act on the very first click even when the window wasn't key (a plain
    // NSView, unlike NSControl, otherwise eats it as window-activation).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildLayout(hasID: Bool, hasSubtitle: Bool, hasMeta: Bool) {
        let head = NSStackView(views: [glyph] + (hasID ? [idChip] : []) + [title]
            + (hasMeta ? [meta] : []))
        head.spacing = 10
        head.alignment = .centerY
        glyph.widthAnchor.constraint(equalToConstant: 14).isActive = true
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var rows: [NSView] = [head]
        if hasSubtitle { rows.append(indented(subtitle, by: 24)) }
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

/// The "own git worktree" switch (last stage). A custom-drawn toggle,
/// NOT `NSButton(checkboxWithTitle:)`: the stock checkbox rendered near-invisible on
/// this hand-painted dark UI — a washed-out glyph beside low-contrast grey text — the
/// same composite failure ``PaletteRow`` was built to dodge.
/// This reuses their proven idiom: layer-backed, owns its whole rect, real
/// `mouseDown`. A 20pt box fills amber with a check when on, so the state reads at a
/// glance. Every use is an opt-IN (worktree, Windows host), never a surprise default.
final class PaletteToggle: NSView {
    var onToggle: ((Bool) -> Void)?
    private(set) var isOn: Bool
    private let box = NSView()
    private let check = makeMono(13)
    private let title = makeSans(12, weight: .semibold)
    private let subtitle = makeMono(10)

    init(title titleText: String, subtitle subtitleText: String, isOn: Bool) {
        self.isOn = isOn
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        title.stringValue = titleText
        subtitle.stringValue = subtitleText
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

/// A palette text input: inset fill + stroke, amber while focused. The hand-entry
/// affordance behind every "type it yourself" fallback (a new host, a folder the box
/// has never been used for) — an unreachable host must never block creation, so the
/// list is only ever a shortcut past this field.
final class PaletteFieldBox: NSView {
    let field: NSTextField

    init(field: NSTextField, placeholder: String) {
        self.field = field
        super.init(frame: .zero)
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.textColor = BoardTheme.textPrimary
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        themedBackground = BoardTheme.canvas
        layer?.borderWidth = 1
        setFocused(false)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }
    required init?(coder: NSCoder) { nil }

    func setFocused(_ focused: Bool) {
        themedBorder = focused ? BoardTheme.attention : BoardTheme.cardStrokeStrong
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
/// A dumb view: the shell wires the confirm closures to its card-creation
/// logic (which owns the pool firewall + binding invariants).
final class CreateCardPalette: NSView, NSTextFieldDelegate {
    enum Stage { case destination, project, harness, agentAccount, task }
    /// Where the card runs. Remote is a stage-1 choice beside "This Mac" (US-009 AC-1),
    /// never a hidden keystroke; the payload is the raw `[user@]host[:port]` the
    /// operator picked or typed, parsed into a spec by the shell.
    enum Destination: Equatable {
        case local
        case remote(String)

        var host: String? { if case let .remote(h) = self { return h }; return nil }
    }
    enum Harness: CaseIterable {
        case claude
        case codex
        case cursor
        case antigravity
        case shell

        var title: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .cursor: return "Cursor"
            case .antigravity: return "Antigravity"
            case .shell: return "Interactive shell"
            }
        }

        var subtitle: String {
            switch self {
            case .claude: return "claude · Anthropic's coding agent CLI"
            case .codex: return "codex · OpenAI coding agent CLI"
            case .cursor: return "agent · Cursor's terminal agent CLI"
            case .antigravity: return "agy · Google's Antigravity agent CLI"
            case .shell: return "bare login shell · run any CLI yourself"
            }
        }

        var cardAgent: CardAgent? {
            switch self {
            case .claude: return .claude
            case .codex: return .codex
            case .cursor: return .cursor
            case .antigravity: return .antigravity
            case .shell: return nil
            }
        }

        var supportsAccountPicker: Bool {
            guard let agent = cardAgent else { return false }
            return AgentAccountBackend.supportsMultiAccount(agent)
        }
    }

    // Shell wires these. Interactive never fails visibly; remote returns an error
    // string for the palette to show (nil = success, shell has dismissed us).
    var confirmInteractive: ((
        _ title: String, _ dir: String, _ harness: Harness, _ inWorktree: Bool,
        _ claudeProfileID: UUID?
    ) -> Void)?
    /// The remote path (US-009): destination + optional far-side dir + card name.
    var confirmRemote: ((
        _ title: String, _ destination: String, _ dir: String, _ windows: Bool
    ) -> String?)?
    var browse: (() -> String?)?
    var onCancel: (() -> Void)?

    // Test seams — the real gestures the integration tests dispatch.
    private(set) var navRows: [PaletteRow] = []
    let nameField = NSTextField()
    /// Hand entry for a host the recents have never seen, and for a folder on it.
    let hostField = NSTextField()
    let dirField = NSTextField()
    private(set) var fieldBoxes: [PaletteFieldBox] = []
    let errorLabel = makeMono(11)
    private(set) var stage: Stage = .destination
    private(set) var destination: Destination = .local

    /// Called when the operator picks "+ Add account…" on the account stage.
    var addAgentAccount: ((CardAgent) -> Void)?

    private let recents: [PaletteProject]
    private var agentAccounts: [AgentAccountProfile]
    private(set) var remoteDir = ""
    private var projectDir: String
    private var harness: Harness = .claude
    private var selectedAgentAccountID: UUID = AgentAccountProfile.defaultClaudeID
    /// Off by default: a worktree is an explicit opt-IN. When on, the task gets its
    /// own git worktree (fresh `task/<slug>` branch) so parallel cards on one repo
    /// don't share a checkout — but that's a deliberate choice, not a surprise.
    private(set) var inWorktree = false
    private var worktreeToggle: PaletteToggle?
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var worktreeToggleForTesting: PaletteToggle? { worktreeToggle }
    /// Whether the picked remote host is a Windows box (psmux, terminal-only card).
    /// Defaults from ``windowsHosts`` when the folder stage opens, so a host the
    /// operator already marked once comes pre-checked.
    private(set) var remoteWindows = false
    private var windowsToggle: PaletteToggle?
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var windowsToggleForTesting: PaletteToggle? { windowsToggle }
    /// Hosts the board remembers as Windows — the shell injects these at wiring time.
    var windowsHosts: Set<String> = []
    private var selected = 0

    private let card = NSView()
    private let body = NSStackView()
    private let header = NSStackView()
    private let footer = makeMono(9)

    init(recents: [PaletteProject], agentAccounts: [AgentAccountProfile] = [.defaultClaude]) {
        self.recents = recents
        self.agentAccounts = agentAccounts.isEmpty ? [.defaultClaude] : agentAccounts
        self.projectDir = recents.first { $0.host == nil }?.path ?? ""
        self.selectedAgentAccountID = AgentAccountProfile.defaultClaudeID
        super.init(frame: .zero)
        if let first = selectableAccounts.first?.id { selectedAgentAccountID = first }
        buildChrome()
        renderStage()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusStage()
    }

    /// Give the current stage its own keyboard focus. The first stage is built before
    /// there is a window, so without this the shell's mount would leave the hand-entry
    /// field unfocused — and an unknown host would be unreachable by typing.
    func focusStage() { window?.makeFirstResponder(focusTarget) }

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
        fieldBoxes = []
        switch stage {
        case .destination: renderDestination()
        case .project: renderProject()
        case .harness: renderHarness()
        case .agentAccount: renderAgentAccount()
        case .task: renderTask()
        }
        highlight()
        window?.makeFirstResponder(focusTarget)
    }

    /// The stage's typing target, if it has one: hand entry is always live, so a host
    /// or folder the recents don't know is one keystroke away rather than a dead end.
    private var focusTarget: NSResponder {
        switch stage {
        case .destination: return hostField
        case .project: return destination == .local ? self : dirField
        case .harness: return self
        case .agentAccount: return self
        case .task: return nameField
        }
    }

    /// `n/total` for the stage chip — a remote card skips the harness stage (the human
    /// runs whatever they like inside the far-side tmux), so the count differs.
    private func stageChip(_ name: String) -> String {
        let steps: [Stage] = destination == .local
            ? (harness.supportsAccountPicker
                ? [.destination, .project, .harness, .agentAccount, .task]
                : [.destination, .project, .harness, .task])
            : [.destination, .project, .task]
        return "\((steps.firstIndex(of: stage) ?? 0) + 1)/\(steps.count) \(name)"
    }

    private func addField(_ box: PaletteFieldBox) {
        box.field.delegate = self
        fieldBoxes.append(box)
        add(box)
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

    // MARK: stage 1 — where does this run?

    /// US-009 AC-1: the first thing the palette asks. "This Mac" is the default, and a
    /// host you have already used sits directly beside it — same row, same keystroke,
    /// no hidden alternate path.
    private func renderDestination() {
        addHeader(stageChip("where"), completed: [])
        add(sectionLabel("WHERE DOES THIS RUN?"))
        addNav(PaletteRow(glyph: "", title: "This Mac",
                          subtitle: "local login shell · your own checkout"))
        for host in knownHosts {
            addNav(PaletteRow(glyph: "@", title: host,
                              subtitle: "ssh · tmux session on the far side"))
        }
        add(sectionLabel("ANOTHER HOST"))
        addField(PaletteFieldBox(field: hostField, placeholder: "user@host  or  host:2222"))
        setFooter(["↵ next: folder", "↑↓ navigate", "esc cancel"])
    }

    /// Hosts the recents already know, most-recent first, deduped. Rendered from LOCAL
    /// state only — nothing here probes the far side, so an unreachable host is still
    /// offered and still creatable.
    private var knownHosts: [String] {
        var seen = Set<String>()
        return recents.compactMap(\.host).filter { seen.insert($0).inserted }
    }

    private var localRecents: [PaletteProject] { recents.filter { $0.host == nil } }

    private func recents(on host: String) -> [PaletteProject] {
        recents.filter { $0.host == host }
    }

    // MARK: stage 2 — folder

    private func renderProject() {
        switch destination {
        case .local: renderLocalProject()
        case let .remote(host): renderRemoteProject(host: host)
        }
    }

    /// US-009 AC-2 + the no-recents edge case: this host's OWN folders (never another
    /// box's, never a local path), plus hand entry — which is the whole stage on a box
    /// used for the first time. An empty list is a prompt, not a dead end.
    private func renderRemoteProject(host: String) {
        addHeader(stageChip("folder"), completed: [host])
        let folders = recents(on: host)
        add(sectionLabel(folders.isEmpty
            ? "NO FOLDERS USED ON THIS HOST YET — TYPE ONE"
            : "RECENT FOLDERS ON THIS HOST"))
        for folder in folders {
            addNav(PaletteRow(glyph: "", title: folder.leaf, subtitle: folder.path))
        }
        addField(PaletteFieldBox(field: dirField,
                                 placeholder: "/home/you/project   (blank = the host's default)"))
        // A Windows box speaks psmux, not tmux, and (password auth) serves no
        // headless channel — the operator marks it once here, and the board
        // remembers per host so the toggle comes pre-checked next time.
        add(sectionLabel("HOST TYPE"))
        let toggle = PaletteToggle(
            title: "Windows host (psmux)",
            subtitle: "attach via psmux · terminal-only (no hooks/relay)",
            isOn: remoteWindows)
        toggle.onToggle = { [weak self] on in self?.remoteWindows = on }
        windowsToggle = toggle
        add(toggle)
        setFooter(["↵ next: name", "↑↓ folder", "← back", "esc cancel"])
    }

    private func renderLocalProject() {
        addHeader(stageChip("project"), completed: ["This Mac"])
        add(sectionLabel("RECENT PROJECTS"))
        for p in localRecents {
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

    // MARK: stage 3 — harness (local only)

    private func renderHarness() {
        addHeader(stageChip("harness"), completed: [projLeaf])
        add(sectionLabel("HARNESS — RUNS THE SESSION"))
        for option in Harness.allCases {
            let glyph = option.cardAgent.map { BoardTheme.agentGlyph($0) } ?? ""
            addNav(PaletteRow(glyph: glyph, title: option.title, subtitle: option.subtitle))
        }
        setFooter(["↵ next: account", "↑↓ navigate", "← back", "esc cancel"])
    }

    // MARK: stage 3b — agent account (local + Claude/Codex/Cursor harness)

    private var selectableAccounts: [AgentAccountProfile] {
        guard let agent = harness.cardAgent else { return [] }
        let host = destination.host
        let stored = agentAccounts.filter { $0.agent == agent && $0.host == host }
        if stored.contains(where: { AgentAccountBackend.isDefaultConfigRoot($0.configRoot, agent: agent) }) {
            return stored
        }
        if let synthetic = AgentAccountProfile.syntheticDefault(for: agent, host: host) {
            return [synthetic] + stored
        }
        return stored
    }

    private func renderAgentAccount() {
        let agent = harness.cardAgent ?? .claude
        addHeader(stageChip("account"), completed: [projLeaf, harness.title])
        add(sectionLabel("\(AgentAccountBackend.displayName(for: agent).uppercased()) ACCOUNT"))
        for account in selectableAccounts {
            let auth = account.authStatus == .ready ? " · signed in" : " · sign in once"
            addNav(PaletteRow(
                glyph: BoardTheme.agentGlyph(agent),
                title: account.name,
                subtitle: "\(account.configRoot)\(auth)"))
        }
        let addRow = PaletteRow(
            glyph: "+", title: "Add \(AgentAccountBackend.displayName(for: agent)) account…",
            subtitle: "new config dir · separate subscription",
            titleColor: BoardTheme.textMuted)
        addRow.onClick = { [weak self] in self?.addAgentAccount?(agent) }
        navRows.append(addRow)
        add(addRow)
        setFooter(["↵ next: task", "↑↓ navigate", "← back", "esc cancel"])
    }

    private var selectedAgentAccount: AgentAccountProfile? {
        selectableAccounts.first { $0.id == selectedAgentAccountID }
    }

    private var agentAccountChip: String {
        selectedAgentAccount?.name ?? "Default"
    }

    // MARK: last stage — task

    private func renderTask() {
        switch destination {
        case .local: renderLocalTask()
        case let .remote(host): renderRemoteTask(host: host)
        }
    }

    private func renderLocalTask() {
        let completed = harness.supportsAccountPicker
            ? [projLeaf, harness.title, agentAccountChip]
            : [projLeaf, harness.title]
        addHeader(stageChip("task"), completed: completed)
        buildNameField()
        buildWorktreeToggle()
        // ponytail: ← not ⌫ — the mono glyph font lacks U+232B (it falls back to an
        // unrelated substitute); basic arrows render clean.
        setFooter(["↵ create", "← back", "esc cancel"])
    }

    /// A remote card is a named tmux session on the far side: no worktree (there is
    /// no local checkout to branch), so the name IS the stage — and
    /// that name is also the session the card re-attaches to after a restart.
    private func renderRemoteTask(host: String) {
        addHeader(stageChip("task"),
                  completed: [host, remoteDir.isEmpty ? "default folder" : remoteDir])
        add(sectionLabel("NAME THIS TASK — ALSO THE TMUX SESSION NAME"))
        buildNameField()
        setFooter(["↵ create", "← back", "esc cancel"])
    }

    private func buildNameField() {
        addField(PaletteFieldBox(field: nameField,
                                 placeholder: "Name this task — e.g. Fix the login redirect"))
    }

    func controlTextDidBeginEditing(_ obj: Notification) { setFieldFocus(obj, true) }
    func controlTextDidEndEditing(_ obj: Notification) { setFieldFocus(obj, false) }

    private func setFieldFocus(_ note: Notification, _ focused: Bool) {
        guard let field = note.object as? NSTextField else { return }
        fieldBoxes.first { $0.field === field }?.setFocused(focused)
    }


    /// The opt-in "own git worktree" switch (off by default).
    private func buildWorktreeToggle() {
        add(sectionLabel("ISOLATION"))
        let toggle = PaletteToggle(
            title: "Own git worktree",
            subtitle: "fresh task/<name> branch · isolated checkout",
            isOn: inWorktree)
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
        case .destination:
            pickDestinationRow(idx)
        case .project:
            activateProjectRow(idx)
        case .harness:
            activateHarnessRow(idx)
        case .agentAccount:
            activateAgentAccountRow(idx)
        case .task:
            confirmTask()
        }
    }

    /// Row 0 is this Mac; every later row is a host the recents already know.
    private func pickDestinationRow(_ idx: Int) {
        destination = idx == 0 ? .local : .remote(knownHosts[idx - 1])
        enterFolderStage()
    }

    private func enterFolderStage() {
        remoteDir = ""
        dirField.stringValue = ""
        remoteWindows = windowsHosts.contains(destination.host ?? "")
        stage = .project
        renderStage()
    }

    /// Return in the host field: a typed host wins, an empty field falls through to the
    /// highlighted row — so a box the recents have never seen is one keystroke away.
    private func commitDestination() {
        let typed = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.isEmpty else {
            destination = .remote(typed)
            enterFolderStage()
            return
        }
        pickDestinationRow(min(selected, knownHosts.count))
    }

    private func activateProjectRow(_ idx: Int) {
        if case let .remote(host) = destination {
            let list = recents(on: host)
            guard idx < list.count else { return }
            remoteDir = list[idx].path
            stage = .task; renderStage()
            return
        }
        if idx == navRows.count - 1 { doBrowse(); return }   // last = Browse…
        projectDir = localRecents[idx].path
        stage = .harness
        renderStage()
    }

    private func advanceFromHarness() {
        if harness.supportsAccountPicker {
            selectedAgentAccountID = selectableAccounts.first?.id ?? AgentAccountProfile.defaultClaudeID
            stage = .agentAccount
        } else {
            stage = .task
        }
        renderStage()
    }

    private func activateHarnessRow(_ idx: Int) {
        harness = Harness.allCases[idx]
        advanceFromHarness()
    }

    private func activateAgentAccountRow(_ idx: Int) {
        let accounts = selectableAccounts
        let addIndex = accounts.count
        if idx == addIndex {
            if let agent = harness.cardAgent { addAgentAccount?(agent) }
            return
        }
        guard idx < accounts.count else { return }
        selectedAgentAccountID = accounts[idx].id
        stage = .task
        renderStage()
    }

    /// Return in the far-side folder field. A blank field is legitimate — with no
    /// recents on this host there is nothing to fall back to, and tmux then opens the
    /// login directory — so an unused host still creates a card.
    private func commitRemoteFolder() {
        let typed = dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = recents(on: destination.host ?? "")
        if !typed.isEmpty {
            remoteDir = typed
        } else {
            remoteDir = selected < list.count ? list[selected].path : ""
        }
        stage = .task
        renderStage()
    }

    private func confirmTask() {
        let title = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if case let .remote(host) = destination {
            if let err = confirmRemote?(title, host, remoteDir, remoteWindows) { showError(err) }
            return
        }
        let profileID = harness.supportsAccountPicker ? selectedAgentAccountID : nil
        confirmInteractive?(title, projectDir, harness, inWorktree, profileID)
    }

    private func doBrowse() {
        guard let path = browse?(), !path.isEmpty else { return }
        projectDir = path
        stage = .harness
        renderStage()
    }

    private func showError(_ text: String) {
        errorLabel.stringValue = text
        errorLabel.isHidden = false
    }

    private func back() {
        switch stage {
        case .destination: onCancel?()
        case .project: stage = .destination; renderStage()
        case .harness: stage = .project; renderStage()
        case .agentAccount: stage = .harness; renderStage()
        case .task:
            if case .remote = destination {
                stage = .project
            } else if harness.supportsAccountPicker {
                stage = .agentAccount
            } else {
                stage = .harness
            }
            renderStage()
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

    /// Key routing while one of the palette's fields holds focus — every stage that can
    /// be typed into routes through here, so the keyboard path is the same everywhere.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): commit(from: control); return true
        case #selector(NSResponder.cancelOperation(_:)): onCancel?(); return true
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.deleteBackward(_:)):
            guard (control as? NSTextField)?.stringValue.isEmpty == true else { return false }
            back(); return true                       // ⌫ on an empty field steps back
        default: return false
        }
    }

    private func commit(from control: NSControl) {
        if control === hostField { commitDestination() }
        else if control === dirField { commitRemoteFolder() }
        else { confirmTask() }
    }

    // MARK: derived text

    private var projLeaf: String { (projectDir as NSString).lastPathComponent }

    /// Swap in the account list; the palette filters it by the picked harness and host.
    func reloadAgentAccounts(_ accounts: [AgentAccountProfile]) {
        agentAccounts = accounts
        if !selectableAccounts.contains(where: { $0.id == selectedAgentAccountID }) {
            selectedAgentAccountID = selectableAccounts.first?.id ?? AgentAccountProfile.defaultClaudeID
        }
        if stage == .agentAccount { renderStage() }
    }

    func selectAgentAccount(_ id: UUID) {
        selectedAgentAccountID = id
        if stage == .agentAccount {
            stage = .task
            renderStage()
        }
    }

    /// Capture seam: jump to the harness stage for a known project.
    func presentHarnessStage(projectDir: String) {
        self.projectDir = projectDir
        self.destination = .local
        self.stage = .harness
        renderStage()
    }
}
