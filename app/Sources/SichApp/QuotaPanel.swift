import AppKit
import SichCore

/// Compact quota/usage side panel: a launch recommendation card followed by a
/// dense provider-by-window usage table. The table keeps the underlying
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

    private let scroll = NSScrollView()
    private let content = NSStackView()
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
            top: QuotaLayout.outerInset,
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
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
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
    }

    /// `cards` feeds the per-harness load readout (how many tasks each harness has
    /// working / waiting on you) beside its gauges; callers without a board (the
    /// standalone quota window) omit it and get the plain usage table.
    public func render(gauges: [QuotaGauge], cards: [BoardCard] = []) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []
        tallies = AgentTaskTally.tally(cards)
        taskLines = [:]

        content.addArrangedSubview(recommendationCard(QuotaAdvisor.recommend(from: gauges)))
        content.addArrangedSubview(usageCard(gauges: gauges))
        preserveHiddenRows(for: gauges)
    }

    private func recommendationCard(_ rec: QuotaRecommendation) -> NSView {
        let accent = recommendationColor(rec.action)
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 6
        card.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        card.wantsLayer = true
        card.themedBackground = accent.withAlphaComponent(0.10)
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 1
        card.themedBorder = accent.withAlphaComponent(0.55)
        card.widthAnchor.constraint(equalToConstant: QuotaLayout.cardWidth).isActive = true

        let headline = label(rec.headline, font: BoardTheme.sansStrong, color: accent)
        headline.maximumNumberOfLines = 2
        headline.lineBreakMode = .byWordWrapping
        headline.preferredMaxLayoutWidth = QuotaLayout.cardWidth - 32
        card.addArrangedSubview(headline)
        let detail = label(rec.detail, font: BoardTheme.sansBody, color: BoardTheme.textMuted)
        detail.attributedStringValue = BoardTheme.prose(
            rec.detail, font: BoardTheme.sansBody, color: BoardTheme.textMuted)
        detail.maximumNumberOfLines = 3
        detail.lineBreakMode = .byWordWrapping
        detail.preferredMaxLayoutWidth = QuotaLayout.cardWidth - 32
        card.addArrangedSubview(detail)
        return card
    }

    private func usageCard(gauges: [QuotaGauge]) -> NSView {
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 0
        card.edgeInsets = NSEdgeInsets(
            top: QuotaLayout.cardInset,
            left: QuotaLayout.cardInset,
            bottom: QuotaLayout.cardInset,
            right: QuotaLayout.cardInset
        )
        card.wantsLayer = true
        card.themedBackground = BoardTheme.cardFill
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 1
        card.themedBorder = BoardTheme.cardStroke
        card.widthAnchor.constraint(equalToConstant: QuotaLayout.cardWidth).isActive = true

        let header = columnHeader()
        card.addArrangedSubview(header)
        card.setCustomSpacing(QuotaLayout.headerGap, after: header)

        let models = providerRows(from: gauges)
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
        row.addArrangedSubview(columnLabel("LEFT", width: QuotaLayout.providerWidth))
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
        return row
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

        let tally = model.agent.flatMap { tallies[$0] } ?? AgentTaskTally()
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
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: QuotaLayout.innerWidth).isActive = true
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

    private func providerRows(from gauges: [QuotaGauge]) -> [ProviderQuotaRow] {
        let anthropic = gauges.filter { $0.provider.lowercased() == "anthropic" }
        let interactive = anthropic.first { normalized($0.pool) == "interactive" }
        let interactive5h = anthropic.first { normalized($0.pool) == "interactive_5h" }
        let interactiveWeekly = anthropic.first { normalized($0.pool) == "interactive_weekly" }
        let sdk = anthropic.first { normalized($0.pool) == "agent_sdk_credit" }

        var result: [ProviderQuotaRow] = [
            ProviderQuotaRow(
                label: "claude",
                agent: .claude,
                fiveHour: slot(interactive5h ?? interactive),
                weekly: slot(interactiveWeekly ?? sdk)
            )
        ]

        result.append(providerRow(label: "codex", agent: .codex, gauges: gauges))
        return result
    }

    private func providerRow(label: String, agent: CardAgent?, gauges: [QuotaGauge]) -> ProviderQuotaRow {
        let provider = label.lowercased()
        let providerGauges = gauges.filter { $0.provider.lowercased() == provider }
        let fiveHour = providerGauges.first { normalized($0.pool) == "\(provider)_5h" }
        let weekly = providerGauges.first { normalized($0.pool) == "\(provider)_weekly" }
        let single = providerGauges.first { normalized($0.pool) == provider }
        return ProviderQuotaRow(
            label: provider,
            agent: agent,
            fiveHour: fiveHour.map(QuotaSlot.gauge) ?? .placeholder(.empty),
            weekly: weekly.map(QuotaSlot.gauge) ?? slot(single)
        )
    }

    private func slot(_ gauge: QuotaGauge?) -> QuotaSlot {
        guard let gauge else { return .placeholder(.empty) }
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

    private func recommendationColor(_ action: QuotaRecommendation.Action) -> NSColor {
        switch action {
        case .launchInteractive: return BoardTheme.stateColor(.done)
        case .routeToSDK: return BoardTheme.flowColor(.a)
        case .hold: return BoardTheme.attention
        case .measuring: return BoardTheme.textMuted
        }
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
        let field = label(text, font: BoardTheme.monoSmall, color: BoardTheme.textFaint)
        field.alignment = .center
        field.toolTip = text == "LEFT" ? "Quota remaining" : nil
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }
}

/// Every text-carrying box tracks ``BoardTheme/boardFontScale`` so the compact grid
/// stays proportional as the board zoom changes.
@MainActor
enum QuotaLayout {
    static var panelWidth: CGFloat { cardWidth + outerInset * 2 }
    static var cardWidth: CGFloat { innerWidth + cardInset * 2 }
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
    static var outerInset: CGFloat { scaled(12) }
    static var cardInset: CGFloat { scaled(12) }
    static var sectionGap: CGFloat { scaled(12) }
    static var headerGap: CGFloat { scaled(8) }
    static var rowGap: CGFloat { scaled(4) }

    private static func scaled(_ size: CGFloat) -> CGFloat {
        (size * BoardTheme.boardFontScale).rounded(.toNearestOrAwayFromZero)
    }
}

private struct ProviderQuotaRow {
    let label: String
    /// The harness this provider row's badge + load counts key on; `nil` renders
    /// a plain text label (a provider with no board-card representation).
    let agent: CardAgent?
    let fiveHour: QuotaSlot
    let weekly: QuotaSlot
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
        placeholder.font = BoardTheme.monoSmall
        placeholder.fontSize = BoardTheme.monoSmall.pointSize
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
        guard window != nil, shimmer.animation(forKey: "sweep") == nil else { return }
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = -bounds.width * 0.18
        animation.toValue = bounds.width * 1.18
        animation.duration = 1.15
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmer.add(animation, forKey: "sweep")
    }
}

private extension NSView {
    static func fixed(width: CGFloat) -> NSView {
        let view = NSView()
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
