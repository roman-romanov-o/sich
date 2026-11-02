import AppKit
import SichCore

/// A board card (US-003 AC#2): the task title first and full-width, then one
/// quiet footer row — the small harness mark, any chips, and on a WORKING card
/// the live interval at the right. The project is read off the group header
/// above the card, not the card itself. Done cards collapse to a compact ✓ row.
/// Single responsibility: present one ``BoardCard``, report clicks for drill-in
/// (US-002 AC#1), and act as the drag source for a manual column move. Board
/// logic stays in `SichCore`.
/// Options the card context menu offers for moving a task to another account
/// or harness without losing task context.
struct CardSwitchMenu: Equatable, Sendable {
    struct AccountOption: Equatable, Sendable {
        let id: UUID
        let name: String
        let quotaBlock: CardQuotaBlock
    }

    let accounts: [AccountOption]
    let harnesses: [CardAgent]
}

@MainActor
final class SessionCard: NSView, NSDraggingSource, ThemeReapplying {
    let card: BoardCard
    let quotaBlock: CardQuotaBlock
    let switchMenu: CardSwitchMenu
    /// Position within its project cluster — staggers the WORKING sheen so a
    /// column shimmers out of phase instead of in lockstep.
    var sheenPhase = 0 {
        didSet { restartSheen() }
    }
    /// A departed card's view left behind to close up in its old lane: inert to
    /// the mouse and invisible to keyboard focus.
    private(set) var isGhost = false
    /// Invoked on click — the board wires this to drill into the session (US-002).
    var onSelect: ((BoardCard) -> Void)?
    /// Invoked from the right-click "Rename Task…" item — the board bubbles this
    /// to the host, which prompts for the new title and mutates the card.
    var onRename: ((BoardCard) -> Void)?
    /// Invoked from the right-click "Delete Task…" item — the board bubbles this to
    /// the host, which confirms, tears down the session + worktree, and drops the card.
    var onDelete: ((BoardCard) -> Void)?
    var onSwitchAccount: ((BoardCard, UUID) -> Void)?
    var onSwitchHarness: ((BoardCard, CardAgent) -> Void)?
    var onDeferNeedsYou: ((BoardCard) -> Void)?
    var onPark: ((BoardCard) -> Void)?
    var onBlockExternally: ((BoardCard) -> Void)?

    private let stack = NSStackView()
    private let now: () -> Date
    /// When this card started needing the operator (item 7, 18.08). Production
    /// reads the board-fed ``AttentionClock``; tests inject a date directly.
    private let waitingSince: (UUID) -> Date?
    private weak var agingBar: NSView?
    private let agingTicker = DurationTicker()
    /// Where the host chip's install state comes from. Production reads the probe
    /// store; tests inject each of the four states directly.
    private let hostState: (String) -> RemoteHookInstallState
    private weak var durationLabel: NSTextField?
    private let durationTicker = DurationTicker()
    /// Distinguishes a click (drill-in) from a drag (column move): a drag sets
    /// this, so `mouseUp` does not also fire `onSelect`.
    private var didDrag = false
    /// The ✓ on a DONE row — the one glyph that celebrates on arrival.
    private weak var doneMark: NSTextField?

    init(
        card: BoardCard,
        quotaBlock: CardQuotaBlock = .none,
        switchMenu: CardSwitchMenu = CardSwitchMenu(accounts: [], harnesses: []),
        now: @escaping () -> Date = Date.init,
        hostState: @escaping (String) -> RemoteHookInstallState = {
            RemoteHookStatus.shared.state(for: $0)
        },
        waitingSince: @escaping (UUID) -> Date? = {
            AttentionClock.shared.waitingSince($0)
        }
    ) {
        self.card = card
        self.quotaBlock = quotaBlock
        self.switchMenu = switchMenu
        self.now = now
        self.hostState = hostState
        self.waitingSince = waitingSince
        super.init(frame: .zero)
        wantsLayer = true
        configureLayer()
        buildContent()
        buildAgingBar()
        buildSheen()
        toolTip = workTooltip
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Appearance

    /// One signal: a NEEDS YOU card carries the red fill, edge and glow; every
    /// other card — blocked, parked, dead link, spent pool, working, done — sits
    /// on the plain card surface. Its lane says what it is; chips say the rest.
    private func configureLayer() {
        layer?.cornerRadius = 10
        layer?.borderWidth = 0
        layer?.masksToBounds = false
        themedBorder = nil
        themedShadow = .black
        layer?.shadowRadius = 3
        layer?.shadowOpacity = 0.12
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        guard card.state == .waitingForInput else {
            themedBackground = BoardTheme.cardFill
            return
        }
        themedBackground = BoardTheme.needsYouCard
        themedBorder = BoardTheme.needs
        layer?.borderWidth = 1
        themedShadow = BoardTheme.needs
        layer?.shadowRadius = 4
        layer?.shadowOpacity = 0.25
        layer?.shadowOffset = .zero
    }

    /// Leave this view behind as the closing ghost of a card that moved lanes.
    func becomeGhost() {
        isGhost = true
        setKeyboardFocus(false)
        setLifted(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isGhost ? nil : super.hitTest(point)
    }

    // MARK: - WORKING ambience

    /// A faint sheen drifts across a working card every nine seconds, staggered per
    /// card — "the agents are busy" felt at the edge of vision, never read.
    /// Composite-only (a gradient layer translating inside a clipping layer).
    private let sheenClip = CALayer()
    private let sheen = CAGradientLayer()

    /// Whether this card carries a sheen at all. Under Reduce Motion the band is
    /// not built — a band that cannot drift is a stuck smear on the card, not
    /// a gentler version of the effect.
    private var sheenWanted: Bool { card.state.isWorking && BoardView.motionAllowed }

    private func buildSheen() {
        guard sheenWanted, let layer else { return }
        sheenClip.masksToBounds = true
        sheenClip.cornerRadius = 10
        sheen.startPoint = CGPoint(x: 0, y: 0)
        sheen.endPoint = CGPoint(x: 1, y: 1)
        sheen.locations = [0, 0.5, 1]
        sheenClip.addSublayer(sheen)
        layer.addSublayer(sheenClip)
        applySheenColors(under: effectiveAppearance)
    }

    func reapplyTheme(under appearance: NSAppearance) { applySheenColors(under: appearance) }

    private func applySheenColors(under appearance: NSAppearance) {
        guard sheenWanted else { return }
        appearance.performAsCurrentDrawingAppearance {
            let ink = BoardTheme.textPrimary.withAlphaComponent(0.045).cgColor
            sheen.colors = [NSColor.clear.cgColor, ink, NSColor.clear.cgColor]
        }
    }

    private func layoutSheen() {
        guard sheenWanted else { return }
        let widthChanged = sheenClip.frame.width != bounds.width
        sheenClip.frame = bounds
        sheen.frame = NSRect(x: 0, y: 0, width: bounds.width * 0.3, height: bounds.height)
        if widthChanged { restartSheen() }
    }

    private func restartSheen() {
        guard sheenWanted, bounds.width > 0 else { return }
        let band = bounds.width * 0.3
        let drift = CAKeyframeAnimation(keyPath: "transform.translation.x")
        drift.values = [-1.6 * band, 4 * band, 4 * band]
        drift.keyTimes = [0, 0.3, 1]
        drift.duration = 9
        drift.repeatCount = .infinity
        drift.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)]
        drift.beginTime = CACurrentMediaTime() - Double(sheenPhase) * 3
        sheen.add(drift, forKey: "sheen")
    }

    /// Keyboard-focus ring (arrow-key board navigation): a brand-coloured 2pt
    /// edge while focused; un-focusing restores the state-derived border.
    func setKeyboardFocus(_ focused: Bool) {
        if focused {
            layer?.borderWidth = 2
            themedBorder = BoardTheme.brand
        } else {
            configureLayer()
        }
    }

    // MARK: - Content

    private func buildContent() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // The bottom edge yields: while a card collapses or expands between lanes
        // its height is pinned below the content's, and the content must slide
        // under the clip instead of fighting the pin.
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            bottom,
        ])
        if card.state == .done {
            buildDoneRow()
        } else {
            buildFullCard()
        }
    }

    /// The full card face: title → footer (harness mark, chips, live interval).
    private func buildFullCard() {
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let title = titleRow()
        stack.addArrangedSubview(title)
        title.widthAnchor.constraint(
            equalTo: stack.widthAnchor, constant: -28).isActive = true
        let footer = footerRow()
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(
            equalTo: stack.widthAnchor, constant: -28).isActive = true
        if card.state.isWorking { startDurationTimer() }
    }

    /// A DONE card is a compact row: ✓ + title (total work on hover).
    private func buildDoneRow() {
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let row = NSStackView()
        row.spacing = 10
        row.alignment = .centerY
        let mark = label("✓", font: BoardTheme.mono, color: BoardTheme.stateColor(.done))
        mark.wantsLayer = true
        doneMark = mark
        row.addArrangedSubview(mark)
        let doneTitle = label(
            card.title ?? BoardTheme.shortPath(card.projectDir),
            font: BoardTheme.doneTitle, color: BoardTheme.textMuted)
        // DONE is the narrowest lane, so the title wraps to a second line before it
        // truncates — one line left only the first word or two readable.
        doneTitle.maximumNumberOfLines = 2
        doneTitle.lineBreakMode = .byTruncatingTail
        doneTitle.cell?.wraps = true
        doneTitle.cell?.truncatesLastVisibleLine = true
        doneTitle.yieldWidthToWindow(.defaultLow)   // longest text squeezes first
        row.addArrangedSubview(doneTitle)
        row.addArrangedSubview(NSView())   // flexible spacer
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    }

    /// The card headline — the human task title ("Fix login redirect"). Falls
    /// back to the project-dir leaf for an untitled (hook-observed) session.
    private func titleRow() -> NSView {
        let row = NSStackView()
        row.alignment = .leading
        // An untitled (hook-observed) card shows its project-dir leaf dimmed, so
        // a path never masquerades as a task name.
        let titleColor: NSColor = card.title == nil ? BoardTheme.textMuted : BoardTheme.textPrimary
        let title = NSTextField(labelWithAttributedString: BoardTheme.cardTitleText(
            card.title ?? BoardTheme.shortPath(card.projectDir), color: titleColor))
        // The card grows for a long title rather than cutting it off — but only
        // to an extent: three lines, then truncation.
        title.maximumNumberOfLines = 3
        title.lineBreakMode = .byTruncatingTail
        title.cell?.wraps = true
        title.cell?.truncatesLastVisibleLine = true
        title.yieldWidthToWindow(.defaultLow)   // longest text squeezes first
        row.addArrangedSubview(title)
        return row
    }

    /// One quiet footer row: the small harness mark, any chips, and — on a WORKING
    /// card — the live interval at the right.
    private func footerRow() -> NSView {
        let row = NSStackView()
        row.spacing = 6
        row.alignment = .centerY
        row.heightAnchor.constraint(equalToConstant: 14).isActive = true
        row.addArrangedSubview(HarnessBadge(agent: card.agent, pointSize: 12, alpha: 0.75))
        if card.state == .unreachable { row.addArrangedSubview(LinkChip()) }
        if quotaBlock.isBlocked { row.addArrangedSubview(QuotaChip(block: quotaBlock, now: now)) }
        if let place = Self.remotePlace(of: card) { row.addArrangedSubview(remotePlaceLabel(place)) }
        if let status = hostChipStatus() { row.addArrangedSubview(hostChip(status)) }
        row.addArrangedSubview(NSView())   // flexible spacer → the interval sits right
        if shouldShowDuration { row.addArrangedSubview(durationReadout()) }
        return row
    }

    /// WORKING gets a pulsing live-activity glyph + current interval. Every
    /// resting column with recorded work gets a clock + cumulative active time.
    private func durationReadout() -> NSView {
        let row = NSStackView()
        row.alignment = .centerY
        row.spacing = 4
        let symbolName = card.state.isWorking ? "waveform.path.ecg" : "clock"
        if let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: card.state.isWorking
                ? "Current working interval" : "Total working time"
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) {
            let icon = NSImageView(image: image)
            icon.identifier = NSUserInterfaceItemIdentifier(
                card.state.isWorking ? "duration-working-pulse" : "duration-clock")
            icon.contentTintColor = card.state.isWorking
                ? BoardTheme.stateColor(.running) : BoardTheme.textFaint
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.yieldWidthToWindow(.defaultLow)   // the live glyph yields before the window grows
            let width = icon.widthAnchor.constraint(equalToConstant: 11)
            width.priority = .defaultLow
            NSLayoutConstraint.activate([
                width,
                icon.heightAnchor.constraint(equalToConstant: 11),
            ])
            row.addArrangedSubview(icon)
            if card.state.isWorking { startWorkingPulse(on: icon) }
        }

        let duration = label("", font: BoardTheme.numericSmall, color: BoardTheme.textFaint)
        duration.identifier = NSUserInterfaceItemIdentifier("task-duration")
        duration.setAccessibilityLabel(
            card.state.isWorking ? "Current working interval" : "Total working time")
        durationLabel = duration
        row.addArrangedSubview(duration)
        updateDuration()
        return row
    }

    /// Only the live clock earns face space: a WORKING card shows its current
    /// interval from its first minute (`0m`). The cumulative total is history —
    /// on a resting card `10h 47m` read as "waiting for ten hours" — so it moved
    /// to the card's tooltip (``workTooltip``).
    private var shouldShowDuration: Bool { card.state.isWorking }

    /// "Worked 10h 47m in total", or nil before any work was recorded.
    private var workTooltip: String? {
        let total = card.totalWorkingTime(at: now())
        guard Int(total) / 60 > 0 else { return nil }
        return "Worked \(Self.formatDuration(total)) in total"
    }

    /// Reduce Motion is not "no feedback": the glyph drops the scale beat (the part
    /// that moves) and keeps a slow opacity breathe, so a working card still reads as
    /// alive at the edge of vision without anything travelling or growing.
    private func startWorkingPulse(on icon: NSImageView) {
        icon.wantsLayer = true
        guard BoardView.motionAllowed else {
            let breathe = CAKeyframeAnimation(keyPath: "opacity")
            breathe.values = [1.0, 0.55, 1.0]
            breathe.keyTimes = [0, 0.5, 1]
            breathe.duration = 2.4
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            icon.layer?.add(breathe, forKey: "working-breathe")
            return
        }

        let beat = CAKeyframeAnimation(keyPath: "transform.scale")
        beat.values = [1.0, 1.2, 0.96, 1.1, 1.0]
        beat.keyTimes = [0, 0.12, 0.24, 0.38, 1]

        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = [0.72, 1.0, 0.8, 1.0, 0.72]
        glow.keyTimes = beat.keyTimes

        let heartbeat = CAAnimationGroup()
        heartbeat.animations = [beat, glow]
        heartbeat.duration = 1.35
        heartbeat.repeatCount = .infinity
        heartbeat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        icon.layer?.add(heartbeat, forKey: "working-heartbeat")
    }

    private func startDurationTimer() {
        durationTicker.timer = Timer.scheduledTimer(
            withTimeInterval: 60, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDuration() }
        }
    }

    private func updateDuration() {
        let instant = now()
        let interval = card.state.isWorking
            ? card.currentWorkingTime(at: instant)
            : card.totalWorkingTime(at: instant)
        let text = Self.formatDuration(interval)
        durationLabel?.stringValue = text
        durationLabel?.toolTip = card.state.isWorking
            ? "Current working interval: \(text)"
            : "Total working time: \(text)"
    }

    /// Whole-minute display used by the footer. Beyond a day, minute precision
    /// stops being useful and the compact form becomes `2d 3h`.
    static func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval) / 60)
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 {
            return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
        }
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
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

    // MARK: - Host chip (US-005 AC-4, AC-7)

    /// What this card can say about where it runs. `nil` for an ordinary local
    /// card that is being observed normally — there is nothing to report. A
    /// healthy remote host is equally silent: the destination is already the
    /// card's project label, so a chip repeating it was pure noise.
    func hostChipStatus() -> HostChipStatus? {
        Self.chipStatus(for: card, hostState: hostState)
    }

    /// The chip derivation as a pure function of card + host state, so the board's
    /// render diff can ask "would this card's chip read differently now?" without
    /// building a view to find out.
    static func chipStatus(
        for card: BoardCard, hostState: (String) -> RemoteHookInstallState
    ) -> HostChipStatus? {
        if let destination = remoteDestination(of: card) {
            let state = hostState(destination)
            guard state.chipDetail != nil else { return nil }
            return .remote(destination: destination, state: state)
        }
        // A card nothing has ever reported on. Saying only "unknown" would leave
        // the operator guessing whether the hooks are broken; they are not — this
        // session simply did not start here (AC-7).
        return card.state == .unknown ? .notStartedBySich : nil
    }

    static func remoteDestination(of card: BoardCard) -> String? {
        card.remoteDestination
    }

    /// Where a remote card's work is: `host:leaf` once the far side's folder is
    /// known, the bare destination until then. The project header above the card
    /// now names the repo (shared with local checkouts), so this is what says the
    /// card is remote and which folder it sits in over there.
    static func remotePlace(of card: BoardCard) -> String? {
        guard let destination = card.remoteDestination.map(BoardTheme.shortDestination) else { return nil }
        guard let dir = card.remoteDir else { return destination }
        return "\(destination):\(BoardTheme.shortPath(dir))"
    }

    private func remotePlaceLabel(_ text: String) -> NSTextField {
        let field = label(text, font: BoardTheme.chip, color: BoardTheme.textFaint)
        field.identifier = NSUserInterfaceItemIdentifier("remote-place")
        field.toolTip = card.remoteDir.map { "\(card.projectDir):\($0)" } ?? card.projectDir
        return field
    }

    /// Built the same way ``ChipLabel`` is — the label IS the chip and paints its
    /// own fill. A stock control on this hand-painted surface was the invisible-pill
    /// defect, and it cannot be captured faithfully in a test either.
    private func hostChip(_ status: HostChipStatus) -> HostChip {
        HostChip(status: status) { destination in
            RemoteHookStatus.shared.requestInstall(for: destination)
        }
    }

    // MARK: - Aging bar (item 7, 18.08)

    /// A hairline along the card's bottom edge that fills and warms with waiting
    /// time — at 4 minutes it is nearly invisible, at 3h35m it is loud. Only a
    /// needs-attention card carries one; every other state stays clean.
    private func buildAgingBar() {
        guard card.state.needsAttention, waitingSince(card.id) != nil else { return }
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        bar.identifier = NSUserInterfaceItemIdentifier("aging-bar")
        addSubview(bar)
        agingBar = bar
        updateAgingBar()
        agingTicker.timer = Timer.scheduledTimer(
            withTimeInterval: 30, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAgingBar() }
        }
    }

    override func layout() {
        super.layout()
        updateAgingBar()
        layoutSheen()
    }

    private func updateAgingBar() {
        guard let bar = agingBar, let start = waitingSince(card.id) else { return }
        let age = max(0, now().timeIntervalSince(start))
        let fraction = Self.agingFraction(age)
        let inset: CGFloat = 6
        bar.frame = NSRect(
            x: inset, y: 2,
            width: max(0, bounds.width - 2 * inset) * fraction, height: 3)
        bar.themedBackground = Self.agingColor(age)
        bar.toolTip = "Waiting for you for \(Self.formatDuration(age))"
    }

    /// How much of the card's width the bar fills: linear from empty to full over
    /// three hours of waiting, so 4 minutes reads as a barely-there sliver.
    static func agingFraction(_ age: TimeInterval) -> CGFloat {
        min(1, max(0, age / (3 * 3600)))
    }

    /// The bar's ink deepens with age: it starts as a translucent NEEDS YOU red
    /// and ends as the full-strength deeper red at the three-hour mark.
    static func agingColor(_ age: TimeInterval) -> NSColor {
        let f = agingFraction(age)
        let warmed = BoardTheme.needs.blended(withFraction: f, of: BoardTheme.needsStroke)
        return (warmed ?? BoardTheme.needsStroke).withAlphaComponent(0.35 + 0.65 * f)
    }

    /// Test seam: the bar view, if this card carries one.
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var agingBarForTesting: NSView? { agingBar }

    // MARK: - Drill-in (click) + drag (move) + rename (right-click)

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename Task…", action: #selector(renameTapped), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        if !switchMenu.accounts.isEmpty {
            menu.addItem(.separator())
            let accountMenu = NSMenuItem(title: "Switch Account", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for option in switchMenu.accounts {
                let suffix = option.quotaBlock.isBlocked ? " (quota spent)" : ""
                let item = NSMenuItem(
                    title: "\(option.name)\(suffix)",
                    action: #selector(switchAccountTapped(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = option.id
                item.isEnabled = !option.quotaBlock.isBlocked
                submenu.addItem(item)
            }
            accountMenu.submenu = submenu
            menu.addItem(accountMenu)
        }
        if !switchMenu.harnesses.isEmpty {
            let harnessMenu = NSMenuItem(title: "Continue On…", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for agent in switchMenu.harnesses {
                let item = NSMenuItem(
                    title: agent.displayName,
                    action: #selector(switchHarnessTapped(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = agent.rawValue
                submenu.addItem(item)
            }
            harnessMenu.submenu = submenu
            menu.addItem(harnessMenu)
        }
        if card.state.needsAttention {
            menu.addItem(.separator())
            let blocked = NSMenuItem(
                title: "Blocked externally…",
                action: #selector(blockExternallyTapped), keyEquivalent: "")
            blocked.target = self
            menu.addItem(blocked)
            let deferItem = NSMenuItem(
                title: "Park until tomorrow…",
                action: #selector(deferNeedsYouTapped), keyEquivalent: "")
            deferItem.target = self
            menu.addItem(deferItem)
        }
        if card.state != .parked, card.state != .done {
            menu.addItem(.separator())
            let park = NSMenuItem(
                title: "Park for later…",
                action: #selector(parkTapped), keyEquivalent: "")
            park.target = self
            menu.addItem(park)
        }
        menu.addItem(.separator())
        let delete = NSMenuItem(title: "Delete Task…", action: #selector(deleteTapped), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        return menu
    }

    @objc private func renameTapped() { onRename?(card) }
    @objc private func deferNeedsYouTapped() { onDeferNeedsYou?(card) }
    @objc private func parkTapped() { onPark?(card) }
    @objc private func blockExternallyTapped() { onBlockExternally?(card) }
    @objc private func deleteTapped() { onDelete?(card) }
    @objc private func switchAccountTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onSwitchAccount?(card, id)
    }
    @objc private func switchHarnessTapped(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let agent = CardAgent(rawValue: raw) else { return }
        onSwitchHarness?(card, agent)
    }

    // MARK: - Arrival

    /// A card that just moved into its lane fades in over the 320ms its lane
    /// spends opening a slot for it (``BoardView`` grows the card from a closed
    /// line). It happens tens of times a day and is system-driven, so it stays
    /// small; Reduce Motion keeps the fade alone. A card arriving in DONE also pops
    /// its ✓ once — completion is the one moment on the board that earns a bounce.
    func animateArrival() {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.32
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        layer.add(fade, forKey: "arrival-fade")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if card.state == .done { popDoneMark() }
    }

    /// The ✓ springs from 0.6 to full size about its own centre — after layout, so
    /// the centre is known. Apple's two-parameter spring: settles in ~0.35s with a
    /// light 0.3 bounce.
    private func popDoneMark() {
        DispatchQueue.main.async { [weak self] in
            guard let mark = self?.doneMark, let layer = mark.layer else { return }
            let cx = mark.bounds.midX, cy = mark.bounds.midY
            var from = CATransform3DMakeTranslation(cx, cy, 0)
            from = CATransform3DScale(from, 0.6, 0.6, 1)
            from = CATransform3DTranslate(from, -cx, -cy, 0)
            let pop = CASpringAnimation(perceptualDuration: 0.35, bounce: 0.3)
            pop.keyPath = "transform"
            pop.fromValue = from
            pop.toValue = CATransform3DIdentity
            pop.duration = pop.settlingDuration
            layer.add(pop, forKey: "done-pop")
        }
    }

    // MARK: - Hover + press feedback
    //
    // Cards are clicked tens of times a day, so the motion stays small and fast:
    // hover lifts the shadow (the card reads as pressable before it is pressed),
    // press sinks the card to 0.97 so the click is acknowledged before the
    // drill-in lands. Only shadow and transform animate — never the frame.

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { setLifted(true) }

    override func mouseExited(with event: NSEvent) {
        setLifted(false)
        setPressed(false)
    }

    /// Hover lift: a deeper, softer shadow on top of the state's own (an amber
    /// NEEDS YOU glow simply glows a little more).
    private func setLifted(_ lifted: Bool) {
        guard let layer else { return }
        if lifted, liftBase == nil {
            liftBase = (layer.shadowRadius, layer.shadowOpacity)
            animateShadow(radius: layer.shadowRadius + 5, opacity: min(1, layer.shadowOpacity + 0.14))
        } else if !lifted, let base = liftBase {
            liftBase = nil
            animateShadow(radius: base.radius, opacity: base.opacity)
        }
    }

    private var liftBase: (radius: CGFloat, opacity: Float)?

    private func animateShadow(radius: CGFloat, opacity: Float) {
        guard let layer else { return }
        let ease = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        for (key, value) in [("shadowRadius", radius as Any), ("shadowOpacity", opacity as Any)] {
            let anim = CABasicAnimation(keyPath: key)
            anim.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
            anim.toValue = value
            anim.duration = 0.15
            anim.timingFunction = ease
            layer.add(anim, forKey: key)
        }
        layer.shadowRadius = radius
        layer.shadowOpacity = opacity
    }

    /// Press sink, scaled about the card's centre (a layer-backed NSView anchors
    /// its layer at the bottom-left corner). Reduce Motion skips the movement.
    private func setPressed(_ pressed: Bool) {
        guard let layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let scale: CGFloat = pressed ? 0.97 : 1
        let cx = bounds.midX, cy = bounds.midY
        var target = CATransform3DMakeTranslation(cx, cy, 0)
        target = CATransform3DScale(target, scale, scale, 1)
        target = CATransform3DTranslate(target, -cx, -cy, 0)
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = layer.presentation()?.transform ?? layer.transform
        anim.toValue = target
        // Asymmetric: the sink answers instantly, the release settles a touch slower.
        anim.duration = pressed ? 0.1 : 0.16
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        layer.add(anim, forKey: "press")
        layer.transform = target
    }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        setPressed(true)
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        setPressed(false)
        let item = NSPasteboardItem()
        item.setString(card.id.uuidString, forType: BoardCell.cardType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        setPressed(false)
        if !didDrag { onSelect?(card) }
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .move }

    /// A bitmap of the card to drag under the cursor — a visual handle only, so the
    /// known-unfaithful `cacheDisplay` is fine here (not screenshot evidence).
    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return image }
        cacheDisplay(in: bounds, to: rep)
        image.addRepresentation(rep)
        return image
    }
}

/// Owns the repeating Foundation timer outside the main-actor view. Its deinit
/// cancels the run-loop registration when a rebuilt card view is discarded.
private final class DurationTicker {
    var timer: Timer?
    deinit { timer?.invalidate() }
}

/// A layer-backed text field that pads its text into a small rounded chip — the
/// same "the label draws its own fill" render path as the back pill. A container
/// `NSView` with a *child* label does NOT paint reliably on this hand-painted
/// dark UI (the iter-4 invisible-pill defect), so the chip IS the label.
@MainActor
class ChipLabel: NSTextField {
    init(text: String) {
        super.init(frame: .zero)
        stringValue = text
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false   // the LAYER paints the fill
        lineBreakMode = .byTruncatingTail
        yieldWidthToWindow()
    }

    required init?(coder: NSCoder) { nil }

    /// Pad the intrinsic text size so the rounded fill has horizontal breathing room.
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 12
        size.height += 3
        return size
    }
}

/// Quota-spent / pool-low chip on a card face.
@MainActor
final class QuotaChip: ChipLabel {
    init(block: CardQuotaBlock, now: @escaping () -> Date = Date.init) {
        super.init(text: block.chipText)
        identifier = NSUserInterfaceItemIdentifier("quota-chip")
        font = BoardTheme.chip
        // A spent pool keeps its violet (the one chip that explains why a card
        // cannot start); a merely low pool is said in words, not colour.
        let (ink, fill): (NSColor, NSColor) = switch block {
        case .exhausted: (BoardTheme.quotaBlocked, BoardTheme.quotaBlocked)
        case .low: (BoardTheme.textMuted, BoardTheme.textFaint)
        case .none: (BoardTheme.textDim, BoardTheme.textDim)
        }
        textColor = ink
        toolTip = block.toolTip(now: now())
        wantsLayer = true
        themedBackground = fill.withAlphaComponent(0.16)
        layer?.cornerRadius = 3
    }

    required init?(coder _: NSCoder) { nil }
}

/// "The machine this work runs on has stopped answering" (US-007 AC-4), said in
/// words on the card face.
///
/// A ``ChipLabel``, so it goes through the same self-painting layer-backed render
/// path as the host chip beside it — a stock control on this hand-painted surface
/// is the invisible-pill defect, and a bitmap of one is not evidence either. It is
/// inert: unlike the host chip there is no click that would fix a dead network.
@MainActor
final class LinkChip: ChipLabel {
    /// The word itself, so a test asserts the sentence the operator reads and not a
    /// coincidence of formatting.
    static let text = "unreachable"

    init() {
        super.init(text: Self.text)
        identifier = NSUserInterfaceItemIdentifier("link-chip")
        font = BoardTheme.chip
        textColor = BoardTheme.stateColor(.unreachable)
        toolTip = "This host stopped answering — its status is no longer live"
        setAccessibilityLabel(Self.text)
        wantsLayer = true
        themedBackground = BoardTheme.stateColor(.unreachable).withAlphaComponent(0.16)
        layer?.cornerRadius = 3
    }

    required init?(coder _: NSCoder) { nil }
}

/// What a card says about the machine its work runs on (US-005 AC-4, AC-7).
///
/// The two cases are deliberately different sentences. "Hooks are not installed
/// on that host" is something the operator can fix in one click; "this session
/// did not start here" is not a fault at all. Collapsing them into a bare
/// "not observed" is what made the board read as broken when it was merely quiet.
enum HostChipStatus: Equatable {
    case remote(destination: String, state: RemoteHookInstallState)
    case notStartedBySich

    /// What the chip shows on the card face — short, so it never crowds the
    /// project label out. The full sentence (``text``) is the tooltip.
    var shortText: String {
        switch self {
        case .remote(_, let state):
            switch state {
            case .installed: return text
            case .notInstalled: return "⚠ no hooks"
            case .staleVersion: return "⚠ old hooks"
            case .unknown: return "? hooks"
            }
        case .notStartedBySich:
            return text
        }
    }

    var text: String {
        switch self {
        case .remote(let destination, let state):
            // The detail alone — the card's project label already names the
            // destination, and the old "user@host — detail" form was long enough
            // that truncation routinely ate the part the operator could act on.
            return state.chipDetail ?? destination
        case .notStartedBySich:
            return "not started by Sich"
        }
    }

    /// Clickable only where a click helps. `unknown` is inert: we could not read
    /// the host, so installing over it would be a guess.
    var isActionable: Bool {
        guard case .remote(_, let state) = self else { return false }
        return state.isActionable
    }

    var destination: String? {
        guard case .remote(let destination, _) = self else { return nil }
        return destination
    }
}

/// The host chip: a ``ChipLabel`` that, when it is actionable, is also the click
/// target. Same custom-drawn layer-backed render path as the rest of the card —
/// a stock `NSButton` here was the invisible-pill defect, and `performClick` on
/// one is not evidence that a real gesture reaches anything.
@MainActor
final class HostChip: ChipLabel {
    let status: HostChipStatus
    private let onInstall: (String) -> Void

    init(status: HostChipStatus, onInstall: @escaping (String) -> Void) {
        self.status = status
        self.onInstall = onInstall
        super.init(text: status.shortText)
        identifier = NSUserInterfaceItemIdentifier("host-chip")
        font = BoardTheme.chip
        textColor = status.isActionable ? BoardTheme.textMuted : BoardTheme.textDim
        // The face is a marker; the tooltip says what it means and, when a click
        // can fix it, which host the click installs onto.
        let install = status.isActionable
            ? status.destination.map { " — click to install Sich's hooks on \($0)" } : nil
        toolTip = status.text + (install ?? "")
        setAccessibilityLabel(status.text)
        // The project label beside it wins any width fight.
        yieldWidthToWindow(.init(480))
        // Fill only where a click does something: a healthy or unreadable host
        // stays as quiet as the repo chip beside it.
        guard status.isActionable else { return }
        wantsLayer = true
        themedBackground = BoardTheme.textFaint.withAlphaComponent(0.16)
        layer?.cornerRadius = 3
    }

    required init?(coder _: NSCoder) { nil }

    /// An inert chip stays transparent to the mouse so the click still drills into
    /// the card; an actionable one claims the hit the way ``PlanningStepButton`` does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard status.isActionable else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let destination = status.destination, status.isActionable else { return }
        onInstall(destination)
    }
}
