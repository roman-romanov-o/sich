import AppKit
import SichCore

/// One quota pool rendered as a compact usage-table cell. It still represents
/// exactly one ``QuotaGauge``; the surrounding panel decides which provider row
/// and window column the cell appears in.
@MainActor
public final class QuotaGaugeRow: NSView {
    public let gauge: QuotaGauge

    public var showsEstimatedCue: Bool { gauge.confidence == .estimated }
    public var isExhausted: Bool { gauge.state == .exhausted }
    public var isUnknown: Bool { gauge.state == .unknown }
    var capacityTone: QuotaCapacityTone {
        if isUnknown { return .unknown }
        if isExhausted { return .critical }
        guard let fraction = gauge.remainingFraction else { return .healthy }
        if fraction < 0.20 { return .critical }
        if fraction <= 0.50 { return .constrained }
        return .healthy
    }

    private let bar = QuotaBar()
    private let titleLabel = QuotaGaugeRow.makeLabel()
    private let remainingLabel = QuotaGaugeRow.makeLabel()
    private let resetLabel = QuotaGaugeRow.makeLabel()

    public init(gauge: QuotaGauge) {
        self.gauge = gauge
        super.init(frame: .zero)
        wantsLayer = true
        buildContent()
    }

    public required init?(coder: NSCoder) { nil }

    public var remainingText: String {
        if isUnknown { return "unknown / not tracked" }
        if isExhausted { return "exhausted" }
        return remainingLabel.stringValue
    }
    /// What the reset line actually displays — reflects the latest `refreshReset`
    /// tick, not a fresh recompute, so it stays faithful to what's on screen.
    public var resetText: String { resetLabel.stringValue }
    /// The percent as drawn *inside* the bar, read back off the bar's own text layer.
    public var barLabelText: String { bar.labelText }
    public var titleText: String { titleLabel.stringValue }

    private func buildContent() {
        titleLabel.stringValue = poolTitle()
        titleLabel.isHidden = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        bar.configure(
            fraction: barFraction(),
            state: gauge.state,
            tone: capacityTone,
            label: barLabel()
        )
        bar.widthAnchor.constraint(equalToConstant: QuotaLayout.cellWidth).isActive = true
        bar.heightAnchor.constraint(equalToConstant: QuotaLayout.barHeight).isActive = true
        bar.toolTip = barTooltip()
        stack.addArrangedSubview(bar)

        // The percent now rides *inside* the bar (phone-battery style), so this label
        // exists only as the machine-readable state text behind `remainingText`.
        remainingLabel.stringValue = remainingLine()
        remainingLabel.isHidden = true

        resetLabel.textColor = BoardTheme.textMuted
        resetLabel.lineBreakMode = .byTruncatingTail
        resetLabel.toolTip = poolTitle()
        stack.addArrangedSubview(resetLabel)
        refreshReset()
    }

    /// Re-evaluate the reset countdown against the current clock — the panel ticks
    /// this each minute so "resets in 2h 14m" stays live without a full re-render.
    public func refreshReset(now: Date = Date()) {
        resetLabel.stringValue = resetLine(now: now)
        resetLabel.isHidden = resetLabel.stringValue.isEmpty
        resetLabel.font = resetIsHot(now: now) ? BoardTheme.numericSmallStrong : BoardTheme.numericSmall
    }

    private func poolTitle() -> String {
        switch (gauge.provider.lowercased(), normalized(gauge.pool)) {
        case ("anthropic", "interactive"):
            return "interactive (5h + weekly)"
        case ("anthropic", "interactive_5h"):
            return "interactive 5h"
        case ("anthropic", "interactive_weekly"):
            return "interactive weekly"
        case ("anthropic", "agent_sdk_credit"):
            return "Agent SDK credit"
        default:
            return gauge.provider
        }
    }

    private func barFraction() -> Double? {
        isUnknown ? nil : gauge.remainingFraction
    }

    private func remainingLine() -> String {
        if isUnknown { return "" }
        if isExhausted { return "" }
        if let frac = gauge.remainingFraction {
            // "~" rather than an " est" suffix: inside a 94 pt bar the suffix was long
            // enough to hang past the fill edge, and the tilde says "approximate" in one
            // glyph. The estimated cue is still doubled by the amber fill + the tooltip —
            // an inferred number must never read as a measured one.
            let prefix = showsEstimatedCue ? "~" : ""
            return "\(prefix)\(Int((frac * 100).rounded()))%"
        }
        if let amount = gauge.remainingAmount {
            let unit = gauge.unit.map { " \($0)" } ?? ""
            return "\(Int(amount.rounded()))\(unit)"
        }
        return "measuring"
    }

    /// The countdown line — the whole point of the cell's second row: `"in 2h 14m"`,
    /// `"back in 1d 6h"` when exhausted, `"refills in 12d"` for an SDK credit. It carries
    /// no `window`/`weekly` prefix: the column header above it already says which window
    /// this is, and at 94 pt the prefix pushed the countdown itself into the ellipsis.
    /// An unknown pool has nothing to count down, so the line is empty.
    private func resetLine(now: Date = Date()) -> String {
        guard !isUnknown, let reset = gauge.reset else { return "" }
        return resetPhrase(left: QuotaCountdown.timeLeft(to: reset, from: now))
    }

    /// The verb carries the hard-stop-vs-window asymmetry now that the prefix is gone:
    /// a monthly credit *refills* (no fallback — you are stuck until it does), while a
    /// rolling window just counts down, or reads as when you're unblocked once exhausted.
    private func resetPhrase(left: String) -> String {
        if gauge.fallback == .none { return "refills in \(left)" }
        return isExhausted ? "back in \(left)" : "in \(left)"
    }

    /// A countdown that matters now — exhausted (you are waiting on exactly this
    /// reset) or imminent — is lifted by weight, not hue: the panel stays neutral
    /// and the board keeps its one red. A distant reset stays calm but *legible*.
    private func resetIsHot(now: Date = Date()) -> Bool {
        guard let reset = gauge.reset else { return false }
        if isExhausted { return true }
        switch QuotaCountdown.urgency(to: reset, from: now) {
        case .imminent, .soon: return true
        case .distant: return false
        }
    }

    /// The cell is terse by design, so hovering spells out what it is: which pool, and
    /// whether the number was measured or inferred (the `~`).
    private func barTooltip() -> String {
        let title = poolTitle()
        if isUnknown { return "\(title) — not tracked" }
        return showsEstimatedCue ? "\(title) — estimated, not measured" : title
    }

    /// What the bar itself reads out. Exhausted is the one case the fraction can't carry
    /// on its own — an empty green bar and a full red one both need the number spelled out.
    private func barLabel() -> String {
        if isUnknown { return "n/a" }
        if isExhausted { return "0%" }
        return remainingLine()
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    private static func makeLabel() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        return field
    }
}

enum QuotaCapacityTone: Equatable {
    case healthy
    case constrained
    case critical
    case unknown
}

/// A pool's bar: a recessed track with a hairline ring, a translucent neutral fill
/// whose density says healthy / low / spent, and the percent riding inside.
@MainActor
final class QuotaBar: NSView, ThemeReapplying {
    private let track = CALayer()
    private let fill = CALayer()
    /// The fill is a translucent wash of the text ink, so one pass of the label in
    /// that same ink reads on both the track and the fill.
    private let label = QuotaBar.makeTextLayer()
    private var currentFraction: Double?
    private var currentState: QuotaPoolState = .active
    private var currentTone: QuotaCapacityTone = .healthy

    var labelText: String { label.string as? String ?? "" }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        track.borderWidth = 1
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        layer?.addSublayer(label)
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        fraction: Double?, state: QuotaPoolState,
        tone: QuotaCapacityTone, label text: String
    ) {
        track.cornerRadius = QuotaLayout.barCornerRadius
        fill.cornerRadius = QuotaLayout.barCornerRadius
        currentFraction = fraction
        currentState = state
        currentTone = tone
        label.string = text
        applyColors()
        needsLayout = true
    }

    private static func makeTextLayer() -> CATextLayer {
        let text = CATextLayer()
        text.font = BoardTheme.gaugeLabel
        text.fontSize = BoardTheme.gaugeLabel.pointSize
        // Left-aligned, not centred: a centred number sits exactly where the fill edge
        // lands at mid-range fractions, so the boundary splits the glyphs into two
        // colours. Pinned left, a realistic reading (a near-full bar, or a low one) puts
        // the whole number cleanly on one side.
        text.alignmentMode = .left
        text.truncationMode = .end
        text.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        return text
    }

    /// The gauge draws into raw sublayers, which can't hold a `themedBackground` for the
    /// appearance walk to re-resolve — so it repaints on demand instead, from the state
    /// and capacity tone the last ``configure(fraction:state:tone:label:)`` recorded.
    func reapplyTheme(under appearance: NSAppearance) { applyColors(under: appearance) }

    /// A CALayer keeps the plain `cgColor` it was handed, so these are resolved against
    /// the appearance in force *now* rather than whenever the gauge was last configured.
    /// Mid-flip the walk hands the new appearance in, since `effectiveAppearance` hasn't
    /// caught up yet.
    private func applyColors(under appearance: NSAppearance? = nil) {
        (appearance ?? effectiveAppearance).performAsCurrentDrawingAppearance {
            track.backgroundColor = BoardTheme.gaugeTrack.cgColor
            track.borderColor = BoardTheme.gaugeRing.cgColor
            label.foregroundColor =
                (currentState == .unknown ? BoardTheme.textFaint : BoardTheme.textPrimary).cgColor
            switch currentState {
            case .unknown: fill.backgroundColor = NSColor.clear.cgColor
            case .exhausted: fill.backgroundColor = BoardTheme.gaugeFill(.critical).cgColor
            case .active: fill.backgroundColor = BoardTheme.gaugeFill(currentTone).cgColor
            }
        }
    }

    override func layout() {
        super.layout()
        track.frame = bounds
        let f = currentState == .exhausted ? 1.0 : max(0.0, min(currentFraction ?? 0.0, 1.0))
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(f), height: bounds.height)
        label.frame = centeredTextFrame()
    }

    private func centeredTextFrame() -> NSRect {
        let height = ceil(BoardTheme.gaugeLabel.pointSize * 1.2)
        let inset = QuotaLayout.barTextInset
        return NSRect(
            x: inset, y: ((bounds.height - height) / 2).rounded(),
            width: bounds.width - inset * 2, height: height
        )
    }
}
