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
    public var resetText: String { resetLine() }
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
        resetLabel.isHidden = true
        resetLabel.font = BoardTheme.monoSmall
        resetLabel.textColor = BoardTheme.textDim
        resetLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(resetLabel)
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

    private func resetLine() -> String {
        if isUnknown { return "" }
        switch gauge.fallback {
        case .none:
            return resetSuffix(prefix: "hard-stop")
        case .windowReset:
            return resetSuffix(prefix: "window")
        case .weeklyReset:
            return resetSuffix(prefix: "weekly")
        case .unknown:
            return resetSuffix(prefix: "")
        }
    }

    private func resetSuffix(prefix: String) -> String {
        let when = gauge.reset.map { QuotaGaugeRow.relative.localizedString(for: $0, relativeTo: Date()) } ?? ""
        if prefix.isEmpty { return when }
        if when.isEmpty { return prefix }
        return "\(prefix) · \(when)"
    }

    private func remainingColor() -> NSColor {
        if isExhausted { return BoardTheme.alert }
        if isUnknown { return BoardTheme.textMuted }
        return BoardTheme.textMuted
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
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
