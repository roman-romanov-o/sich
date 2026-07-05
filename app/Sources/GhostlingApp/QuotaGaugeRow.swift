import AppKit
import GhostlingCore

/// One quota pool rendered as a single, custom-drawn, layer-backed gauge — the
/// HELM POC's per-pool row (`research/UI_POC.html`). It presents exactly one
/// ``QuotaGauge`` and nets nothing; the panel renders one of these per gauge.
///
/// Built CUSTOM-DRAWN + LAYER-BACKED (like `SessionCard`, the Phase-03 lesson) so
/// a `CGWindowListCreateImage` capture composites it faithfully and a screenshot
/// is real evidence for the pixel AC. It exposes the cues the swift-test cases
/// assert on — `showsEstimatedCue`, `isExhausted`, `isUnknown`, `resetText`,
/// `remainingText` — so the render path itself is machine-verified, not just the
/// underlying value type.
@MainActor
public final class QuotaGaugeRow: NSView {
    public let gauge: QuotaGauge

    /// US-006 AC#3: an inferred (estimated) gauge shows a visible confidence cue;
    /// a measured gauge does NOT. The test asserts on this directly.
    public var showsEstimatedCue: Bool { gauge.confidence == .estimated }
    /// US-006 edge case #1: the pool is hard/locked-out exhausted.
    public var isExhausted: Bool { gauge.state == .exhausted }
    /// US-006 edge case #2: no usable signal — "unknown / not tracked", not free.
    public var isUnknown: Bool { gauge.state == .unknown }

    private let bar = QuotaBar()
    private let titleLabel = QuotaGaugeRow.makeLabel()
    private let estimatedBadge = QuotaGaugeRow.makeLabel()
    private let remainingLabel = QuotaGaugeRow.makeLabel()
    private let resetLabel = QuotaGaugeRow.makeLabel()

    public init(gauge: QuotaGauge) {
        self.gauge = gauge
        super.init(frame: .zero)
        wantsLayer = true
        configureLayer()
        buildContent()
    }

    public required init?(coder: NSCoder) { nil }

    // MARK: - Test-facing render facts

    /// The human-facing remaining string this row renders (e.g. "60% remaining",
    /// "exhausted", "unknown / not tracked"). Asserted by the E2E cases so the
    /// render text — not just the value type — is covered.
    public var remainingText: String { remainingLabel.stringValue }
    /// The reset / refill line this row renders (empty when there is nothing to
    /// show, e.g. an unknown pool).
    public var resetText: String { resetLabel.stringValue }
    /// The pool's title as rendered ("interactive (5h + weekly)", "Agent SDK
    /// credit", "Codex", "Gemini").
    public var titleText: String { titleLabel.stringValue }

    // MARK: - Appearance

    private func configureLayer() {
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        if isExhausted {
            // Exhausted is unmistakable: a red wash + red edge (edge case #1).
            layer?.backgroundColor = NSColor(red: 0.20, green: 0.07, blue: 0.06, alpha: 1).cgColor
            layer?.borderColor = BoardTheme.alert.cgColor
        } else if isUnknown {
            // Unknown reads as inert grey, NOT a full/empty bar (edge case #2).
            layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
            layer?.borderColor = BoardTheme.hairline.cgColor
        } else {
            layer?.backgroundColor = BoardTheme.cardFill.cgColor
            layer?.borderColor = BoardTheme.cardStroke.cgColor
        }
    }

    private func buildContent() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        stack.addArrangedSubview(headerRow())
        stack.addArrangedSubview(barRow())
        stack.addArrangedSubview(remainingRow())
        if !resetLine().isEmpty {
            resetLabel.stringValue = resetLine()
            resetLabel.font = BoardTheme.monoSmall
            resetLabel.textColor = isExhausted ? BoardTheme.attention : BoardTheme.textFaint
            // The reset/refill line is the longest string in the gauge; wrap it to
            // two lines so the narrower (288pt) pool column never truncates it.
            resetLabel.maximumNumberOfLines = 2
            resetLabel.lineBreakMode = .byWordWrapping
            resetLabel.preferredMaxLayoutWidth = GaugeLayout.rowWidth - 20
            stack.addArrangedSubview(resetLabel)
        }
    }

    /// `interactive (5h + weekly)        estimated` — pool title on the left, the
    /// confidence cue (only when estimated) on the right.
    private func headerRow() -> NSView {
        let row = NSStackView()
        row.spacing = 8
        row.alignment = .centerY
        titleLabel.stringValue = poolTitle()
        titleLabel.font = BoardTheme.monoBold
        titleLabel.textColor = isUnknown ? BoardTheme.textMuted : BoardTheme.textPrimary
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(NSView())   // flexible spacer
        if showsEstimatedCue { row.addArrangedSubview(makeEstimatedBadge()) }
        row.widthAnchor.constraint(equalToConstant: GaugeLayout.rowWidth - 20).isActive = true
        return row
    }

    private func barRow() -> NSView {
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.configure(
            fraction: barFraction(),
            state: gauge.state,
            estimated: showsEstimatedCue
        )
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: GaugeLayout.rowWidth - 20),
            bar.heightAnchor.constraint(equalToConstant: GaugeLayout.barHeight),
        ])
        return bar
    }

    private func remainingRow() -> NSView {
        remainingLabel.stringValue = remainingLine()
        remainingLabel.font = BoardTheme.mono
        remainingLabel.textColor = remainingColor()
        return remainingLabel
    }

    /// The amber "estimated" badge — a visible confidence cue, not false precision
    /// (AC#3). Only built for an estimated gauge.
    private func makeEstimatedBadge() -> NSView {
        estimatedBadge.stringValue = "estimated"
        estimatedBadge.font = BoardTheme.monoSmall
        estimatedBadge.textColor = BoardTheme.attention
        estimatedBadge.wantsLayer = true
        estimatedBadge.layer?.backgroundColor = NSColor(red: 0.28, green: 0.20, blue: 0.06, alpha: 1).cgColor
        estimatedBadge.layer?.cornerRadius = 3
        estimatedBadge.alignment = .center
        return estimatedBadge
    }

    // MARK: - Text projection (faithful to the gauge value)

    private func poolTitle() -> String {
        switch (gauge.provider.lowercased(), gauge.pool.lowercased()) {
        case ("anthropic", "interactive"): return "interactive (5h + weekly)"
        case ("anthropic", "agent_sdk_credit"), ("anthropic", "agent-sdk-credit"):
            return "Agent SDK credit"
        default: return gauge.provider
        }
    }

    /// What the bar fills to. Unknown has no fraction (it draws a hatched/empty
    /// inert bar, not 0% and not 100% — edge case #2).
    private func barFraction() -> Double? {
        isUnknown ? nil : gauge.remainingFraction
    }

    private func remainingLine() -> String {
        if isUnknown { return "unknown / not tracked" }
        if isExhausted { return "exhausted — \(refillNoun())" }
        if let frac = gauge.remainingFraction {
            return "\(Int((frac * 100).rounded()))% remaining"
        }
        if let amount = gauge.remainingAmount {
            let unit = gauge.unit.map { " \($0)" } ?? ""
            return "\(Int(amount.rounded()))\(unit) remaining"
        }
        return "—"
    }

    /// The reset/refill line — the asymmetry surface (edge case #1 / TC-E2E-204):
    /// a monthly hard-stop with NO fallback reads differently from a window/weekly
    /// reset. Empty for an unknown pool (nothing to promise).
    private func resetLine() -> String {
        if isUnknown { return "" }
        let when = gauge.reset.map { " · resets \(QuotaGaugeRow.relative.localizedString(for: $0, relativeTo: Date()))" } ?? ""
        switch gauge.fallback {
        case .none:
            return "monthly hard-stop · no fallback" + when
        case .windowReset:
            return "rolling window — refills as usage ages out" + when
        case .weeklyReset:
            return "weekly reset" + when
        case .unknown:
            return when.isEmpty ? "" : String(when.dropFirst(3))
        }
    }

    private func refillNoun() -> String {
        switch gauge.fallback {
        case .none: return "hard-stop, no fallback"
        case .windowReset: return "waiting on window reset"
        case .weeklyReset: return "waiting on weekly reset"
        case .unknown: return "no refill signal"
        }
    }

    private func remainingColor() -> NSColor {
        if isExhausted { return BoardTheme.alert }
        if isUnknown { return BoardTheme.textMuted }
        return BoardTheme.textPrimary
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        // Pin to English: the rest of the gauge copy ("resets", "rolling window …")
        // is hand-authored English, so the system locale leaking through here
        // produced a half-translated "resets за 29 хв". Match the surrounding UI.
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    private static func makeLabel() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        return field
    }
}

/// The gauge's remaining-capacity bar: a custom-drawn, layer-backed track + fill
/// (no stock control), so it composites faithfully in a screenshot. An unknown
/// pool draws an inert hatched track with no fill — visibly "not tracked", never
/// an implied 0% or 100%.
@MainActor
final class QuotaBar: NSView {
    private let track = CALayer()
    private let fill = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { nil }

    func configure(fraction: Double?, state: QuotaPoolState, estimated: Bool) {
        track.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        track.cornerRadius = GaugeLayout.barHeight / 2
        fill.cornerRadius = GaugeLayout.barHeight / 2
        switch state {
        case .unknown:
            fill.backgroundColor = NSColor.clear.cgColor   // no fill — not tracked
        case .exhausted:
            fill.backgroundColor = BoardTheme.alert.cgColor
        case .active:
            let color = estimated ? BoardTheme.attention : NSColor(red: 0.32, green: 0.70, blue: 0.46, alpha: 1)
            fill.backgroundColor = color.cgColor
        }
        currentFraction = fraction
        currentState = state
        needsLayout = true
    }

    private var currentFraction: Double?
    private var currentState: QuotaPoolState = .active

    override func layout() {
        super.layout()
        track.frame = bounds
        let f = currentState == .exhausted ? 0.0 : (currentFraction ?? 0.0)
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(f), height: bounds.height)
    }
}
