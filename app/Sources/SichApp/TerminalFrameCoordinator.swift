import AppKit
import Foundation

/// Why the terminal needs a new frame. Higher-cost reasons subsume lower ones:
/// a viewport shift changes every visible row, while ordinary PTY output can use
/// the existing row damage diff.
enum TerminalRefreshReason: Int, Sendable {
    case output
    case viewport
    case full

    func merged(with other: Self) -> Self {
        rawValue >= other.rawValue ? self : other
    }
}

/// Main-thread pending-work state, split out so coalescing is deterministic and
/// testable without a window or a running display link.
struct TerminalRefreshQueue {
    private(set) var pending: TerminalRefreshReason?

    mutating func request(_ reason: TerminalRefreshReason) {
        pending = pending.map { $0.merged(with: reason) } ?? reason
    }

    mutating func consume() -> TerminalRefreshReason? {
        defer { pending = nil }
        return pending
    }
}

/// Ghostty-style precise scroll normalization. Trackpad deltas are pixels and
/// deliberately receive Ghostty's 2x sensitivity; mouse-wheel deltas are rows.
struct TerminalScrollAccumulator {
    static let preciseMultiplier: CGFloat = 2
    private(set) var residue: CGFloat = 0

    /// A wheel event's motion in rows, continuous — the smooth viewport path
    /// consumes this directly; ``rows(deltaY:precise:cellHeight:)`` quantizes it
    /// for the paths that must emit whole ticks (mouse reports, arrow keys).
    static func rowDelta(deltaY: CGFloat, precise: Bool, cellHeight: CGFloat) -> CGFloat {
        guard cellHeight > 0 else { return 0 }
        return precise ? deltaY * preciseMultiplier / cellHeight : deltaY
    }

    mutating func rows(adding rowDelta: CGFloat) -> Int {
        guard rowDelta != 0 else { return 0 }
        residue += rowDelta
        let rows = Int(residue) // rounds toward zero, preserving sub-row motion
        residue -= CGFloat(rows)
        return rows
    }
}

/// A native-display clock for the terminal surface, built on `NSView.displayLink`
/// (CADisplayLink): it fires on the main run loop at the refresh rate of the
/// display that actually contains the view, and follows the view across displays
/// automatically — a 144Hz screen gets 144 frame slots, not a 60Hz assumption.
///
/// Pacing policy: the link stays running through an output burst (so every
/// display refresh can paint) and only pauses after ``idleFrameGrace`` consecutive
/// frames with no pending work. Stopping after every frame — the previous
/// CVDisplayLink design — paid a link restart plus a cross-thread hop per frame
/// and capped the visible rate far below the display's.
@MainActor
final class TerminalFrameCoordinator {
    private var displayLink: CADisplayLink?
    private let onFrame: @MainActor () -> Bool
    private var idleFrames = 0

    /// Frames with nothing to draw tolerated before pausing (~0.2s at 144Hz).
    /// Long enough to bridge the gaps between PTY chunks in a burst, short
    /// enough that a shell sitting at its prompt costs no steady-state wakeups.
    private static let idleFrameGrace = 30

    init(onFrame: @escaping @MainActor () -> Bool) {
        self.onFrame = onFrame
    }

    // No deinit cleanup: CADisplayLink retains its target, so while a link exists
    // this object cannot deinit — `detach()` (view left the window) is the only
    // place the link is torn down, and it breaks that retain via invalidate().

    /// Bind the clock to `view`'s window display. Idempotent; call again after the
    /// view moves into a window. `CADisplayLink` retains its target, so the link is
    /// invalidated (breaking that retain) whenever the view leaves the window.
    func attach(to view: NSView) {
        guard view.window != nil else {
            detach()
            return
        }
        guard displayLink == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(displayTick))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func detach() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func requestFrame() {
        idleFrames = 0
        guard let displayLink else {
            // Headless (no window, tests): deliver one coalesced frame on the next
            // main-run-loop turn so the update is never lost. Scheduled on the run
            // loop rather than the main dispatch queue because a plain spun run loop
            // — tests, nested AppKit modes — does not necessarily drain that queue.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated { _ = self?.onFrame() }
            }
            return
        }
        displayLink.isPaused = false
    }

    @objc private func displayTick() {
        if onFrame() {
            idleFrames = 0
        } else {
            idleFrames += 1
            if idleFrames >= Self.idleFrameGrace {
                displayLink?.isPaused = true
            }
        }
    }
}
