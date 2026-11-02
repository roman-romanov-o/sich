import AppKit
import SichCore

/// The rest screen: the board blurs behind a canvas-tinted veil and the same ring,
/// now 280pt and breathing, counts the break down. Underneath it: how many cards
/// will need you after the break (a count, not the cards — the point is to not
/// read them), how many agents are still working, and one quiet way out. When the
/// break runs out the ring turns to the attention orange and the held cards appear
/// as a tray: picking one drills in and starts the next pomodoro on it.
///
/// Swallows keys and clicks while visible (it is the topmost full-window view under
/// the task switcher) — Esc on the break-over screen ends the break; during the
/// break the "end break early" pill is the deliberate exit.
@MainActor
final class PomodoroRestOverlay: NSView {
    /// A held card as the tray shows it.
    struct TrayRow: Equatable {
        let cardID: UUID
        let project: String
        let title: String
        let waiting: TimeInterval?
    }

    /// "end break early" / "← board" / Esc on the over screen.
    var onEndBreak: (() -> Void)?
    /// A tray row: drill into that card and start the next pomodoro on it.
    var onPickCard: ((UUID) -> Void)?

    private let blur = NSVisualEffectView()
    private let veil = NSView()
    private let card = NSStackView()
    private let halo = CAGradientLayer()
    private let ripples = [CAShapeLayer(), CAShapeLayer()]
    let ring = PomodoroRingView(diameter: 280)
    private let breath = NSTextField(labelWithString: "")
    private let dots = NSTextField(labelWithString: "")
    private let heldField = NSTextField(labelWithString: "")
    private let agentsRow = NSStackView()
    private let agentsField = NSTextField(labelWithString: "")
    private var agentDots: [NSView] = []
    private let early = RestPill(text: "end break early")
    private let tray = NSStackView()
    private let back = RestPill(text: "← board")
    private(set) var isOver = false
    private var breathingOn = false

    init() {
        super.init(frame: .zero)
        isHidden = true
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Build

    private func build() {
        blur.blendingMode = .withinWindow
        blur.material = .fullScreenUI
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        veil.wantsLayer = true
        veil.themedBackground = BoardTheme.canvas.withAlphaComponent(0.62)
        veil.translatesAutoresizingMaskIntoConstraints = false
        addSubview(veil)
        for full in [blur, veil] {
            NSLayoutConstraint.activate([
                full.leadingAnchor.constraint(equalTo: leadingAnchor),
                full.trailingAnchor.constraint(equalTo: trailingAnchor),
                full.topAnchor.constraint(equalTo: topAnchor),
                full.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        // The halo + ripples sit on a square view behind the ring, inside the card.
        let aura = NSView()
        aura.wantsLayer = true
        aura.translatesAutoresizingMaskIntoConstraints = false
        halo.type = .radial
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        halo.locations = [0, 0.45, 0.7]
        halo.frame = CGRect(x: 0, y: 0, width: 280, height: 280)
        halo.cornerRadius = 140
        aura.layer?.addSublayer(halo)
        for ripple in ripples {
            ripple.frame = halo.frame
            ripple.path = CGPath(ellipseIn: halo.frame.insetBy(dx: 0.5, dy: 0.5), transform: nil)
            ripple.fillColor = nil
            ripple.lineWidth = 1
            ripple.opacity = 0
            aura.layer?.addSublayer(ripple)
        }
        aura.addSubview(ring)
        NSLayoutConstraint.activate([
            aura.widthAnchor.constraint(equalToConstant: 280),
            aura.heightAnchor.constraint(equalToConstant: 280),
            ring.centerXAnchor.constraint(equalTo: aura.centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: aura.centerYAnchor),
        ])

        card.orientation = .vertical
        card.alignment = .centerX
        card.spacing = 14
        card.edgeInsets = NSEdgeInsets(top: 36, left: 48, bottom: 36, right: 48)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])

        card.addArrangedSubview(aura)
        configure(breath, font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                  color: BoardTheme.textPrimary.withAlphaComponent(0.6))
        card.addArrangedSubview(breath)
        configure(dots, font: .systemFont(ofSize: 11), color: BoardTheme.textFaint)
        card.addArrangedSubview(dots)
        configure(heldField, font: .systemFont(ofSize: 14), color: BoardTheme.textPrimary)
        heldField.alignment = .center
        heldField.lineBreakMode = .byWordWrapping
        heldField.maximumNumberOfLines = 2
        heldField.preferredMaxLayoutWidth = 400
        card.addArrangedSubview(heldField)

        agentsRow.orientation = .horizontal
        agentsRow.alignment = .centerY
        agentsRow.spacing = 8
        configure(agentsField, font: .systemFont(ofSize: 13), color: BoardTheme.textPrimary.withAlphaComponent(0.7))
        let live = NSStackView()
        live.orientation = .horizontal
        live.spacing = 5
        agentDots = (0..<4).map { _ in
            let dot = NSView()
            dot.wantsLayer = true
            dot.themedBackground = BoardTheme.textFaint
            dot.layer?.cornerRadius = 3
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])
            live.addArrangedSubview(dot)
            return dot
        }
        agentsRow.addArrangedSubview(live)
        agentsRow.addArrangedSubview(agentsField)
        card.addArrangedSubview(agentsRow)

        early.onClick = { [weak self] in self?.onEndBreak?() }
        card.addArrangedSubview(early)

        tray.orientation = .vertical
        tray.spacing = 6
        tray.translatesAutoresizingMaskIntoConstraints = false
        tray.widthAnchor.constraint(equalToConstant: 400).isActive = true
        card.addArrangedSubview(tray)

        back.onClick = { [weak self] in self?.onEndBreak?() }
        card.addArrangedSubview(back)
    }

    private func configure(_ field: NSTextField, font: NSFont, color: NSColor) {
        field.font = font
        field.textColor = color
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = false
    }

    // MARK: - Render

    /// The number of agents still working, worded.
    static func agentsText(working: Int) -> String {
        "\(working) agent\(working == 1 ? "" : "s") still working underneath"
    }

    /// The held-count line, for the break and for the over screen.
    static func heldText(count: Int, over: Bool) -> String {
        let tasks = "\(count) task\(count == 1 ? "" : "s")"
        if over {
            return count > 0
                ? "\(tasks) asked for you meanwhile — pick one to start the next pomodoro on it"
                : "Nothing asked for you. Pick a card and start the next one."
        }
        return count > 0 ? "\(tasks) will need you after the break" : "nothing needs you"
    }

    /// "breathe in" for the first half of each 8-second cycle, "breathe out" for the rest.
    static func breathText(elapsed: TimeInterval) -> String {
        elapsed.truncatingRemainder(dividingBy: 8) < 4 ? "BREATHE IN" : "BREATHE OUT"
    }

    /// Show, hide or repaint. `held` is the tray (only read on the over screen —
    /// during the break only its count is shown); `working` the live agent count.
    func render(state: PomodoroState, held: [TrayRow], working: Int) {
        let show = state.isBreak
        guard show else {
            if !isHidden {
                isHidden = true
                stopBreathing()
            }
            return
        }
        let wasHidden = isHidden
        isHidden = false
        isOver = state.breakOver
        ring.apply(state)
        dots.attributedStringValue = NSAttributedString(
            string: PomodoroDock.dotsText(state),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .kern: 6, .foregroundColor: BoardTheme.textFaint])
        heldField.stringValue = Self.heldText(count: held.count, over: isOver)

        breath.isHidden = isOver
        agentsRow.isHidden = isOver
        early.isHidden = isOver
        tray.isHidden = !isOver
        back.isHidden = !isOver

        if isOver {
            stopBreathing()
            renderTray(held)
            startGlow()
        } else {
            let elapsed = state.total - state.remaining
            breath.attributedStringValue = NSAttributedString(
                string: Self.breathText(elapsed: elapsed),
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .kern: 3,
                             .foregroundColor: BoardTheme.textPrimary.withAlphaComponent(0.6)])
            agentsField.stringValue = Self.agentsText(working: working)
            for (index, dot) in agentDots.enumerated() { dot.isHidden = index >= min(working, 4) }
            ring.layer?.removeAnimation(forKey: "glow")
            if !breathingOn { startBreathing() }
        }
        if wasHidden { window?.makeFirstResponder(self) }
    }

    private func renderTray(_ held: [TrayRow]) {
        tray.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in held {
            let view = TrayRowView(row: row)
            view.onPick = { [weak self] in self?.onPickCard?($0) }
            tray.addArrangedSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: tray.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: tray.trailingAnchor),
            ])
        }
    }

    // MARK: - Motion

    /// The halo swells and the ripples run out on the 8-second breath; the live dots
    /// beat. All of it is Core Animation on otherwise static layers, and none of it
    /// runs under Reduce Motion.
    private func startBreathing() {
        breathingOn = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let running = BoardTheme.textFaint
            halo.colors = [running.withAlphaComponent(0.20).cgColor,
                           running.withAlphaComponent(0.07).cgColor,
                           NSColor.clear.cgColor]
            for ripple in ripples { ripple.strokeColor = BoardTheme.textFaint.cgColor }
        }
        halo.opacity = 1
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let swell = CABasicAnimation(keyPath: "transform.scale")
        swell.fromValue = 0.92
        swell.toValue = 1.1
        swell.duration = 4
        swell.autoreverses = true
        swell.repeatCount = .infinity
        swell.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        halo.add(swell, forKey: "breathe")
        for (index, ripple) in ripples.enumerated() {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1
            grow.toValue = 1.5
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.5, 0]
            fade.keyTimes = [0, 0.15, 1]
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = 8
            group.beginTime = CACurrentMediaTime() + Double(index) * 4
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.6, 0.3, 1)
            ripple.add(group, forKey: "ripple")
        }
        for (index, dot) in agentDots.enumerated() {
            let beat = CABasicAnimation(keyPath: "opacity")
            beat.fromValue = 1
            beat.toValue = 0.3
            beat.duration = 0.9
            beat.autoreverses = true
            beat.repeatCount = .infinity
            beat.beginTime = CACurrentMediaTime() + Double(index) * 0.3
            dot.layer?.add(beat, forKey: "beat")
        }
    }

    private func stopBreathing() {
        breathingOn = false
        halo.removeAllAnimations()
        halo.opacity = 0
        for ripple in ripples { ripple.removeAllAnimations(); ripple.opacity = 0 }
        for dot in agentDots { dot.layer?.removeAnimation(forKey: "beat") }
    }

    /// Break over: the orange ring pulses until you pick a card or go back.
    private func startGlow() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        guard ring.layer?.animation(forKey: "glow") == nil else { return }
        let glow = CABasicAnimation(keyPath: "opacity")
        glow.fromValue = 0.55
        glow.toValue = 1
        glow.duration = 1.6
        glow.autoreverses = true
        glow.repeatCount = .infinity
        glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.layer?.add(glow, forKey: "glow")
    }

    // MARK: - Input

    /// Keys stop here: the board underneath is not for working right now. Esc on the
    /// over screen is "← board".
    override func keyDown(with event: NSEvent) {
        if isOver, event.keyCode == 53 { onEndBreak?() }
    }

    override func mouseDown(with event: NSEvent) {}

    // Test seams.
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var heldTextForTesting: String { heldField.stringValue }
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var agentsTextForTesting: String { agentsField.stringValue }
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var earlyPillForTesting: RestPill { early }
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var backPillForTesting: RestPill { back }
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var trayRowsForTesting: [TrayRowView] { tray.arrangedSubviews.compactMap { $0 as? TrayRowView } }
}

/// The rest screen's two text pills ("end break early", "← board") — the
/// ``BackPill`` idiom: a single layer-backed text field with a hairline border.
@MainActor
final class RestPill: NSTextField {
    var onClick: (() -> Void)?

    init(text: String) {
        super.init(frame: .zero)
        useCenteredTextCell()
        stringValue = text
        font = BoardTheme.mono
        textColor = BoardTheme.textPrimary.withAlphaComponent(0.7)
        alignment = .center
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        themedBorder = BoardTheme.hairline
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 20
        size.height = 26
        return size
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// One held card on the break-over tray: project · title · "waiting Xm".
@MainActor
final class TrayRowView: NSView {
    /// The row was picked; carries the card it stands for.
    var onPick: ((UUID) -> Void)?
    let row: PomodoroRestOverlay.TrayRow

    init(row: PomodoroRestOverlay.TrayRow) {
        self.row = row
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        themedBackground = BoardTheme.cardFill
        themedBorder = BoardTheme.cardStroke
        layer?.borderWidth = 1
        layer?.cornerRadius = 8

        let project = NSTextField(labelWithString: row.project)
        project.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        project.textColor = BoardTheme.textFaint
        let title = NSTextField(labelWithString: row.title)
        title.font = .systemFont(ofSize: 12)
        title.textColor = BoardTheme.textPrimary
        title.lineBreakMode = .byTruncatingTail
        title.yieldWidthToWindow()
        let wait = NSTextField(labelWithString: row.waiting.map { "waiting \(PomodoroFormat.minutes($0))" } ?? "waiting")
        wait.font = .systemFont(ofSize: 10, weight: .semibold)
        wait.textColor = BoardTheme.needs
        let spring = NSView()
        spring.setContentHuggingPriority(.init(1), for: .horizontal)
        for field in [project, title, wait] {
            field.isBezeled = false
            field.drawsBackground = false
            field.isEditable = false
            field.isSelectable = false
        }
        let line = NSStackView(views: [project, title, spring, wait])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 10
        line.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onPick?(row.cardID) }
}
