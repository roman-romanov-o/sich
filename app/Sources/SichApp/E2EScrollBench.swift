import AppKit
import QuartzCore

/// In-app scroll frame-rate probe, run by the E2E harness under `SICH_SCROLLBENCH=1`.
///
/// The unit-level draw probes measure a bitmap context, but the real surface draws
/// into a Core Animation display-list context, so the only honest number is one
/// taken inside the running app: a display link at the screen's native rate posts a
/// real wheel event per refresh, and the run loop is timed from wake-up to the end
/// of the Core Animation commit. A main-thread turn longer than one refresh is a
/// dropped frame the user sees as a hitch.
@MainActor
final class E2EScrollBench {
    private let surface: TerminalSurface
    private let outDir: URL
    private var link: CADisplayLink?
    private var observers: [CFRunLoopObserver] = []
    private var ticks: [CFTimeInterval] = []
    private var turnStart: CFTimeInterval = 0
    private var turns: [Double] = []
    private var finish: ((Result) -> Void)?

    /// Frame count plus the one-line summary; zero frames means the display link
    /// never ticked (screen off), which the harness reports as a failed measurement.
    struct Result {
        let frames: Int
        let summary: String
    }

    init(surface: TerminalSurface, outDir: URL) {
        self.surface = surface
        self.outDir = outDir
    }

    func run(seconds: Double, then finish: @escaping (Result) -> Void) {
        self.finish = finish
        let begin = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue, true, -2_000_000) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.turnStart = CACurrentMediaTime() }
        }
        // Core Animation commits at order 2_000_000 on beforeWaiting; running after
        // it means a turn includes draw(_:) encoding AND the commit.
        let end = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_100_000) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.endTurn() }
        }
        for observer in [begin, end].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
        let link = surface.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.stop() }
    }

    private func endTurn() {
        guard turnStart > 0 else { return }
        turns.append((CACurrentMediaTime() - turnStart) * 1000)
        turnStart = 0
    }

    @objc private func tick() {
        ticks.append(CACurrentMediaTime())
        // Alternate 30 refreshes up, 30 down, 24 trackpad pixels per refresh — a
        // brisk precise swipe, so every frame lands on a sub-row position and the
        // smooth path (fraction + row below) is what gets measured.
        let pixels: Int32 = (ticks.count / 30) % 2 == 0 ? 24 : -24
        guard let backing = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                    wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        backing.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        guard let event = NSEvent(cgEvent: backing) else { return }
        surface.scrollWheel(with: event)
    }

    private func stop() {
        link?.invalidate()
        link = nil
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers.removeAll()
        let summary = report()
        finish?(Result(frames: ticks.count, summary: summary))
        finish = nil
    }

    private func report() -> String {
        let maxFPS = surface.window?.screen?.maximumFramesPerSecond ?? 60
        let nominal = 1000.0 / Double(maxFPS)
        let intervals = zip(ticks.dropFirst(), ticks).map { ($0 - $1) * 1000 }
        let dropped = intervals.filter { $0 > nominal * 1.5 }.count
        let slowTurns = turns.filter { $0 > nominal }.count
        let stats: [String: Any] = [
            "display_max_fps": maxFPS,
            "ticks": ticks.count,
            "achieved_fps": ticks.count > 1 ? Double(ticks.count - 1) / (ticks.last! - ticks.first!) : 0,
            "dropped_frames": dropped,
            "interval_ms": percentiles(intervals),
            "run_loop_turns": turns.count,
            "turns_over_budget": slowTurns,
            "turn_ms": percentiles(turns)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: outDir.appendingPathComponent("scrollbench.json"))
        }
        let fps = stats["achieved_fps"] as? Double ?? 0
        let turnStats = stats["turn_ms"] as? [String: Double] ?? [:]
        guard !ticks.isEmpty else { return "no frames: the display link never fired (display off?)" }
        return String(format: "%.1f fps of %d, %d dropped of %d frames; "
                      + "turn p50 %.2f p95 %.2f max %.2f ms, %d turns over budget",
                      fps, maxFPS, dropped, intervals.count,
                      turnStats["p50"] ?? 0, turnStats["p95"] ?? 0, turnStats["max"] ?? 0, slowTurns)
    }

    private func percentiles(_ values: [Double]) -> [String: Double] {
        guard !values.isEmpty else { return [:] }
        let sorted = values.sorted()
        func at(_ quantile: Double) -> Double {
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * quantile))]
        }
        return ["p50": at(0.5), "p95": at(0.95), "max": sorted.last!]
    }
}
