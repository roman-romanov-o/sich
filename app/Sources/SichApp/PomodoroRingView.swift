import AppKit
import SichCore

/// The pomodoro's one drawing — a dial of 25 minute-ticks around a round-capped arc
/// that unwinds from the top as the phase runs out, the digits and phase word inside.
/// It is used at three sizes (the quota dock, the compact bottom dock, the rest screen)
/// and in six looks: *idle* (dashed track, no arc), *work* (the running gray that
/// drifts to the attention orange over the last three minutes), *paused* (a thin
/// dashed arc), *break* (a thin dim arc), *hold* (orange — the break waits for ↵) and
/// *over* (orange, pulsing on the rest screen).
///
/// Drawn with `CAShapeLayer`s, not `draw(_:)`: the arc updates once a second and a
/// layer property change is cheaper than repainting a 280pt circle. Implicit layer
/// animations are disabled around every update so the arc steps instead of easing —
/// the operator asked for a clock that does not call attention to itself. The dial's
/// colours are resolved under the view's appearance and re-resolved on a light/dark
/// flip through ``ThemeReapplying``.
@MainActor
final class PomodoroRingView: NSView, ThemeReapplying {
    /// How the dial reads; derived from the engine state by ``look(for:)``.
    enum Look: Equatable {
        case idle
        /// `attention` = 0…1, how far the arc has drifted to orange (last 3 min).
        case work(attention: Double)
        case paused
        case rest
        case hold
        case over
    }

    /// Invoked on click anywhere on the dial — start / pause / resume.
    var onClick: (() -> Void)?

    let diameter: CGFloat
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let head = CAShapeLayer()
    private var ticks: [CAShapeLayer] = []
    private let digits = NSTextField(labelWithString: "25:00")
    private let phaseLabel = NSTextField(labelWithString: "")
    private(set) var look: Look = .idle
    private var fraction: Double = 1
    private var minutesLeft = 0
    private var tickCount = 25
    private let showsPhase: Bool

    /// Scale relative to the prototype's 224-unit viewBox (ring radius 100).
    private var unit: CGFloat { diameter / 224 }
    private var radius: CGFloat { 100 * unit }
    private var center: CGPoint { CGPoint(x: diameter / 2, y: diameter / 2) }

    /// `showsPhase: false` for the compact bottom dock, which has no room for the word.
    init(diameter: CGFloat, showsPhase: Bool = true) {
        self.diameter = diameter
        self.showsPhase = showsPhase
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        buildLayers()
        buildText()
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
        ])
        reapplyTheme(under: effectiveAppearance)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    // MARK: - Build

    private func buildLayers() {
        guard let layer else { return }
        let circle = Self.circlePath(center: center, radius: radius)
        for shape in [track, arc] {
            shape.path = circle
            shape.fillColor = nil
            shape.lineCap = .round
            layer.addSublayer(shape)
        }
        track.lineWidth = 3 * unit
        arc.lineWidth = 6 * unit
        head.fillColor = nil
        head.path = CGPath(ellipseIn: CGRect(x: -4 * unit, y: -4 * unit, width: 8 * unit, height: 8 * unit), transform: nil)
        layer.addSublayer(head)
        rebuildTicks(count: tickCount)
    }

    /// One short radial stroke per minute of the phase; every fifth a little longer.
    private func rebuildTicks(count: Int) {
        ticks.forEach { $0.removeFromSuperlayer() }
        ticks = (0..<count).map { index in
            let angle = CGFloat.pi / 2 - 2 * .pi * CGFloat(index) / CGFloat(count)
            let inner = radius + 8 * unit
            let outer = radius + 12 * unit + (index % 5 == 0 ? 3 * unit : 0)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
            path.addLine(to: CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
            let tick = CAShapeLayer()
            tick.path = path
            tick.lineWidth = 1.2 * unit
            tick.lineCap = .round
            tick.fillColor = nil
            layer?.addSublayer(tick)
            return tick
        }
    }

    private func buildText() {
        digits.font = .monospacedSystemFont(ofSize: (diameter * 0.2).rounded(), weight: .semibold)
        digits.alignment = .center
        digits.isBezeled = false
        digits.drawsBackground = false
        digits.isEditable = false
        digits.isSelectable = false
        digits.translatesAutoresizingMaskIntoConstraints = false
        phaseLabel.font = .monospacedSystemFont(ofSize: diameter >= 240 ? 13 : 12, weight: .regular)
        phaseLabel.alignment = .center
        phaseLabel.isBezeled = false
        phaseLabel.drawsBackground = false
        phaseLabel.isEditable = false
        phaseLabel.isSelectable = false
        phaseLabel.isHidden = !showsPhase
        phaseLabel.translatesAutoresizingMaskIntoConstraints = false
        let inside = NSStackView(views: [digits, phaseLabel])
        inside.orientation = .vertical
        inside.alignment = .centerX
        inside.spacing = 6
        inside.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inside)
        NSLayoutConstraint.activate([
            inside.centerXAnchor.constraint(equalTo: centerXAnchor),
            inside.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// A full circle starting at 12 o'clock and running clockwise, so `strokeEnd`
    /// = the fraction left reads the way a clock face does.
    private static func circlePath(center: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: .pi / 2,
                    endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        return path
    }

    // MARK: - State

    /// The dial's reading of an engine state.
    static func look(for state: PomodoroState) -> Look {
        if state.awaitingReply { return .hold }
        if state.breakOver { return .over }
        switch state.phase {
        case .idle: return .idle
        case .shortBreak, .longBreak: return .rest
        case .work:
            guard state.isRunning else { return .paused }
            let window = PomodoroConstants.attentionWindow
            let drift = max(0, min(1, (window - state.remaining) / window))
            return .work(attention: drift)
        }
    }

    /// The word under the digits.
    static func phaseText(for state: PomodoroState) -> String {
        if state.awaitingReply { return "break waits for ↵" }
        if state.breakOver { return "break over" }
        switch state.phase {
        case .idle: return "start a pomodoro"
        case .longBreak: return "long break"
        case .shortBreak: return "break"
        case .work: return state.isRunning ? "focus" : "paused"
        }
    }

    /// Repaint from the engine state. Cheap enough to call once a second.
    func apply(_ state: PomodoroState) {
        look = Self.look(for: state)
        let idle = state.phase == .idle
        fraction = idle ? 1 : state.fraction
        let total = idle ? PomodoroConstants.work : state.total
        let count = max(1, Int((total / 60).rounded()))
        if count != tickCount {
            tickCount = count
            rebuildTicks(count: count)
        }
        minutesLeft = idle ? count : Int((state.remaining / 60).rounded(.up))
        digits.stringValue = PomodoroFormat.mmss(idle ? PomodoroConstants.work : state.remaining)
        phaseLabel.attributedStringValue = NSAttributedString(
            string: Self.phaseText(for: state).uppercased(),
            attributes: [.font: phaseLabel.font ?? BoardTheme.mono, .kern: 2,
                         .foregroundColor: phaseLabel.textColor ?? BoardTheme.textMuted])
        toolTip = idle ? "Start a 25-minute pomodoro on the card you're in"
            : state.isRunning ? "Pause" : "Resume"
        reapplyTheme(under: effectiveAppearance)
    }

    /// Resolve every colour for the current look and push geometry + colour into the
    /// layers in one non-animated transaction.
    func reapplyTheme(under appearance: NSAppearance) {
        let look = self.look
        let fraction = self.fraction
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        appearance.performAsCurrentDrawingAppearance {
            let faint = BoardTheme.textFaint
            let arcColor: NSColor
            switch look {
            case .idle: arcColor = faint
            case .work(let attention):
                arcColor = attention > 0
                    ? faint.blended(withFraction: attention, of: BoardTheme.attention) ?? BoardTheme.attention
                    : faint
            case .paused: arcColor = faint
            case .rest: arcColor = BoardTheme.textDim
            case .hold, .over: arcColor = BoardTheme.attention
            }
            track.strokeColor = BoardTheme.gaugeTrack.cgColor
            track.lineDashPattern = look == .idle ? [2 * unit as NSNumber, 6 * unit as NSNumber] : nil
            arc.strokeColor = arcColor.cgColor
            arc.isHidden = look == .idle
            arc.strokeEnd = fraction
            switch look {
            case .paused:
                arc.lineWidth = 3 * unit
                arc.lineDashPattern = [4 * unit as NSNumber, 7 * unit as NSNumber]
            case .rest:
                arc.lineWidth = 3 * unit
                arc.lineDashPattern = nil
            default:
                arc.lineWidth = 6 * unit
                arc.lineDashPattern = nil
            }
            head.fillColor = arcColor.cgColor
            head.isHidden = look == .idle
            let angle = CGFloat.pi / 2 - 2 * .pi * fraction
            head.position = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            for (index, tick) in ticks.enumerated() {
                tick.strokeColor = faint.cgColor
                tick.opacity = (look != .idle && index >= minutesLeft) ? 0.18 : 1
            }
            digits.textColor = look == .idle ? BoardTheme.textFaint : BoardTheme.textPrimary
            let phaseColor: NSColor = switch look {
            case .hold: BoardTheme.attention
            case .idle: BoardTheme.textPrimary.withAlphaComponent(0.55)
            default: BoardTheme.textPrimary.withAlphaComponent(0.78)
            }
            phaseLabel.textColor = phaseColor
            if phaseLabel.attributedStringValue.length > 0 {
                let text = NSMutableAttributedString(attributedString: phaseLabel.attributedStringValue)
                text.addAttribute(.foregroundColor, value: phaseColor,
                                  range: NSRange(location: 0, length: text.length))
                phaseLabel.attributedStringValue = text
            }
        }
        CATransaction.commit()
    }

    // MARK: - Interaction

    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    /// The whole dial is one click target (the labels inside don't steal the hit).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onClick != nil else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    // Test seams.
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var digitsForTesting: String { digits.stringValue }
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var phaseForTesting: String { phaseLabel.attributedStringValue.string }
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var arcFractionForTesting: CGFloat { arc.strokeEnd }
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var arcHiddenForTesting: Bool { arc.isHidden }
}
