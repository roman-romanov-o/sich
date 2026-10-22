import AppKit
import SichCore

/// A custom-drawn, layer-backed clickable row for the saha chooser — the SAME idiom
/// as ``BackPill`` / ``PlanningStepButton``: a `wantsLayer` `NSTextField` that paints
/// its own fill and fires `onClick` from a REAL dispatched `mouseDown`, never a
/// tracking loop. A stock `NSButton` was the interaction-AC-binding-rule trap here
/// (`performClick` isn't a real gesture, and a real click enters `NSButton`'s modal
/// tracking loop) — this is the only click path proven to composite on the dark UI
/// AND be driven by a genuine event.
@MainActor
final class ChooserButton: NSTextField {
    var onClick: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        useCenteredTextCell()
        stringValue = title
        font = BoardTheme.monoBold
        textColor = BoardTheme.textPrimary
        alignment = .center
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        wantsLayer = true
        themedBackground = BoardTheme.cardFillRaised
        layer?.cornerRadius = 5
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 24
        size.height = 28
        return size
    }

    /// Own the whole row as one click target so real hit-testing resolves the point
    /// to this row — not a pane behind it (the geometry half of the binding rule).
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The second step of saha-card creation. Button clicks are the production callback
/// chain as well as the integration-test seam — each is a ``ChooserButton`` so a real
/// dispatched `mouseDown` (`window.sendEvent`) reaches it, never `performClick`.
@MainActor
final class SahaTaskChooserView: NSView {
    var onChooseExisting: ((URL) -> Void)?
    var onCreateNew: ((String) -> Void)?

    private let titleField = NSTextField()
    private let stack = NSStackView()
    private(set) var existingButtons: [ChooserButton] = []
    private var existingURLs: [URL]
    let createButton = ChooserButton(title: "Create new task")
    let errorLabel = NSTextField(labelWithString: "")

    init(folders: [TaskFolderSummary]) {
        existingURLs = folders.map(\.url)
        super.init(frame: .zero)
        wantsLayer = true
        themedBackground = BoardTheme.canvas
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),
        ])

        stack.addArrangedSubview(NSTextField(labelWithString: "Choose a saha task"))
        for (index, folder) in folders.enumerated() {
            let button = ChooserButton(title: "\(folder.title) · \(folder.progress.displayText)")
            button.onClick = { [weak self] in self?.chooseExisting(index) }
            existingButtons.append(button)
            stack.addArrangedSubview(button)
        }
        titleField.placeholderString = "New task title"
        titleField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        stack.addArrangedSubview(titleField)
        createButton.onClick = { [weak self] in self?.createTapped() }
        stack.addArrangedSubview(createButton)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel)
    }

    required init?(coder: NSCoder) { nil }

    func setTitleForTesting(_ title: String) { titleField.stringValue = title }

    func show(error: String) {
        errorLabel.stringValue = error
        errorLabel.isHidden = false
    }

    private func chooseExisting(_ index: Int) {
        guard existingURLs.indices.contains(index) else { return }
        onChooseExisting?(existingURLs[index])
    }

    private func createTapped() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            show(error: "Enter a task title.")
            return
        }
        onCreateNew?(title)
    }

    func bindFolderURLs(_ folders: [TaskFolderSummary]) {
        existingURLs = folders.map(\.url)
    }
}

private extension TaskFolderProgress {
    var displayText: String {
        switch self {
        case let .known(completed, total): return "\(completed)/\(total)"
        case .unknown: return "unknown"
        }
    }
}

/// The "+ new task" project-folder chooser (designer Approach A): recent folders as
/// **clickable rows** — a tinted initials tile, the folder leaf in bold, its git
/// branch, and the faint `◇ ~/parent` — instead of a bare dropdown of long paths.
/// A "Choose a different folder…" row opens the native ``NSOpenPanel``. Single
/// responsibility: let the operator pick where the new terminal opens, fast.
///
/// Built in the board's custom-drawn idiom (layer-backed `NSView`s of labels, the
/// same render path ``SessionCard`` uses) so it composites on the Deep Slate UI.
@MainActor
final class FolderPickerView: NSView {
    /// The currently chosen directory (absolute path). Defaults to the most-recent.
    private(set) var selectedDir: String
    /// Wired by the controller to run an `NSOpenPanel` and return the chosen path.
    var onBrowse: (() -> String?)?

    private let listStack = NSStackView()
    private var rows: [FolderRow] = []

    init(recentDirs: [String]) {
        selectedDir = recentDirs.first ?? ""
        super.init(frame: .zero)
        build(recentDirs: recentDirs)
    }

    required init?(coder: NSCoder) { nil }

    private func build(recentDirs: [String]) {
        listStack.orientation = .vertical
        listStack.alignment = .width   // rows stretch to the picker width (no per-row constraint)
        listStack.spacing = 3
        listStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: topAnchor),
            listStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            listStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for dir in recentDirs { addRow(for: dir) }
        rows.first?.setSelected(true)
        listStack.addArrangedSubview(chooseRow())
    }

    private func addRow(for dir: String) {
        let row = FolderRow(folder: RecentFolder(path: dir))
        row.onPick = { [weak self] picked in self?.select(picked) }
        rows.append(row)
        listStack.addArrangedSubview(row)
    }

    /// Single-selection: highlight the picked row, clear the rest, record its dir.
    private func select(_ row: FolderRow) {
        selectedDir = row.folder.path
        for r in rows { r.setSelected(r === row) }
    }

    /// Run the native folder chooser; if a folder comes back, insert it at the top as
    /// the new selection so the operator sees their choice before hitting Create.
    private func browse() {
        guard let path = onBrowse?() else { return }
        if let existing = rows.first(where: { $0.folder.path == path }) {
            select(existing)
            return
        }
        let row = FolderRow(folder: RecentFolder(path: path))
        row.onPick = { [weak self] picked in self?.select(picked) }
        rows.insert(row, at: 0)
        listStack.insertArrangedSubview(row, at: 0)
        select(row)
    }

    /// The dashed "Choose a different folder…" affordance below the recents.
    private func chooseRow() -> NSView {
        let row = ClickableRow()
        row.onClick = { [weak self] in self?.browse() }
        let plus = makeLabel("⊕  Choose a different folder…", font: BoardTheme.mono, color: BoardTheme.brand)
        let hint = makeLabel("⌘O", font: BoardTheme.monoSmall, color: BoardTheme.textFaint)
        let stack = NSStackView(views: [plus, NSView(), hint])
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        row.edgePin(stack, h: 12, v: 9)
        return row
    }
}

/// One recent-folder row: tinted initials tile · leaf (bold) + branch chip ·
/// faint `◇ ~/parent`, with a teal selection ring + check when chosen. Clicking
/// reports itself to the picker. Mirrors ``SessionCard``'s layer-backed render path.
@MainActor
final class FolderRow: ClickableRow {
    let folder: RecentFolder
    private let check = NSTextField(labelWithString: "✓")

    init(folder: RecentFolder) {
        self.folder = folder
        super.init(frame: .zero)
        onClick = { [weak self] in self.map { $0.onPick?($0) } }
        build()
        setSelected(false)
    }

    required init?(coder: NSCoder) { nil }

    /// Reported on click so the picker can make this the selection.
    var onPick: ((FolderRow) -> Void)?

    private func build() {
        let body = NSStackView(views: [leafRow(), parentRow()])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 2
        check.font = BoardTheme.monoBold
        check.textColor = BoardTheme.hex(0x20A896)
        let row = NSStackView(views: [tile(), body, NSView(), check])
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        edgePin(row, h: 10, v: 8)
    }

    private func leafRow() -> NSView {
        let leaf = makeLabel(folder.leaf, font: BoardTheme.title, color: BoardTheme.textPrimary)
        guard let branch = folder.branch else { return leaf }
        let chip = ChipLabel(text: branch)
        chip.font = BoardTheme.monoSmall
        chip.textColor = BoardTheme.hex(0x7A5FB8)
        chip.wantsLayer = true
        chip.themedBackground = BoardTheme.hex(0x7A5FB8).withAlphaComponent(0.16)
        chip.layer?.cornerRadius = 3
        let stack = NSStackView(views: [leaf, chip])
        stack.spacing = 7
        stack.alignment = .centerY
        return stack
    }

    private func parentRow() -> NSView {
        makeLabel("◇ \(folder.parentDisplay)", font: BoardTheme.monoSmall, color: BoardTheme.textFaint)
    }

    /// A small rounded initials tile in the folder's deterministic tint — the visual
    /// anchor that lets the eye home in on a known project at a glance.
    private func tile() -> NSView {
        let label = makeLabel(folder.initials, font: BoardTheme.monoBold, color: folder.tileTextColor)
        label.alignment = .center
        label.wantsLayer = true
        label.themedBackground = folder.tint
        label.layer?.cornerRadius = 6
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 30),
            label.heightAnchor.constraint(equalToConstant: 30),
        ])
        return label
    }

    /// Teal ring + check when selected (the SessionCard attention-edge idiom); a
    /// quiet slate fill otherwise.
    func setSelected(_ on: Bool) {
        check.isHidden = !on
        layer?.borderWidth = on ? 1.5 : 1
        themedBorder = on ? BoardTheme.hex(0x20A896) : BoardTheme.cardStroke
        themedBackground = on ? BoardTheme.cardFillRaised : BoardTheme.cardFill
    }
}

/// A layer-backed clickable container row. Factors out the wantsLayer + click idiom
/// shared by ``FolderRow`` and the "Choose…" affordance (DRY without a protocol).
@MainActor
class ClickableRow: NSView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { onClick?() }

    /// Pin a child to fill self with horizontal/vertical insets.
    func edgePin(_ child: NSView, h: CGFloat, v: CGFloat) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor, constant: h),
            child.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -h),
            child.topAnchor.constraint(equalTo: topAnchor, constant: v),
            child.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -v),
        ])
    }
}

/// The presentable facets of one recent folder, derived from its absolute path:
/// leaf, `~`-abbreviated parent, git branch, initials, and a deterministic tint.
/// ponytail: pure derivation, no model field added — recency is the MRU order, so
/// no per-dir timestamp is stored (add a `lastUsed` map if "2m ago" is wanted).
struct RecentFolder {
    let path: String
    let leaf: String
    let parentDisplay: String
    let branch: String?
    let initials: String
    let tint: NSColor
    let tileTextColor: NSColor

    @MainActor
    init(path: String) {
        self.path = path
        leaf = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        parentDisplay = (parent as NSString).abbreviatingWithTildeInPath
        branch = Self.gitBranch(of: path)
        initials = Self.initials(of: leaf)
        tint = Self.tint(for: leaf)
        tileTextColor = Self.contrastText(on: tint)
    }

    /// Cheap current branch read: parse `<gitdir>/HEAD` (`ref: refs/heads/<branch>`),
    /// resolving through ``GitWorktree`` so a worktree checkout's chip doesn't
    /// silently read as nil. nil for a non-repo or detached HEAD. ponytail: one
    /// small file read per recent (≤6), no `git` subprocess.
    private static func gitBranch(of path: String) -> String? {
        guard let head = GitWorktree.gitDir(of: path).map({ ($0 as NSString).appendingPathComponent("HEAD") }),
            let raw = try? String(contentsOfFile: head, encoding: .utf8)
        else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
    }

    /// First letters of the first two words (`agentic-coding` → `ac`), else the
    /// first two characters (`saha` → `sa`). Lowercased, matching the mock.
    private static func initials(of leaf: String) -> String {
        let words = leaf.split { !$0.isLetter && !$0.isNumber }
        let picked = words.count >= 2
            ? words.prefix(2).compactMap { $0.first }
            : Array(leaf.lowercased().prefix(2))
        return String(picked).lowercased()
    }

    /// Deterministic tile colour from a stable hash of the leaf (String.hashValue is
    /// per-run randomised, so sum the scalars instead).
    @MainActor
    private static func tint(for leaf: String) -> NSColor {
        let palette: [UInt32] = [0x2DD4BF, 0xA06BFF, 0xF5A623, 0x4B8DF8, 0x3FB950, 0xEC6A9C]
        let sum = leaf.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return BoardTheme.hex(palette[sum % palette.count])
    }

    /// Dark text on a light tint, white on a dark one — keep the initials legible
    /// (contrast is not a corner to cut). Rec. 709 relative luminance.
    @MainActor
    private static func contrastText(on color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let luma = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luma > 0.55 ? BoardTheme.canvasSunken : BoardTheme.textPrimary
    }
}

/// Module-private label helper (the same non-bezeled, transparent-background label
/// every board view builds). Free function so both row types share it.
@MainActor
func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = font
    field.textColor = color
    field.isBezeled = false
    field.drawsBackground = false
    field.isEditable = false
    return field
}
