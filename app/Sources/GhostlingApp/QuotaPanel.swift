import AppKit
import GhostlingCore

/// Compact quota/usage side panel: a launch recommendation card followed by a
/// dense provider-by-window usage table. The table keeps the underlying
/// ``QuotaGauge`` invariant intact: each real pool is still rendered by one
/// ``QuotaGaugeRow`` and exposed through `rows`; the table layout only changes
/// where those rows sit on screen.
@MainActor
public final class QuotaPanel: NSView {
    public private(set) var rows: [QuotaGaugeRow] = []

    private let scroll = NSScrollView()
    private let content = NSStackView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = BoardTheme.canvas.cgColor
        buildScaffold()
    }

    public required init?(coder: NSCoder) { nil }

    private func buildScaffold() {
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 18, left: 16, bottom: 18, right: 16)
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

    public func render(gauges: [QuotaGauge]) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []

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
        card.layer?.backgroundColor = accent.withAlphaComponent(0.10).cgColor
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 1
        card.layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
        card.widthAnchor.constraint(equalToConstant: QuotaLayout.cardWidth).isActive = true

        card.addArrangedSubview(label(rec.headline, font: BoardTheme.monoBold, color: accent))
        let detail = label(rec.detail, font: BoardTheme.monoSmall, color: BoardTheme.textMuted)
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
        card.spacing = 12
        card.edgeInsets = NSEdgeInsets(top: 18, left: 16, bottom: 16, right: 16)
        card.wantsLayer = true
        card.layer?.backgroundColor = BoardTheme.cardFill.cgColor
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 1
        card.layer?.borderColor = BoardTheme.cardStroke.cgColor
        card.widthAnchor.constraint(equalToConstant: QuotaLayout.cardWidth).isActive = true

        card.addArrangedSubview(columnHeader())
        for model in providerRows(from: gauges) {
            card.addArrangedSubview(providerRow(model))
        }
        return card
    }

    private func columnHeader() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = QuotaLayout.columnGap
        row.widthAnchor.constraint(equalToConstant: QuotaLayout.innerWidth).isActive = true
        row.addArrangedSubview(NSView.fixed(width: QuotaLayout.providerWidth))
        row.addArrangedSubview(columnLabel("5H"))
        row.addArrangedSubview(columnLabel("WEEKLY"))
        return row
    }

    private func providerRow(_ model: ProviderQuotaRow) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = QuotaLayout.columnGap
        row.widthAnchor.constraint(equalToConstant: QuotaLayout.innerWidth).isActive = true

        let name = label(model.label, font: BoardTheme.mono, color: BoardTheme.textPrimary)
        name.widthAnchor.constraint(equalToConstant: QuotaLayout.providerWidth).isActive = true
        row.addArrangedSubview(name)
        row.addArrangedSubview(cell(for: model.fiveHour))
        row.addArrangedSubview(cell(for: model.weekly))
        return row
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
                fiveHour: slot(interactive5h ?? interactive),
                weekly: slot(interactiveWeekly ?? sdk)
            )
        ]

        result.append(providerRow(label: "codex", gauges: gauges))
        return result
    }

    private func providerRow(label: String, gauges: [QuotaGauge]) -> ProviderQuotaRow {
        let provider = label.lowercased()
        let providerGauges = gauges.filter { $0.provider.lowercased() == provider }
        let fiveHour = providerGauges.first { normalized($0.pool) == "\(provider)_5h" }
        let weekly = providerGauges.first { normalized($0.pool) == "\(provider)_weekly" }
        let single = providerGauges.first { normalized($0.pool) == provider }
        return ProviderQuotaRow(
            label: provider,
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

    private func columnLabel(_ text: String) -> NSTextField {
        let field = label(text, font: BoardTheme.monoSmall, color: BoardTheme.textFaint)
        field.alignment = .center
        field.widthAnchor.constraint(equalToConstant: QuotaLayout.cellWidth).isActive = true
        return field
    }
}

enum QuotaLayout {
    static let cardWidth: CGFloat = 296
    static let innerWidth: CGFloat = 264
    static let providerWidth: CGFloat = 56
    static let cellWidth: CGFloat = 94
    static let cellHeight: CGFloat = 38
    static let barHeight: CGFloat = 8
    static let columnGap: CGFloat = 10
}

private struct ProviderQuotaRow {
    let label: String
    let fiveHour: QuotaSlot
    let weekly: QuotaSlot
}

private enum QuotaSlot {
    case gauge(QuotaGauge)
    case placeholder(QuotaPlaceholderKind)
}

private enum QuotaPlaceholderKind {
    case measuring
    case empty
}

@MainActor
private final class QuotaPlaceholderCell: NSView {
    private let kind: QuotaPlaceholderKind
    private let track = CALayer()
    private let fill = CALayer()
    private let shimmer = CALayer()

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
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let bar = NSRect(x: 0, y: 0,
                         width: bounds.width, height: QuotaLayout.barHeight)
        track.frame = bar
        track.cornerRadius = QuotaLayout.barHeight / 2
        track.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor

        switch kind {
        case .measuring:
            fill.frame = bar
            fill.cornerRadius = QuotaLayout.barHeight / 2
            fill.backgroundColor = BoardTheme.brand.withAlphaComponent(0.22).cgColor
            shimmer.frame = NSRect(x: -bar.width * 0.35, y: bar.minY, width: bar.width * 0.35, height: bar.height)
            shimmer.cornerRadius = QuotaLayout.barHeight / 2
            shimmer.backgroundColor = BoardTheme.brand.withAlphaComponent(0.65).cgColor
            startMeasuringAnimation()
        case .empty:
            fill.frame = .zero
            shimmer.frame = .zero
            shimmer.removeAllAnimations()
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
