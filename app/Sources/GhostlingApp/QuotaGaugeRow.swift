import AppKit
import GhostlingCore

/// One quota pool rendered as a compact usage-table cell. It still represents
/// exactly one ``QuotaGauge``; the surrounding panel decides which provider row
/// and window column the cell appears in.
@MainActor
public final class QuotaGaugeRow: NSView {
    public let gauge: QuotaGauge

    public var showsEstimatedCue: Bool { gauge.confidence == .estimated }
    public var isExhausted: Bool { gauge.state == .exhausted }
    public var isUnknown: Bool { gauge.state == .unknown }

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
            estimated: showsEstimatedCue
        )
        bar.widthAnchor.constraint(equalToConstant: QuotaLayout.cellWidth).isActive = true
        bar.heightAnchor.constraint(equalToConstant: QuotaLayout.barHeight).isActive = true
        stack.addArrangedSubview(bar)

        remainingLabel.stringValue = remainingLine()
        remainingLabel.font = BoardTheme.monoSmall
        remainingLabel.textColor = remainingColor()
        remainingLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(remainingLabel)

        resetLabel.stringValue = resetLine()
        resetLabel.isHidden = resetLabel.stringValue.isEmpty
        resetLabel.font = BoardTheme.monoSmall
        resetLabel.textColor = resetColor()
        resetLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(resetLabel)
    }

    /// Re-evaluate the reset countdown against the current clock — the panel ticks
    /// this each minute so "resets in 2h 14m" stays live without a full re-render.
    public func refreshReset(now: Date = Date()) {
        resetLabel.stringValue = resetLine(now: now)
        resetLabel.isHidden = resetLabel.stringValue.isEmpty
        resetLabel.textColor = resetColor(now: now)
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
            let suffix = showsEstimatedCue ? " est" : ""
            return "\(Int((frac * 100).rounded()))%\(suffix)"
        }
        if let amount = gauge.remainingAmount {
            let unit = gauge.unit.map { " \($0)" } ?? ""
            return "\(Int(amount.rounded()))\(unit)"
        }
        return "measuring"
    }

    /// The highlighted "time left until this limit resets" line — e.g.
    /// `"window · resets in 2h 14m"`, `"weekly · back in 1d 6h"` (exhausted framing),
    /// or `"hard-stop · refills in 12d"` for an SDK credit. The window/weekly/hard-stop
    /// prefix keeps the refill *kind* explicit; the countdown is the new part users
    /// asked to see. An unknown pool has nothing to count down, so the line is empty.
    private func resetLine(now: Date = Date()) -> String {
        if isUnknown { return "" }
        let prefix = resetPrefix()
        guard let reset = gauge.reset else { return prefix }
        let phrase = resetPhrase(left: QuotaCountdown.timeLeft(to: reset, from: now))
        return prefix.isEmpty ? phrase : "\(prefix) · \(phrase)"
    }

    private func resetPrefix() -> String {
        switch gauge.fallback {
        case .none: return "hard-stop"
        case .windowReset: return "window"
        case .weeklyReset: return "weekly"
        case .unknown: return ""
        }
    }

    /// A hard-stop credit *refills*; a rolling window *resets*. When exhausted, frame
    /// either as when you're unblocked ("back in …") — that's the number that matters.
    private func resetPhrase(left: String) -> String {
        if isExhausted { return "back in \(left)" }
        return gauge.fallback == .none ? "refills in \(left)" : "resets in \(left)"
    }

    /// Highlight the countdown when it matters: bright attention while exhausted (you
    /// are waiting on exactly this reset) or when it's imminent/soon; dim otherwise.
    private func resetColor(now: Date = Date()) -> NSColor {
        guard let reset = gauge.reset else { return BoardTheme.textDim }
        if isExhausted { return BoardTheme.attention }
        switch QuotaCountdown.urgency(to: reset, from: now) {
        case .imminent, .soon: return BoardTheme.attention
        case .distant: return BoardTheme.textDim
        }
    }

    private func remainingColor() -> NSColor {
        if isExhausted { return BoardTheme.alert }
        if isUnknown { return BoardTheme.textMuted }
        return BoardTheme.textMuted
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

@MainActor
final class QuotaBar: NSView {
    private let track = CALayer()
    private let fill = CALayer()
    private var currentFraction: Double?
    private var currentState: QuotaPoolState = .active

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { nil }

    func configure(fraction: Double?, state: QuotaPoolState, estimated: Bool) {
        track.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        track.cornerRadius = QuotaLayout.barHeight / 2
        fill.cornerRadius = QuotaLayout.barHeight / 2
        switch state {
        case .unknown:
            fill.backgroundColor = NSColor.clear.cgColor
        case .exhausted:
            fill.backgroundColor = BoardTheme.alert.cgColor
        case .active:
            fill.backgroundColor = (estimated ? BoardTheme.attention : BoardTheme.stateColor(.done)).cgColor
        }
        currentFraction = fraction
        currentState = state
        configureExhaustedAnimation()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        track.frame = bounds
        let f = currentState == .exhausted ? 1.0 : max(0.0, min(currentFraction ?? 0.0, 1.0))
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(f), height: bounds.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureExhaustedAnimation()
    }

    private func configureExhaustedAnimation() {
        fill.removeAnimation(forKey: "exhaustedPulse")
        guard window != nil, currentState == .exhausted else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.55
        animation.toValue = 1.0
        animation.duration = 0.9
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fill.add(animation, forKey: "exhaustedPulse")
    }
}
