import AppKit
import SichCore
import Testing

@testable import SichApp

/// The WORKING sheen is a drifting band; under Reduce Motion it cannot drift, so
/// it must not exist. The regression this guards: the band was built and sized
/// regardless and only the drift was skipped, which left a frozen smear across
/// the left third of every working card on a Reduce Motion Mac.
@MainActor
@Suite(.serialized)
struct WorkingSheenTests {

    private func working() -> BoardCard {
        BoardCard(sessionID: "w", title: "Redesign", projectDir: "/tmp/p", agent: .claude, state: .running)
    }

    private func gradientLayers(in layer: CALayer?) -> [CAGradientLayer] {
        guard let layer else { return [] }
        return (layer.sublayers ?? []).flatMap { sub -> [CAGradientLayer] in
            (sub is CAGradientLayer ? [sub as! CAGradientLayer] : []) + gradientLayers(in: sub)
        }
    }

    private func mounted(_ card: BoardCard) -> SessionCard {
        let view = SessionCard(card: card, hostState: { _ in .installed })
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 80)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func underReduceMotionAWorkingCardHasNoSheenBand() {
        BoardView.motionOverrideForTesting = false
        defer { BoardView.motionOverrideForTesting = nil }
        #expect(gradientLayers(in: mounted(working()).layer).isEmpty)
    }

    @Test func withMotionAllowedTheSheenDrifts() throws {
        BoardView.motionOverrideForTesting = true
        defer { BoardView.motionOverrideForTesting = nil }
        let band = try #require(gradientLayers(in: mounted(working()).layer).first)
        #expect(band.animation(forKey: "sheen") != nil)
    }

    private func pulseIcon(in view: NSView) -> NSImageView? {
        if let icon = view as? NSImageView, icon.identifier?.rawValue == "duration-working-pulse" { return icon }
        for sub in view.subviews { if let found = pulseIcon(in: sub) { return found } }
        return nil
    }

    /// Reduce Motion keeps a cue, just not a moving one: the glyph breathes in
    /// opacity and never scales.
    @Test func underReduceMotionTheGlyphBreathesWithoutMoving() throws {
        BoardView.motionOverrideForTesting = false
        defer { BoardView.motionOverrideForTesting = nil }
        let icon = try #require(pulseIcon(in: mounted(working())))
        let breathe = try #require(icon.layer?.animation(forKey: "working-breathe") as? CAKeyframeAnimation)
        #expect(breathe.keyPath == "opacity")
        #expect(icon.layer?.animation(forKey: "working-heartbeat") == nil)
    }

    @Test func withMotionAllowedTheGlyphBeats() throws {
        BoardView.motionOverrideForTesting = true
        defer { BoardView.motionOverrideForTesting = nil }
        let icon = try #require(pulseIcon(in: mounted(working())))
        #expect(icon.layer?.animation(forKey: "working-heartbeat") != nil)
        #expect(icon.layer?.animation(forKey: "working-breathe") == nil)
    }

    @Test func aRestingCardNeverCarriesASheen() {
        BoardView.motionOverrideForTesting = true
        defer { BoardView.motionOverrideForTesting = nil }
        let idle = working().with(state: .idle)
        #expect(gradientLayers(in: mounted(idle).layer).isEmpty)
    }
}
