import AppKit
import SichCore

/// Where the quota panel sits in the board window.
enum QuotaDock: Equatable {
    /// A fixed-width column on the board's trailing edge — landscape windows.
    case trailing
    /// A strip under the board — portrait windows, where height is the spare
    /// dimension and every point of width belongs to the columns. `columns` is
    /// how many quota cards fit side by side: the usage table splits across them
    /// so the strip stays short. With one column it is a single card, as on the
    /// trailing edge.
    case bottom(columns: Int)
}

/// Compact quota/usage panel: a dense provider-by-window usage table. (A
/// "safe to launch" advice card used to sit above it; it only restated what
/// the bars beside it already show, so it was removed.) The table keeps the underlying
/// ``QuotaGauge`` invariant intact: each real pool is still rendered by one
/// ``QuotaGaugeRow`` and exposed through `rows`; the table layout only changes
/// where those rows sit on screen.
@MainActor
public final class QuotaPanel: NSView {
    public private(set) var rows: [QuotaGaugeRow] = []
    /// Last render's per-harness in-progress counts (from the board's cards).
    public private(set) var tallies: [CardAgent: AgentTaskTally] = [:]
    /// Test seam: the load lines actually rendered under each provider badge,
    /// keyed by provider label — e.g. `"claude": ["2 working", "1 waiting"]`.
    private(set) var taskLines: [String: [String]] = [:]

    /// Set by the shell, which re-renders afterwards: the dock decides how many
    /// usage cards the next ``render(gauges:cards:claudeProfiles:claudeProfileByCard:)`` lays out.
    var dock: QuotaDock = .trailing {
        didSet { if dock != oldValue { applyDock() } }
    }

    private let scroll = NSScrollView()
    private let content = NSStackView()
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
        super.init(frame: frameRect)
        wantsLayer = true
        themedBackground = BoardTheme.canvas
        buildScaffold()
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
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        let sideBySide = if case .bottom(let columns) = dock { columns > 1 } else { false }
        content.orientation = sideBySide ? .horizontal : .vertical
        content.alignment = sideBySide ? .top : .leading
        topHairline.isHidden = dock == .trailing
        leadingHairline.isHidden = dock != .trailing
        hugsContentHeight.isActive = dock != .trailing
    }

    /// How many cards the usage table is split across (see ``QuotaDock``).
    private var usageCardCount: Int {
        switch dock {
        case .trailing: return 1
        case .bottom(let columns): return max(1, columns)
        }
    }

    /// `cards` feeds the per-harness load readout (how many tasks each harness has
    /// working / waiting on you) beside its gauges; callers without a board (the
    /// standalone quota window) omit it and get the plain usage table.
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
        taskLines = [:]

        if dock == .trailing {
            let title = laneTitle()
            content.addArrangedSubview(title)
            content.setCustomSpacing(10, after: title)
        }
        let models = providerRows(
            from: gauges, claudeProfiles: claudeProfiles,
            claudeProfileByCard: claudeProfileByCard, cards: cards)
        let perCard = max(1, (models.count + usageCardCount - 1) / usageCardCount)
        for start in stride(from: 0, to: models.count, by: perCard) {
            let chunk = models[start..<min(start + perCard, models.count)]
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

    /// One usage table: the 5H / WEEKLY header over its share of the provider rows.
    private func usageCard(_ models: [ProviderQuotaRow]) -> NSView {
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 0
        // No box: the board's lanes are borderless, and a bordered card here read as a
        // different product docked beside the board. Alignment and the hairline
        // dividers do the grouping.
        card.widthAnchor.constraint(equalToConstant: QuotaLayout.cardWidth).isActive = true

        let header = columnHeader()
        card.addArrangedSubview(header)
        card.setCustomSpacing(QuotaLayout.headerGap, after: header)

        for (index, model) in models.enumerated() {
            if index > 0 {
                let divider = rowDivider()
                card.addArrangedSubview(divider)
                card.setCustomSpacing(QuotaLayout.rowGap, after: divider)
            }
            let row = providerRow(model)
            card.addArrangedSubview(row)
            if index < models.count - 1 {
                card.setCustomSpacing(QuotaLayout.rowGap, after: row)
            }
        }
        return card
    }

    private func columnHeader() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = QuotaLayout.columnGap
        row.widthAnchor.constraint(equalToConstant: QuotaLayout.innerWidth).isActive = true
        // The logo rail needs no header — the marks name themselves.
        let rail = NSView()
        rail.widthAnchor.constraint(equalToConstant: QuotaLayout.providerWidth).isActive = true
        row.addArrangedSubview(rail)
        row.addArrangedSubview(columnLabel("5H"))
        row.addArrangedSubview(columnLabel("WEEKLY"))
        return row
    }

    private func providerRow(_ model: ProviderQuotaRow) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = QuotaLayout.columnGap
        row.widthAnchor.constraint(equalToConstant: QuotaLayout.innerWidth).isActive = true

        row.addArrangedSubview(providerCell(model))
        row.addArrangedSubview(cell(for: model.fiveHour))
        row.addArrangedSubview(cell(for: model.weekly))
        guard let account = model.accountName else { return row }

        // With several Claude accounts the badge alone no longer says whose pools
        // these are. The name gets the whole row width above the gauges — the
        // 36pt logo rail could only ever show a truncated sliver of it.
        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 2
        let caption = label(account, font: BoardTheme.sansSmall, color: BoardTheme.textMuted)
        caption.identifier = NSUserInterfaceItemIdentifier("quota-account-name")
        caption.lineBreakMode = .byTruncatingTail
        caption.widthAnchor.constraint(equalToConstant: QuotaLayout.innerWidth).isActive = true
        block.addArrangedSubview(caption)
        block.addArrangedSubview(row)
        return block
    }

    /// The provider column: the harness badge (visual identity, not a text name)
    /// with a compact rendering of the harness's current board load under it, so
    /// each pool's demand sits beside what's left without widening the logo rail.
    private func providerCell(_ model: ProviderQuotaRow) -> NSView {
        let cell = NSStackView()
        cell.orientation = .vertical
        cell.alignment = .centerX
        cell.spacing = 3
        cell.widthAnchor.constraint(equalToConstant: QuotaLayout.providerWidth).isActive = true

        if let agent = model.agent {
            cell.addArrangedSubview(HarnessBadge(agent: agent))
        } else {
            cell.addArrangedSubview(label(model.label, font: BoardTheme.mono, color: BoardTheme.textPrimary))
        }

        let tally = model.tally
        var lines: [String] = []
        func addLine(_ text: String, compact: String, color: NSColor) {
            lines.append(text)
            let field = label(compact, font: BoardTheme.sansTiny, color: color)
            field.alignment = .center
            field.toolTip = text
            field.widthAnchor.constraint(equalToConstant: QuotaLayout.providerWidth).isActive = true
            cell.addArrangedSubview(field)
        }
        if tally.working > 0 {
            addLine("\(tally.working) working", compact: "\(tally.working) work",
                    color: BoardTheme.stateColor(.running))
        }
        if tally.waiting > 0 {
            addLine("\(tally.waiting) waiting", compact: "\(tally.waiting) wait",
                    color: BoardTheme.attention)
        }
        taskLines[model.label] = lines
        return cell
    }

    private func rowDivider() -> NSView {
        // The board's own hairline token, not the system separator — every line in
        // the window is the same ink.
        let divider = NSView()
        divider.themedBackground = BoardTheme.hairline
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: QuotaLayout.innerWidth),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
        return divider
    }

    private func cell(for slot: QuotaSlot) -> NSView {
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

    private func providerRows(
        from gauges: [QuotaGauge],
        claudeProfiles: [ClaudeProfile],
        claudeProfileByCard: [UUID: UUID],
        cards: [BoardCard]
    ) -> [ProviderQuotaRow] {
        let anthropic = gauges.filter { $0.provider.lowercased() == "anthropic" }

        var result: [ProviderQuotaRow] = claudeProfiles.map { profile in
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
            return ProviderQuotaRow(
                label: profile.quotaLabel,
                agent: .claude,
                accountName: claudeProfiles.count > 1 ? profile.name : nil,
                tally: tallyCards(profileCards),
                fiveHour: claudeSlot(interactive5h ?? interactive),
                weekly: claudeSlot(interactiveWeekly)
            )
        }

        // Other harnesses earn a row only when there is something to read: a pool we
        // track, or a card running on it. A row of dashes was noise. Claude accounts
        // above always stay — "measuring" is information there, and the two pools
        // are never allowed to disappear from the panel.
        let others: [(String, CardAgent)] = [("codex", .codex), ("cursor", .cursor), ("antigravity", .antigravity)]
        for (label, agent) in others {
            let row = providerRow(label: label, agent: agent, gauges: gauges, cards: cards)
            if row.hasGauge || cards.contains(where: { $0.agent == agent }) { result.append(row) }
        }
        return result
    }

    private func providerRow(
        label: String, agent: CardAgent?, gauges: [QuotaGauge], cards: [BoardCard]
    ) -> ProviderQuotaRow {
        let provider = label.lowercased()
        let providerGauges = gauges.filter { $0.provider.lowercased() == provider }
        let fiveHour = providerGauges.first { normalized($0.pool) == "\(provider)_5h" }
        let weekly = providerGauges.first { normalized($0.pool) == "\(provider)_weekly" }
        let single = providerGauges.first { normalized($0.pool) == provider }
        let agentCards = agent.map { a in cards.filter { $0.agent == a } } ?? []
        return ProviderQuotaRow(
            label: provider,
            agent: agent,
            accountName: nil,
            tally: tallyCards(agentCards),
            fiveHour: fiveHour.map(QuotaSlot.gauge) ?? .placeholder(.empty),
            weekly: weekly.map(QuotaSlot.gauge) ?? slot(single)
        )
    }

    private func slot(_ gauge: QuotaGauge?) -> QuotaSlot {
        guard let gauge else { return .placeholder(.empty) }
        return .gauge(gauge)
    }

    /// Claude rows wait on the hidden `/usage` scrape — an empty cell means
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

    private func columnLabel(_ text: String, width: CGFloat = QuotaLayout.cellWidth) -> NSTextField {
        let field = label(text, font: BoardTheme.capsSmall, color: BoardTheme.textFaint)
        // An attributed value carries its own alignment — the field's would be dropped.
        let caps = NSMutableAttributedString(attributedString: BoardTheme.caps(
            text, color: BoardTheme.textFaint, font: BoardTheme.capsSmall))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        caps.addAttribute(.paragraphStyle, value: centered,
                          range: NSRange(location: 0, length: caps.length))
        field.attributedStringValue = caps
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
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
    static var cardWidth: CGFloat { innerWidth }
    static var innerWidth: CGFloat { providerWidth + cellWidth * 2 + columnGap * 2 }
    static var providerWidth: CGFloat { scaled(36) }
    static var cellWidth: CGFloat { scaled(94) }
    /// Bar (18) + spacing (4) + countdown line (~13). The percent moved inside the bar,
    /// so the cell lost a whole text row and gained a bar you can actually read.
    static var cellHeight: CGFloat { scaled(36) }
    static var barHeight: CGFloat { scaled(18) }
    static let barCornerRadius: CGFloat = 5
    static let barTextInset: CGFloat = 7
    static var columnGap: CGFloat { scaled(8) }
    /// The board lanes' 20pt gutter, so the panel's content lines up like a lane's.
    static var outerInset: CGFloat { scaled(20) }
    /// Matches the board lane stack's top offset (``BoardView``'s 12pt).
    static let headerTop: CGFloat = 12
    /// Unboxed tables side by side (bottom dock) need air to read as separate.
    static var sectionGap: CGFloat { scaled(28) }
    static var headerGap: CGFloat { scaled(8) }
    static var rowGap: CGFloat { scaled(4) }

    private static func scaled(_ size: CGFloat) -> CGFloat {
        (size * BoardTheme.boardFontScale).rounded(.toNearestOrAwayFromZero)
    }
}

private struct ProviderQuotaRow {
    let label: String
    let agent: CardAgent?
    /// Which Claude account this row belongs to; only set once there is more than
    /// one on the board, so the single-account panel stays as terse as before.
    let accountName: String?
    let tally: AgentTaskTally
    let fiveHour: QuotaSlot
    let weekly: QuotaSlot

    var hasGauge: Bool {
        [fiveHour, weekly].contains { if case .gauge = $0 { true } else { false } }
    }
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

        switch kind {
        case .measuring:
            fill.frame = bar
            fill.cornerRadius = QuotaLayout.barCornerRadius
            shimmer.frame = NSRect(x: -bar.width * 0.35, y: bar.minY, width: bar.width * 0.35, height: bar.height)
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
            placeholder.foregroundColor = BoardTheme.textFaint.cgColor
            guard kind == .measuring else { return }
            fill.backgroundColor = BoardTheme.brand.withAlphaComponent(0.22).cgColor
            shimmer.backgroundColor = BoardTheme.brand.withAlphaComponent(0.65).cgColor
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
        animation.fromValue = -bounds.width * 0.18
        animation.toValue = bounds.width * 1.18
        animation.duration = 1.15
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmer.add(animation, forKey: "sweep")
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
