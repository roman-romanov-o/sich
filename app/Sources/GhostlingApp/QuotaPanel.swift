import AppKit
import GhostlingCore

/// The two-pool quota panel (US-006): renders an array of ``QuotaGauge`` as FOUR
/// DISTINCT gauges — the two Anthropic pools (interactive 5h+weekly / Agent SDK
/// credit) visually GROUPED but NEVER merged into one number, plus best-effort
/// Codex / Gemini. Inferred values carry a visible "estimated" cue; exhausted and
/// unknown states are unmistakable; the hard-stop-vs-window-reset asymmetry is
/// shown (`research/10`, `research/UI_POC.html` HELM cluster).
///
/// Single responsibility: present `[QuotaGauge]` as gauges. It builds no quota
/// data and nets nothing — the projection (`QuotaProjection`) is the source of
/// truth, and this view renders one row per gauge in gauge order.
///
/// Rendering discipline (Phase-03 lesson): every gauge is a CUSTOM-DRAWN,
/// LAYER-BACKED ``QuotaGaugeRow`` (like `SessionCard`), not a stock-control
/// composite, so a screenshot is faithful evidence for the pixel AC.
@MainActor
public final class QuotaPanel: NSView {
    /// The built view-model — one entry per rendered gauge, in gauge order, with
    /// the Anthropic pools grouped first. Exposed so a test can assert on what
    /// actually renders (two distinct Anthropic gauges, an unknown Gemini, an
    /// estimated cue) without scraping pixels.
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

    // MARK: - Scaffold

    private func buildScaffold() {
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
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
        scroll.hasVerticalScroller = true
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

    // MARK: - Render

    /// Project + render. Groups the two Anthropic pools (interactive first, then
    /// Agent SDK credit) under one header, then renders each remaining provider's
    /// gauges. The two Anthropic gauges stay two separate rows — never summed
    /// into one number (US-006 AC#1 / `research/10`).
    public func render(gauges: [QuotaGauge]) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []

        // The capacity brain leads with a RECOMMENDATION, not a passive meter
        // (US-006): a pool-routing directive derived from the live gauges sits above
        // the bars. Kept as a separate arranged subview — it never touches `rows`,
        // so the gauge-row tests are unaffected.
        content.addArrangedSubview(recommendationBand(QuotaAdvisor.recommend(from: gauges)))
        content.addArrangedSubview(title("Quota — by pool"))

        let anthropic = gauges.filter { $0.provider.lowercased() == "anthropic" }
        let others = gauges.filter { $0.provider.lowercased() != "anthropic" }

        if !anthropic.isEmpty {
            content.addArrangedSubview(groupHeader("Anthropic"))
            let group = makeGroupContainer()
            for (i, gauge) in anthropic.enumerated() {
                if i > 0 { group.addArrangedSubview(poolSeparator()) }
                addRow(gauge, to: group)
            }
            content.addArrangedSubview(group)
        }
        for gauge in others { addRow(gauge, to: content) }

        if gauges.contains(where: { $0.state == .unknown }) {
            let note = label(
                "unknown = no local signal for that pool — shown honestly, never assumed 0% or 100%",
                font: BoardTheme.monoSmall, color: BoardTheme.textFaint)
            note.lineBreakMode = .byWordWrapping
            note.maximumNumberOfLines = 2
            note.preferredMaxLayoutWidth = GaugeLayout.rowWidth
            content.addArrangedSubview(note)
        }
    }

    private func addRow(_ gauge: QuotaGauge, to stack: NSStackView) {
        let row = QuotaGaugeRow(gauge: gauge)
        row.widthAnchor.constraint(equalToConstant: GaugeLayout.rowWidth).isActive = true
        rows.append(row)
        stack.addArrangedSubview(row)
    }

    /// The grouped-but-not-merged Anthropic container: the two pools share one
    /// boxed, labelled region so the eye reads "same provider" — but each pool is
    /// its own ``QuotaGaugeRow`` inside, never combined into a single gauge.
    private func makeGroupContainer() -> NSStackView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 8
        box.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = BoardTheme.hairline.cgColor
        return box
    }

    /// A hairline + caption BETWEEN the two grouped Anthropic pools, so the
    /// "same provider, but two independent pools — never netted" rule is
    /// unmistakable to the eye (US-006 AC#1 / the never-summed constraint).
    private func poolSeparator() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = BoardTheme.hairline.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: GaugeLayout.rowWidth),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        stack.addArrangedSubview(line)
        stack.addArrangedSubview(
            label("independent pool — not summed", font: BoardTheme.monoSmall, color: BoardTheme.textFaint))
        return stack
    }

    /// The recommendation headline band — a tinted, layer-backed box (same custom
    /// render path as the gauge rows, so a screenshot is faithful) whose accent
    /// colour reads the directive at a glance: launch (green), route-to-SDK
    /// (violet/SDK pool), hold (amber), measuring (muted).
    private func recommendationBand(_ rec: QuotaRecommendation) -> NSView {
        let accent = recommendationColor(rec.action)
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 3
        box.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        box.wantsLayer = true
        box.layer?.backgroundColor = accent.withAlphaComponent(0.12).cgColor
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = accent.withAlphaComponent(0.5).cgColor
        box.addArrangedSubview(label(rec.headline, font: BoardTheme.monoBold, color: accent))
        let detail = label(rec.detail, font: BoardTheme.monoSmall, color: BoardTheme.textMuted)
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 3
        detail.preferredMaxLayoutWidth = GaugeLayout.rowWidth - 24
        box.addArrangedSubview(detail)
        box.widthAnchor.constraint(equalToConstant: GaugeLayout.rowWidth).isActive = true
        return box
    }

    private func recommendationColor(_ action: QuotaRecommendation.Action) -> NSColor {
        switch action {
        case .launchInteractive: return BoardTheme.stateColor(.done)
        case .routeToSDK: return BoardTheme.flowColor(.a)
        case .hold: return BoardTheme.attention
        case .measuring: return BoardTheme.textMuted
        }
    }

    private func groupHeader(_ text: String) -> NSTextField {
        label(text + "  ·  two pools — never netted", font: BoardTheme.monoSmall, color: BoardTheme.textFaint)
    }

    private func title(_ text: String) -> NSTextField {
        label(text, font: BoardTheme.title, color: BoardTheme.textPrimary)
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

/// Fixed geometry for a gauge row. 288pt fits inside the 340pt quota column's
/// grouped Anthropic box (340 − 32 panel inset − 20 group inset = 288).
enum GaugeLayout {
    static let rowWidth: CGFloat = 288
    static let barHeight: CGFloat = 8
}

/// A document view that flips its coordinate system so a top-anchored stack inside
/// an `NSScrollView` lays out top-down (AppKit's default origin is bottom-left).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
