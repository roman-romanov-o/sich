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
    /// A click on the trailing meta text, when the row offers a second action there
    /// (the folder list's "⇥ open" steps into the folder instead of using it).
    var onMeta: (() -> Void)?
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
        self.title.lineBreakMode = .byTruncatingTail
        self.subtitle.lineBreakMode = .byTruncatingMiddle
        self.subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
    /// Retarget a row the list is reusing — the same views, new words. Keeps a
    /// keystroke from building sixty rows of labels and constraints from scratch.
    func set(title: String, subtitle: String, meta: String) {
        self.title.stringValue = title
        self.subtitle.stringValue = subtitle
        self.meta.stringValue = meta
    }

    override func mouseDown(with event: NSEvent) {
        if let onMeta, let head = meta.superview,
           head.convert(meta.frame, to: self).insetBy(dx: -12, dy: -12)
               .contains(convert(event.locationInWindow, from: nil)) {
            onMeta()
        } else {
            onClick?()
        }
    }
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
        // One line that scrolls: a long path slides under the edge, never wraps.
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
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
    /// Where the folder field's completions come from (US-009 + inline completion):
    /// this Mac's disk or one ssh listing per far-side folder. The shell injects the
    /// production source; the default never dials out under `swift test`.
    var folderSource: any FolderSuggestionSource = PaletteFolderSource(remoteRunner: SSHCommandRunner())
    /// What a bare name in the local folder field is relative to. A test points it at
    /// a scratch tree; the app never changes it.
    var home = NSHomeDirectory()
    var onCancel: (() -> Void)?

    // Test seams — the real gestures the integration tests dispatch.
    private(set) var navRows: [PaletteRow] = []
    let nameField = NSTextField()
    /// Hand entry for a host the recents have never seen, and for a folder on it.
    let hostField = NSTextField()
    /// The one folder field, local and remote alike. Typing lists the folders that
    /// complete the path right under it — ⇥ fills one in, ↑↓ picks, ↵ uses it — so
    /// a folder the recents never saw is reachable without leaving the keyboard.
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
    /// The highlighted nav row; `-1` while the folder field holds text and nothing has
    /// been arrowed to yet — ↵ then means "the path as typed", like a shell prompt.
    private var selected = 0

    /// One far-side (or local) listing per folder, kept for the palette's lifetime so
    /// typing inside a folder filters instantly and only a new folder costs a round
    /// trip. Keyed by host + parent; a host's listing never answers for another's.
    private enum FolderListing { case pending, unreadable, folders([String]) }
    private var folderListings: [String: FolderListing] = [:]
    /// True only for the duration of a source call, so an answer that lands
    /// synchronously (this Mac) is stored for the render already in progress rather
    /// than painting the list a second time from inside it.
    private var awaitingSynchronousListing = false
    /// The folder-stage list under the field — rebuilt on every keystroke while the
    /// field itself (and its focus) stays put. It lives in a scroll pane so a folder
    /// with a hundred children is browsable, not truncated: every subfolder is a row,
    /// ↑↓ keep the highlight in view, ⇥/→ step in.
    private let folderList = NSStackView()
    private let folderScroll = NSScrollView()
    /// The list's fixed parts: one heading, up to ``maxFolderRows`` reusable rows,
    /// one "more" line. A render retargets and shows/hides; it never rebuilds.
    let folderHeading = makeMono(9)
    private var folderRows: [PaletteRow] = []
    private let folderMore = makeMono(10)
    /// About eight rows; past that the pane scrolls.
    static let folderListMaxHeight: CGFloat = 420
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var folderScrollForTesting: NSScrollView { folderScroll }
    /// The folders currently offered under the field, in row order, each as the text
    /// the field gets when it is taken — a child of the typed folder, or, for a bare
    /// name, a match from one of the folders your recent projects live in.
    private(set) var folderSuggestions: [String] = []
    /// Rows are real views, rebuilt per keystroke; past this many the list says how
    /// many more there are and typing narrows it. Nobody arrows through 2,000 rows,
    /// and 2,000 AppKit views per keystroke would be felt.
    static let maxFolderRows = 60

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
        buildFolderPane()
        renderStage()
    }

    required init?(coder: NSCoder) { nil }

    /// The scroll pane the folder list lives in, built once: the stage only mounts
    /// it, so the document and its width binding survive every re-render.
    private func buildFolderPane() {
        folderList.orientation = .vertical
        folderList.alignment = .leading
        folderList.spacing = 2
        let document = FolderListDocument()
        pin(folderList, to: document)
        folderHeading.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        folderHeading.textColor = BoardTheme.textFaint
        folderHeading.lineBreakMode = .byTruncatingMiddle
        folderHeading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addFolderLabel(inset(folderHeading, leading: 10, top: 6, bottom: 3))
        folderMore.textColor = BoardTheme.textDim
        addFolderLabel(inset(folderMore, leading: 34, top: 6, bottom: 6))
        folderMore.superview?.isHidden = true
        folderScroll.documentView = document
        folderScroll.drawsBackground = false
        folderScroll.hasVerticalScroller = true
        folderScroll.autohidesScrollers = true
        folderScroll.verticalScrollElasticity = .allowed
        folderScroll.horizontalScrollElasticity = .none
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: folderScroll.contentView.widthAnchor).isActive = true
        // The pane is as tall as its list up to the cap, solved by the one layout pass
        // the keystroke already pays for — no `fittingSize` (a second, private solve
        // of every row, which cost more than everything else in the keystroke).
        let hug = folderScroll.heightAnchor.constraint(equalTo: document.heightAnchor)
        // Below the rows' own content priority (750): the list is as tall as its rows,
        // and the pane follows it, never the other way round.
        hug.priority = NSLayoutConstraint.Priority(499)
        hug.isActive = true
        folderScroll.heightAnchor.constraint(lessThanOrEqualToConstant: Self.folderListMaxHeight).isActive = true
    }

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
        l.lineBreakMode = .byTruncatingMiddle
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let wrap = NSView()
        l.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10),
            l.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 6),
            l.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -3),
            l.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -10),
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
        case .project: return dirField
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

    /// US-009 AC-2 + inline completion: the field is the stage. Empty, it shows this
    /// destination's own recents (never another box's, never a local path on a remote
    /// host); with text in it, the folders that complete the path. An unused host, or a
    /// folder nothing can list, is still one ↵ away — the list is a shortcut past
    /// typing, never a gate on it.
    private func renderProject() {
        let host = destination.host
        addHeader(stageChip(host == nil ? "project" : "folder"), completed: [host ?? "This Mac"])
        addField(PaletteFieldBox(
            field: dirField,
            placeholder: host == nil
                ? "Type a project name or path — kanban, ~/Projects/…  ·  tab completes"
                : "Path on \(host!) — ~/project or /srv/app  ·  blank = login folder"))
        add(folderScroll)
        if host != nil {
            // A Windows box speaks psmux, not tmux, and (password auth) serves no
            // headless channel — the operator marks it once here, and the board
            // remembers per host so the toggle comes pre-checked next time.
            add(sectionLabel("HOST TYPE"))
            let toggle = PaletteToggle(
                title: "Windows host (psmux)",
                subtitle: "attach via psmux · terminal-only (no hooks/relay)",
                isOn: remoteWindows)
            toggle.onToggle = { [weak self] on in
                self?.remoteWindows = on
                self?.renderFolderList()
            }
            windowsToggle = toggle
            add(toggle)
        }
        renderFolderList()
        setFooter(["↑↓ pick", "tab/→ open", host == nil ? "↵ next: harness" : "↵ next: name",
                   "← back", "esc cancel"])
    }

    /// This destination's recents, in row order, for the empty-field list.
    private var folderRecents: [PaletteProject] {
        destination.host.map(recents(on:)) ?? localRecents
    }

    private var typedFolder: String {
        dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A local path reads with `~`; a far-side one is shown exactly as typed, since
    /// only that host knows what its home is.
    private func displayFolder(_ path: String) -> String {
        destination.host == nil ? FolderCompletion.abbreviated(localAbsolute(path), home: home) : path
    }

    private func localAbsolute(_ typed: String) -> String {
        FolderCompletion.localDirectory(for: typed, home: home)
    }

    /// The folders your recent local projects live in (as typed-form parents, `~/…/`),
    /// the home folder excluded since the field already lists it. A bare name is looked
    /// up in these too, so a project is found by name without remembering where it
    /// was cloned.
    private var projectRoots: [String] {
        var seen: Set<String> = []
        return localRecents.compactMap { project in
            let dir = (project.path as NSString).deletingLastPathComponent
            guard dir != home, !dir.isEmpty, seen.insert(dir).inserted else { return nil }
            return displayFolder(dir) + "/"
        }
    }

    private func listingKey(_ parent: String) -> String {
        "\(destination.host ?? "")\u{0}\(parent)"
    }

    /// Rebuild only the list under the field. Rows are plain subviews, not the
    /// stage's `add`, so the field above keeps its editor and its focus.
    private func renderFolderList() {
        guard stage == .project else { return }
        navRows = []
        folderSuggestions = []
        folderMore.superview?.isHidden = true
        let typed = typedFolder
        if typed.isEmpty {
            renderFolderRecents()
        } else {
            renderFolderMatches(for: typed)
        }
        for row in folderRows.dropFirst(navRows.count) { row.isHidden = true }
        highlight()
        folderScroll.contentView.scroll(to: .zero)
        folderScroll.reflectScrolledClipView(folderScroll.contentView)
    }

    private func renderFolderRecents() {
        let list = folderRecents
        let local = destination.host == nil
        folderHeading.stringValue = list.isEmpty
            ? (local ? "NO RECENT PROJECTS — TYPE A PATH" : "NO FOLDERS USED ON THIS HOST YET — TYPE ONE")
            : (local ? "RECENT PROJECTS" : "RECENT FOLDERS ON THIS HOST")
        for p in list {
            // Fixed two-part template every local row, incl. the zero case, so the scanned
            // list has even info density (a bare path next to a "· N active" one snags the eye).
            let sub: String
            if local {
                let tail = p.activeCards == 0
                    ? "no active cards"
                    : "\(p.activeCards) active card\(p.activeCards == 1 ? "" : "s")"
                sub = "\(p.display) · \(tail)"
            } else {
                sub = p.path
            }
            showFolderRow(title: p.leaf, subtitle: sub, meta: "", stepIn: nil)
        }
        if selected < 0 || selected >= navRows.count { selected = 0 }
    }

    private func renderFolderMatches(for typed: String) {
        selected = -1
        let (parent, leaf) = FolderCompletion.split(typed)
        let shown = parent.isEmpty ? "~/" : displayFolder(parent)
        if remoteWindows {
            folderHeading.stringValue = "WINDOWS HOST — ↵ USES THE PATH AS TYPED"
            return
        }
        let primary = listing(of: parent)
        if case .pending = primary {
            folderHeading.stringValue = "LISTING \(shown) …"
            return
        }
        // Best matches first across every folder searched: a prefix on the home folder
        // and a prefix in a project root both beat a loose match in either.
        var tiers: [[(text: String, name: String)]] = [[], [], []]
        func offer(_ children: [String], under base: String) {
            for name in FolderCompletion.matches(children: children, leaf: leaf) {
                tiers[FolderCompletion.rank(name, against: leaf) ?? 2].append((base + name, name))
            }
        }
        if case let .folders(children) = primary { offer(children, under: parent) }
        var searchedRoots = false
        if parent.isEmpty, destination.host == nil {
            for root in projectRoots {
                guard case let .folders(children) = listing(of: root) else { continue }
                searchedRoots = true
                offer(children, under: root)
            }
        }
        let matches = tiers.flatMap { $0 }
        guard !matches.isEmpty else {
            if case .unreadable = primary {
                folderHeading.stringValue = destination.host == nil
                    ? "NO FOLDER \(shown)"
                    : "CAN'T LIST \(shown) ON \(destination.host!) — ↵ USES THE PATH AS TYPED"
            } else {
                folderHeading.stringValue = "NO FOLDERS IN \(shown) MATCH"
            }
            return
        }
        folderHeading.stringValue = "FOLDERS IN \(shown)"
            + (searchedRoots ? " + YOUR PROJECT FOLDERS" : "")
            + " · \(matches.count)" + (leaf.isEmpty ? "" : " MATCHING")
        let offered = matches.prefix(Self.maxFolderRows)
        folderSuggestions = offered.map(\.text)
        for (i, match) in offered.enumerated() {
            showFolderRow(title: match.name, subtitle: displayFolder(match.text), meta: "→ open",
                          stepIn: { [weak self] in self?.stepInto(i) })
        }
        let hidden = matches.count - offered.count
        if hidden > 0 {
            folderMore.stringValue = "+\(hidden) more — type to narrow"
            folderMore.superview?.isHidden = false
        }
    }

    private func inset(_ label: NSTextField, leading: CGFloat, top: CGFloat, bottom: CGFloat) -> NSView {
        let wrap = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: leading),
            label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: top),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -bottom),
            label.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -10),
        ])
        return wrap
    }

    /// A label spans the list's width so a long folder truncates inside the card.
    private func addFolderLabel(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        folderList.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: folderList.widthAnchor).isActive = true
    }

    /// The next pooled row, built on first use and retargeted after; it sits in the
    /// stack just above the "more" line, in the order the list reads.
    private func showFolderRow(title: String, subtitle: String, meta: String,
                               stepIn: (() -> Void)?) {
        let idx = navRows.count
        let row: PaletteRow
        if idx < folderRows.count {
            row = folderRows[idx]
            row.set(title: title, subtitle: subtitle, meta: meta)
        } else {
            row = PaletteRow(glyph: "/", title: title, subtitle: subtitle, meta: meta)
            row.translatesAutoresizingMaskIntoConstraints = false
            folderList.insertArrangedSubview(row, at: folderList.arrangedSubviews.count - 1)
            row.widthAnchor.constraint(equalTo: folderList.widthAnchor).isActive = true
            folderRows.append(row)
        }
        row.isHidden = false
        row.onClick = { [weak self] in self?.activate(idx) }
        row.onMeta = stepIn
        navRows.append(row)
    }

    /// The cached listing for `parent`, requesting it on first sight. A local answer
    /// lands synchronously inside the request (and re-renders from its callback), so
    /// the caller only ever paints `.pending` for a listing still crossing the wire.
    private func listing(of parent: String) -> FolderListing {
        let key = listingKey(parent)
        if let known = folderListings[key] { return known }
        folderListings[key] = .pending
        let host = destination.host
        awaitingSynchronousListing = true
        let listed = host == nil ? localAbsolute(parent) : parent
        folderSource.subdirectories(of: listed, on: host) { [weak self] tree in
            guard let self else { return }
            self.folderListings[key] = tree.map { .folders(FolderCompletion.ordered($0.children)) } ?? .unreadable
            // A source that looked a level further has already answered the next
            // step-in; a listing we hold is never overwritten by a stale prefetch.
            for (child, names) in tree?.grandchildren ?? [:] {
                let childKey = self.listingKey(parent + child + "/")
                if self.folderListings[childKey] == nil {
                    self.folderListings[childKey] = .folders(FolderCompletion.ordered(names))
                }
            }
            // Only a listing that crossed the wire repaints — and only when the field
            // is still looking at that folder on that host.
            if !self.awaitingSynchronousListing, self.stage == .project,
               self.destination.host == host,
               FolderCompletion.split(self.typedFolder).parent == parent {
                self.renderFolderList()
            }
        }
        awaitingSynchronousListing = false
        return folderListings[key] ?? .pending
    }

    /// ⇥ in the folder field, shell-style: fill the highlighted (or only) match and
    /// step into it; otherwise extend to what every match shares, when that continues
    /// what was typed; and when it gains nothing (or the matches came from elsewhere,
    /// as a bare name's do), highlight the first match so the next ⇥ or ↵ takes it.
    private func completeFolder() {
        let typed = typedFolder
        guard !typed.isEmpty, !folderSuggestions.isEmpty else { return }
        if selected >= 0 && selected < folderSuggestions.count {
            stepInto(selected)
        } else if folderSuggestions.count == 1 {
            stepInto(0)
        } else {
            let shared = FolderCompletion.commonPrefix(folderSuggestions)
            if shared.count > typed.count, shared.hasPrefix(typed) {
                setFolderText(shared)
            } else {
                selected = 0
                highlight()
            }
        }
    }

    /// Put suggestion `idx` in the field with a trailing `/`, listing its children —
    /// one level down the tree, no name needed. Browsing is this, repeated.
    private func stepInto(_ idx: Int) {
        guard !typedFolder.isEmpty, idx >= 0, idx < folderSuggestions.count else { return }
        setFolderText(folderSuggestions[idx] + "/")
    }

    private func setFolderText(_ text: String) {
        dirField.stringValue = text
        dirField.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        renderFolderList()
    }

    /// ↵ in the folder field. A highlighted suggestion wins; else the path as typed;
    /// else the highlighted recent. A blank remote field is legitimate — tmux then
    /// opens the login directory, so an unused host still creates a card. Locally a
    /// folder must exist: the shell cannot start in one that does not.
    private func commitFolder() {
        let typed = typedFolder
        var path: String
        if !typed.isEmpty, selected >= 0, selected < folderSuggestions.count {
            path = folderSuggestions[selected]
        } else if !typed.isEmpty {
            path = typed
        } else if selected >= 0, selected < folderRecents.count {
            path = folderRecents[selected].path
        } else {
            path = ""
        }
        if case .remote = destination {
            remoteDir = path
            stage = .task
            renderStage()
            return
        }
        guard !path.isEmpty else { showError("Type a folder, or pick a recent one."); return }
        path = (localAbsolute(path) as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            showError("No folder at \(displayFolder(path))")
            return
        }
        projectDir = path
        stage = .harness
        renderStage()
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

    /// Every keystroke in the folder field re-lists — the response is the feedback, so
    /// there is no debounce: a local listing is instant and a remote one is cached per
    /// folder, so only stepping into a new far-side folder costs a round trip.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === dirField else { return }
        errorLabel.isHidden = true
        renderFolderList()
    }

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
        if selected < 0 {
            // Nothing arrowed to yet: ↓ takes the first row, ↑ the last.
            selected = delta > 0 ? 0 : navRows.count - 1
        } else {
            selected = (selected + delta + navRows.count) % navRows.count
        }
        highlight()
        if stage == .project {
            folderScroll.layoutSubtreeIfNeeded()
            navRows[selected].scrollToVisible(navRows[selected].bounds)
        }
    }

    /// Enter / click on nav row `idx`.
    private func activate(_ idx: Int) {
        guard idx >= 0 else { return }
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

    /// A folder row — recent or suggested — taken by ↵ or a click: commit it.
    private func activateProjectRow(_ idx: Int) {
        guard idx < navRows.count else { return }
        commitFolder()
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

    private func confirmTask() {
        let title = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if case let .remote(host) = destination {
            if let err = confirmRemote?(title, host, remoteDir, remoteWindows) { showError(err) }
            return
        }
        let profileID = harness.supportsAccountPicker ? selectedAgentAccountID : nil
        confirmInteractive?(title, projectDir, harness, inWorktree, profileID)
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
        case #selector(NSResponder.insertTab(_:)):
            guard control === dirField else { return false }
            completeFolder(); return true
        case #selector(NSResponder.moveRight(_:)):
            guard control === dirField, selected >= 0, selected < folderSuggestions.count else { return false }
            stepInto(selected); return true
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
        else if control === dirField { commitFolder() }
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

/// The folder pane's document: flipped so the list grows downward from the top the
/// way a scrolling list reads, and `scrollToVisible` means what it says.
private final class FolderListDocument: NSView {
    override var isFlipped: Bool { true }
}
