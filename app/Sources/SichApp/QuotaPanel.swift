import AppKit
import SichCore

/// Where the quota panel sits in the board window.
enum QuotaDock: Equatable {
    /// A fixed-width column on the board's trailing edge — landscape windows.
    case trailing
    /// A strip under the board — portrait windows, where height is the spare
    /// dimension and every point of width belongs to the columns. `columns` is
    /// how many quota cards fit side by side: the provider blocks split across
    /// them so the strip stays short. With one column it is a single card, as on
    /// the trailing edge.
    case bottom(columns: Int)
}

/// Compact quota/usage panel: one block per provider (and per Claude account) —
/// "mark · name · account" with the live board load on the right, then that
/// provider's pools side by side, each a captioned bar with its countdown. The
/// underlying ``QuotaGauge`` invariant stays intact: each real pool is rendered
/// by one ``QuotaGaugeRow`` and exposed through `rows`; the panel only decides
/// where those rows sit on screen.
@MainActor
public final class QuotaPanel: NSView {
    public private(set) var rows: [QuotaGaugeRow] = []
    /// Last render's per-harness in-progress counts (from the board's cards).
    public private(set) var tallies: [CardAgent: AgentTaskTally] = [:]
    /// Set by the shell, which re-renders afterwards: the dock decides how many
    /// usage cards the next ``render(gauges:cards:claudeProfiles:claudeProfileByCard:)`` lays out.
    var dock: QuotaDock = .trailing {
        didSet { if dock != oldValue { applyDock() } }
    }

    private let scroll = NSScrollView()
    private let content = NSStackView()
    /// The operator's pomodoro under the gauges (trailing dock: pinned to the bottom
    /// of the lane; bottom dock: a compact column on the strip's trailing edge). The
    /// dock view is rebuilt when the panel re-docks, so the panel remembers the last
    /// render and the shell's callbacks and re-applies them to the new instance.
    private(set) var pomodoroDock: PomodoroDock
    private var pomodoroState = PomodoroState()
    private var pomodoroContext = PomodoroDock.Context()
    var onPomodoroToggle: (() -> Void)? { didSet { wirePomodoro() } }
    var onPomodoroRestNow: (() -> Void)? { didSet { wirePomodoro() } }
    var onPomodoroHint: ((PomodoroHint) -> Void)? { didSet { wirePomodoro() } }
    private var pomodoroConstraints: [NSLayoutConstraint] = []
    /// Separates the bottom strip from the columns above it.
    private let topHairline = NSView()
    /// Trailing dock: the panel is the board's last lane, edged like the others.
    private let leadingHairline = NSView()
    /// Bottom dock only: the strip is as tall as its cards (the shell caps it; past
    /// the cap the cards scroll). On the trailing edge the shell owns the height.
    private lazy var hugsContentHeight: NSLayoutConstraint = {
        let hug = heightAnchor.constraint(equalTo: content.heightAnchor)
        hug.priority = .defaultHigh
        return hug
    }()
    /// Re-ticks each row's "resets in …" line every minute so the countdown stays
    /// live between quota polls (which are minutes apart) without a full re-render.
    private var resetTicker: Timer?

    public override init(frame frameRect: NSRect) {
        pomodoroDock = PomodoroDock(compact: false)
        super.init(frame: frameRect)
        wantsLayer = true
        themedBackground = BoardTheme.canvas
        buildScaffold()
        mountPomodoro()
    }

    public required init?(coder: NSCoder) { nil }

    /// Tick only while on-screen: start the per-minute reset refresh when the panel
    /// gains a window, tear it down when it leaves (also sidesteps a nonisolated
    /// `deinit` touching the non-Sendable `Timer`).
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            resetTicker?.invalidate()
            resetTicker = nil
        } else if resetTicker == nil {
            startResetTicker()
        }
    }

    private func startResetTicker() {
        let ticker = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rows.forEach { $0.refreshReset() } }
        }
        RunLoop.main.add(ticker, forMode: .common)
        resetTicker = ticker
    }

    private func buildScaffold() {
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = QuotaLayout.sectionGap
        content.edgeInsets = NSEdgeInsets(
            // The lanes' header-row offset, so QUOTA shares the column titles' baseline.
            top: QuotaLayout.headerTop,
            left: QuotaLayout.outerInset,
            bottom: QuotaLayout.outerInset,
            right: QuotaLayout.outerInset
        )
        content.translatesAutoresizingMaskIntoConstraints = false

        let clip = FlippedView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            // Cards are fixed-width, so a wide bottom strip leaves slack on the right.
            content.trailingAnchor.constraint(lessThanOrEqualTo: clip.trailingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: clip.bottomAnchor),
        ])

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = clip
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            clip.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        leadingHairline.themedBackground = BoardTheme.hairline
        leadingHairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leadingHairline)
        NSLayoutConstraint.activate([
            leadingHairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            leadingHairline.topAnchor.constraint(equalTo: topAnchor),
            leadingHairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            leadingHairline.widthAnchor.constraint(equalToConstant: 1),
        ])

        topHairline.themedBackground = BoardTheme.hairline
        topHairline.isHidden = true
        topHairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topHairline)
        NSLayoutConstraint.activate([
            topHairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            topHairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            topHairline.topAnchor.constraint(equalTo: topAnchor),
            topHairline.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func applyDock() {
        let sideBySide = usageCardCount > 1
        content.orientation = sideBySide ? .horizontal : .vertical
        content.alignment = sideBySide ? .top : .leading
        topHairline.isHidden = dock == .trailing
        leadingHairline.isHidden = dock != .trailing
        hugsContentHeight.isActive = dock != .trailing
        pomodoroDock.removeFromSuperview()
        pomodoroDock = PomodoroDock(compact: dock != .trailing)
        mountPomodoro()
    }

    /// Pin the pomodoro dock for the current ``dock``: under the scrolling cards on
    /// the trailing edge; as the strip's last column (one card wide) at the bottom.
    private func mountPomodoro() {
        addSubview(pomodoroDock)
        NSLayoutConstraint.deactivate(pomodoroConstraints)
        let dockView = pomodoroDock
        if dock == .trailing {
            pomodoroConstraints = [
                scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: dockView.topAnchor),
                dockView.leadingAnchor.constraint(equalTo: leadingAnchor),
                dockView.trailingAnchor.constraint(equalTo: trailingAnchor),
                dockView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        } else {
            let tall = heightAnchor.constraint(greaterThanOrEqualTo: dockView.heightAnchor)
            tall.priority = .defaultHigh
            pomodoroConstraints = [
                scroll.trailingAnchor.constraint(equalTo: dockView.leadingAnchor),
                scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
                dockView.trailingAnchor.constraint(equalTo: trailingAnchor),
                dockView.topAnchor.constraint(equalTo: topAnchor),
                dockView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
                dockView.widthAnchor.constraint(equalToConstant: QuotaLayout.panelWidth),
                tall,
            ]
        }
        NSLayoutConstraint.activate(pomodoroConstraints)
        wirePomodoro()
        pomodoroDock.render(state: pomodoroState, context: pomodoroContext)
    }

    private func wirePomodoro() {
        pomodoroDock.onToggle = onPomodoroToggle
        pomodoroDock.onRestNow = onPomodoroRestNow
        pomodoroDock.onHint = onPomodoroHint
    }

    /// Repaint the pomodoro dock (the shell calls this once a second while a phase
    /// runs — it touches only the dock, never the gauge cards).
    func renderPomodoro(state: PomodoroState, cardTitle: String?, hint: PomodoroHint?) {
        pomodoroState = state
        pomodoroContext = PomodoroDock.Context(cardTitle: cardTitle, hint: hint, compact: dock != .trailing)
        pomodoroDock.render(state: state, context: pomodoroContext)
    }

    /// How many cards the provider blocks are split across (see ``QuotaDock``). On
    /// the bottom strip the pomodoro dock takes the last column.
    private var usageCardCount: Int {
        switch dock {
        case .trailing: return 1
        case .bottom(let columns): return max(1, columns - 1)
        }
    }

    /// `cards` feeds the per-harness load readout (how many tasks each harness has
    /// working / waiting on you) beside its name; callers without a board (the
    /// standalone quota window) omit it and get the plain usage panel.
    /// `claudeProfileByCard` maps each card id → profile id for per-account load lines.
    func render(
        gauges: [QuotaGauge],
        cards: [BoardCard] = [],
        claudeProfiles: [ClaudeProfile] = [.defaultProfile],
        claudeProfileByCard: [UUID: UUID] = [:]
    ) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []
        tallies = AgentTaskTally.tally(cards)

        if dock == .trailing {
            let title = laneTitle()
            content.addArrangedSubview(title)
            content.setCustomSpacing(10, after: title)
        }
        let blocks = providerBlocks(
            from: gauges, claudeProfiles: claudeProfiles,
            claudeProfileByCard: claudeProfileByCard, cards: cards)
        let perCard = max(1, (blocks.count + usageCardCount - 1) / usageCardCount)
        for start in stride(from: 0, to: blocks.count, by: perCard) {
            let chunk = blocks[start..<min(start + perCard, blocks.count)]
            addCard(usageCard(Array(chunk)))
        }
        preserveHiddenRows(for: gauges)
    }

    /// Side by side, the stack view sizes itself to the shorter cards and lets the
    /// tallest one run through its bottom inset — hold every card inside it.
    private func addCard(_ card: NSView) {
        content.addArrangedSubview(card)
        card.bottomAnchor.constraint(
            lessThanOrEqualTo: content.bottomAnchor, constant: -QuotaLayout.outerInset
        ).isActive = true
    }

    /// The lane signage: the same 28pt caps header row every board column has, so on
    /// the trailing edge the panel reads as the board's last lane and its title sits
    /// on the column titles' baseline.
    private func laneTitle() -> NSView {
        let title = label("QUOTA", font: BoardTheme.columnTitle, color: BoardTheme.textMuted)
        title.attributedStringValue = BoardTheme.caps("QUOTA", color: BoardTheme.textMuted)
        let row = NSStackView(views: [NSView(), title, NSView()])
        row.distribution = .equalCentering
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: QuotaLayout.cardWidth),
            row.heightAnchor.constraint(equalToConstant: 28),
        ])
        return row
    }

    /// One usage card: its share of the provider blocks, hairlines between them.
    private func usageCard(_ blocks: [ProviderBlock]) -> NSView {
        let card = NSStackView()
        card.identifier = NSUserInterfaceItemIdentifier("quota-card")
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = QuotaLayout.blockGap
        // No box: the board's lanes are borderless, and a bordered card here read as a
        // different product docked beside the board. Alignment and the hairline
        // dividers do the grouping.
        card.widthAnchor.constraint(equalToConstant: QuotaLayout.cardWidth).isActive = true
        for (index, block) in blocks.enumerated() {
            if index > 0 { card.addArrangedSubview(divider()) }
            card.addArrangedSubview(providerBlockView(block))
        }
        return card
    }

    /// "mark · name · account … load" over the provider's pools side by side.
    private func providerBlockView(_ block: ProviderBlock) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.widthAnchor.constraint(equalToConstant: QuotaLayout.cardWidth).isActive = true

        let head = NSStackView()
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 8
        head.widthAnchor.constraint(equalToConstant: QuotaLayout.cardWidth).isActive = true
        head.addArrangedSubview(HarnessBadge(agent: block.agent))
        let name = label(block.agent.displayName, font: BoardTheme.sansSmall, color: BoardTheme.textPrimary)
        name.lineBreakMode = .byTruncatingTail
        head.addArrangedSubview(name)
        if let account = block.accountName {
            head.addArrangedSubview(label("·", font: BoardTheme.sansSmall, color: BoardTheme.textMuted))
            let caption = label(account, font: BoardTheme.sansTiny, color: BoardTheme.textMuted)
            caption.identifier = NSUserInterfaceItemIdentifier("quota-account-name")
            caption.lineBreakMode = .byTruncatingTail
            // The account is identity — it keeps its words; the load readout on the
            // right (repeated by the board itself) gives way first.
            caption.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            head.addArrangedSubview(caption)
        }
        head.addArrangedSubview(NSView())   // flexible spacer
        head.addArrangedSubview(loadLabel(block))
        stack.addArrangedSubview(head)

        if block.pools.isEmpty {
            stack.addArrangedSubview(label("quota not tracked", font: BoardTheme.sansTiny, color: BoardTheme.textDim))
            return stack
        }
        let gauges = NSStackView()
        gauges.orientation = .horizontal
        gauges.alignment = .top
        gauges.spacing = QuotaLayout.columnGap
        for pool in block.pools { gauges.addArrangedSubview(poolCell(pool)) }
        stack.addArrangedSubview(gauges)
        return stack
    }

    /// The live load beside the name: "2 working · 1 waiting" (waiting in the NEEDS
    /// YOU red), else "3 idle", else "no sessions".
    private func loadLabel(_ block: ProviderBlock) -> NSTextField {
        let tally = block.tally
        var lines: [String] = []
        if tally.working > 0 { lines.append("\(tally.working) working") }
        if tally.waiting > 0 { lines.append("\(tally.waiting) waiting") }
        let field = label("", font: BoardTheme.sansTiny, color: BoardTheme.textFaint)
        field.identifier = NSUserInterfaceItemIdentifier("quota-load")
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        guard !lines.isEmpty else {
            field.stringValue = block.sessions > 0 ? "\(block.sessions) idle" : "no sessions"
            return field
        }
        let text = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: " · ", attributes: [
                    .font: BoardTheme.sansTiny, .foregroundColor: BoardTheme.textFaint]))
            }
            let waiting = line.hasSuffix("waiting")
            text.append(NSAttributedString(string: line, attributes: [
                .font: waiting ? BoardTheme.sansSmall : BoardTheme.sansTiny,
                .foregroundColor: waiting ? BoardTheme.needs : BoardTheme.textFaint]))
        }
        field.attributedStringValue = text
        return field
    }

    /// One pool: its caption (5H / WEEKLY / MONTHLY) centred over the bar and
    /// countdown, a hairline under the caption tying the two bars to one ruler.
    private func poolCell(_ pool: ProviderBlock.Pool) -> NSView {
        let cell = NSStackView()
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 4
        cell.widthAnchor.constraint(equalToConstant: QuotaLayout.cellWidth).isActive = true
        cell.addArrangedSubview(captionLabel(pool.caption))
        cell.addArrangedSubview(slotView(pool.slot))
        return cell
    }

    private func captionLabel(_ text: String) -> NSView {
        let field = label(text, font: BoardTheme.capsSmall, color: BoardTheme.textFaint)
        // An attributed value carries its own alignment — the field's would be dropped.
        let caps = NSMutableAttributedString(attributedString: BoardTheme.caps(
            text, color: BoardTheme.textFaint, font: BoardTheme.capsSmall, kern: 0.6))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        caps.addAttribute(.paragraphStyle, value: centered,
                          range: NSRange(location: 0, length: caps.length))
        field.attributedStringValue = caps
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(field)
        let rule = NSView()
        rule.themedBackground = BoardTheme.hairline
        rule.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(rule)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: QuotaLayout.cellWidth),
            box.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            field.topAnchor.constraint(equalTo: box.topAnchor),
            rule.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
        return box
    }

    private func divider() -> NSView {
        // The board's own hairline token, not the system separator — every line in
        // the window is the same ink.
        let divider = NSView()
        divider.themedBackground = BoardTheme.hairline
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: QuotaLayout.cardWidth),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
        return divider
    }

    private func slotView(_ slot: QuotaSlot) -> NSView {
        switch slot {
        case .gauge(let gauge):
            let row = QuotaGaugeRow(gauge: gauge)
            row.widthAnchor.constraint(equalToConstant: QuotaLayout.cellWidth).isActive = true
            row.heightAnchor.constraint(equalToConstant: QuotaLayout.cellHeight).isActive = true
            rows.append(row)
            return row
        case .placeholder(let kind):
            return QuotaPlaceholderCell(kind: kind)
        }
    }

    private func providerBlocks(
        from gauges: [QuotaGauge],
        claudeProfiles: [ClaudeProfile],
        claudeProfileByCard: [UUID: UUID],
        cards: [BoardCard]
    ) -> [ProviderBlock] {
        let anthropic = gauges.filter { $0.provider.lowercased() == "anthropic" }

        // Claude blocks always keep both pools: an empty cell means "measuring",
        // never "missing" — the two pools are never allowed to disappear.
        var result: [ProviderBlock] = claudeProfiles.map { profile in
            let prefix = profile.poolPrefix
            let interactive = anthropic.first { normalized($0.pool) == normalized(prefix) }
            let interactive5h = anthropic.first { normalized($0.pool) == normalized(profile.pool5h) }
            let interactiveWeekly = anthropic.first {
                normalized($0.pool) == normalized(profile.poolWeekly)
            }
            let profileCards = cards.filter { card in
                guard card.agent == .claude else { return false }
                let pid = claudeProfileByCard[card.id] ?? ClaudeProfile.defaultID
                return pid == profile.id
            }
            return ProviderBlock(
                agent: .claude,
                accountName: claudeProfiles.count > 1 ? profile.name : nil,
                tally: tallyCards(profileCards),
                sessions: profileCards.filter { $0.state != .done }.count,
                pools: [
                    .init(caption: "5H", slot: claudeSlot(interactive5h ?? interactive)),
                    .init(caption: "WEEKLY", slot: claudeSlot(interactiveWeekly)),
                ]
            )
        }

        // Other harnesses earn a block only when there is something to read: a pool
        // we track, or a card running on it. A block of dashes was noise.
        let others: [(String, CardAgent)] = [("codex", .codex), ("cursor", .cursor), ("antigravity", .antigravity)]
        for (label, agent) in others {
            let block = providerBlock(label: label, agent: agent, gauges: gauges, cards: cards)
            if !block.pools.isEmpty || cards.contains(where: { $0.agent == agent }) { result.append(block) }
        }
        return result
    }

    private func providerBlock(
        label: String, agent: CardAgent, gauges: [QuotaGauge], cards: [BoardCard]
    ) -> ProviderBlock {
        let provider = label.lowercased()
        let providerGauges = gauges.filter { $0.provider.lowercased() == provider }
        let fiveHour = providerGauges.first { normalized($0.pool) == "\(provider)_5h" }
        let weekly = providerGauges.first { normalized($0.pool) == "\(provider)_weekly" }
        let single = providerGauges.first { normalized($0.pool) == provider }
        let agentCards = cards.filter { $0.agent == agent }
        var pools: [ProviderBlock.Pool] = []
        if let fiveHour { pools.append(.init(caption: "5H", slot: .gauge(fiveHour))) }
        if let weekly { pools.append(.init(caption: "WEEKLY", slot: .gauge(weekly))) }
        else if let single { pools.append(.init(caption: Self.caption(for: single), slot: .gauge(single))) }
        return ProviderBlock(
            agent: agent,
            accountName: nil,
            tally: tallyCards(agentCards),
            sessions: agentCards.filter { $0.state != .done }.count,
            pools: pools
        )
    }

    /// What a provider's single pool is a window of: a hard-stop credit refills
    /// monthly; a rolling window is weekly unless the source says otherwise.
    static func caption(for gauge: QuotaGauge) -> String {
        switch gauge.fallback {
        case .none: return "MONTHLY"
        case .windowReset: return "5H"
        case .weeklyReset, .unknown: return "WEEKLY"
        }
    }

    /// Claude pools wait on the hidden `/usage` scrape — an empty cell means
    /// "measuring", not "missing", so we never flash a false green estimate.
    private func claudeSlot(_ gauge: QuotaGauge?) -> QuotaSlot {
        guard let gauge else {
            return .placeholder(HiddenTUIProbe.spawningEnabled ? .measuring : .empty)
        }
        return .gauge(gauge)
    }

    private func preserveHiddenRows(for gauges: [QuotaGauge]) {
        let visible = Set(rows.map(\.gauge.id))
        for gauge in gauges where !visible.contains(gauge.id) {
            rows.append(QuotaGaugeRow(gauge: gauge))
        }
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    private func tallyCards(_ cards: [BoardCard]) -> AgentTaskTally {
        var working = 0
        var waiting = 0
        for card in cards {
            switch card.state {
            case .running, .runningTests: working += 1
            case .waitingForInput: waiting += 1
            case .blocked, .parked: break
            case .idle, .done, .unknown, .unreachable: break
            }
        }
        return AgentTaskTally(working: working, waiting: waiting)
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        return field
    }
}

/// Every text-carrying box tracks ``BoardTheme/boardFontScale`` so the compact grid
/// stays proportional as the board zoom changes.
@MainActor
enum QuotaLayout {
    /// A window taller than it is wide has height to spare and none of width, so
    /// the panel drops under the board instead of taking a column off its side.
    static func dock(forContentSize size: NSSize) -> QuotaDock {
        guard size.height > size.width else { return .trailing }
        let fitting = (size.width - outerInset * 2 + sectionGap) / (cardWidth + sectionGap)
        return .bottom(columns: max(1, Int(fitting)))
    }

    static var panelWidth: CGFloat { cardWidth + outerInset * 2 }
    static var cardWidth: CGFloat { scaled(240) }
    /// Two pools share the card width, with air between them so each reads as its
    /// own instrument.
    static var cellWidth: CGFloat { ((cardWidth - columnGap) / 2).rounded(.down) }
    /// Bar (18) + spacing (4) + countdown line (~13).
    static var cellHeight: CGFloat { scaled(36) }
    static var barHeight: CGFloat { scaled(18) }
    static let barCornerRadius: CGFloat = 5
    static let barTextInset: CGFloat = 7
    static var columnGap: CGFloat { scaled(14) }
    /// The board lanes' 20pt gutter, so the panel's content lines up like a lane's.
    static var outerInset: CGFloat { scaled(20) }
    /// Matches the board lane stack's top offset (``BoardView``'s 12pt).
    static let headerTop: CGFloat = 12
    /// Unboxed cards side by side (bottom dock) need air to read as separate.
    static var sectionGap: CGFloat { scaled(28) }
    /// Air around the hairline between two provider blocks.
    static var blockGap: CGFloat { scaled(10) }

    private static func scaled(_ size: CGFloat) -> CGFloat {
        (size * BoardTheme.boardFontScale).rounded(.toNearestOrAwayFromZero)
    }
}

private struct ProviderBlock {
    struct Pool {
        let caption: String
        let slot: QuotaSlot
    }

    let agent: CardAgent
    /// Which Claude account this block belongs to; only set once there is more
    /// than one on the board, so the single-account panel stays as terse as before.
    let accountName: String?
    let tally: AgentTaskTally
    /// Live cards on this provider (done excluded) — "N idle" when none is working.
    let sessions: Int
    let pools: [Pool]
}

private enum QuotaSlot {
    case gauge(QuotaGauge)
    case placeholder(QuotaPlaceholderKind)
}

private enum QuotaPlaceholderKind: Equatable {
    case measuring
    case empty
}

@MainActor
private final class QuotaPlaceholderCell: NSView, ThemeReapplying {
    private let kind: QuotaPlaceholderKind
    private let track = CALayer()
    private let fill = CALayer()
    private let shimmer = CALayer()
    private let placeholder = CATextLayer()
    private let caption = NSTextField(labelWithString: "")

    init(kind: QuotaPlaceholderKind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: QuotaLayout.cellWidth).isActive = true
        heightAnchor.constraint(equalToConstant: QuotaLayout.cellHeight).isActive = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        layer?.addSublayer(shimmer)
        placeholder.string = kind == .empty ? "—" : ""
        placeholder.font = BoardTheme.numericSmall
        placeholder.fontSize = BoardTheme.numericSmall.pointSize
        placeholder.alignmentMode = .center
        placeholder.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(placeholder)
        // The countdown line's slot: "measuring…" while the scrape is pending.
        caption.stringValue = kind == .measuring ? "measuring…" : ""
        caption.font = BoardTheme.numericSmall
        caption.textColor = BoardTheme.textDim
        caption.isBezeled = false
        caption.drawsBackground = false
        caption.isEditable = false
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityLabel(kind == .empty ? "Not available" : "Measuring")
        setAccessibilityValue(kind == .empty ? "—" : "")
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // Top of the cell, matching where `QuotaGaugeRow`'s stack puts its bar — the view
        // is unflipped, so that's `height - barHeight`, not zero.
        let bar = NSRect(x: 0, y: bounds.height - QuotaLayout.barHeight,
                         width: bounds.width, height: QuotaLayout.barHeight)
        track.frame = bar
        track.cornerRadius = QuotaLayout.barCornerRadius
        track.borderWidth = 1

        switch kind {
        case .measuring:
            fill.frame = bar
            fill.cornerRadius = QuotaLayout.barCornerRadius
            shimmer.frame = NSRect(x: -bar.width * 0.4, y: bar.minY, width: bar.width * 0.4, height: bar.height)
            shimmer.cornerRadius = QuotaLayout.barCornerRadius
            startMeasuringAnimation()
        case .empty:
            fill.frame = .zero
            shimmer.frame = .zero
            shimmer.removeAllAnimations()
        }
        placeholder.frame = bar
        applyColors()
    }

    /// Raw sublayers again: no `themedBackground` for the appearance walk to re-resolve,
    /// so the walk calls this instead. Geometry is left to ``layout()`` — a flip only
    /// changes colour.
    func reapplyTheme(under appearance: NSAppearance) { applyColors(under: appearance) }

    /// Resolved against the appearance in force now, since a CALayer keeps whatever
    /// plain `cgColor` it was last handed. Mid-flip the walk hands the new appearance in,
    /// since `effectiveAppearance` hasn't caught up yet.
    private func applyColors(under appearance: NSAppearance? = nil) {
        (appearance ?? effectiveAppearance).performAsCurrentDrawingAppearance {
            track.backgroundColor = (kind == .empty ? NSColor.clear : BoardTheme.gaugeTrack).cgColor
            track.borderColor = (kind == .empty ? NSColor.clear : BoardTheme.gaugeRing).cgColor
            placeholder.foregroundColor = BoardTheme.textFaint.cgColor
            guard kind == .measuring else { return }
            // A slow, faint drift — the panel admits it is still measuring without
            // flashing; the same neutral ink as the gauges themselves.
            fill.backgroundColor = BoardTheme.textFaint.withAlphaComponent(0.10).cgColor
            shimmer.backgroundColor = BoardTheme.textFaint.withAlphaComponent(0.22).cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            shimmer.removeAllAnimations()
        } else if kind == .measuring {
            startMeasuringAnimation()
        }
    }

    private func startMeasuringAnimation() {
        guard window != nil, shimmer.animation(forKey: "sweep") == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = -bounds.width * 0.2
        animation.toValue = bounds.width * 1.38
        animation.duration = 2.8
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmer.add(animation, forKey: "sweep")
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
