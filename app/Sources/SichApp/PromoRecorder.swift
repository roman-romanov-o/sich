import AppKit
import Foundation
import SichCore

/// Records promo footage: drives the real board through a short scripted story on
/// synthetic data and writes one clean 2x PNG per frame, an ffmpeg concat list
/// (`frames.txt`, each frame held for its real on-screen duration) and `beats.json`
/// (when each story beat fired) so the video edit can sync zooms and titles to it.
///
/// Triggered only by `SICH_E2E=1 SICH_PROMO=1` (see `scripts/promo-footage.sh`); the
/// scenario, not the app, moves the cards — every surface shown is the shipped UI.
/// Frames use the same permission-free layer render as ``E2EHarness``.
@MainActor
public final class PromoRecorder {
    private let shell: BoardShell
    private let window: NSWindow
    private let outDir: URL
    private let writers = DispatchQueue(label: "sich.promo.writer", attributes: .concurrent)
    private let inFlight = DispatchSemaphore(value: 8)
    private var frames: [(file: String, at: TimeInterval)] = []
    private var beats: [(name: String, at: TimeInterval)] = []
    private var start = Date()
    private var ticker: Timer?
    /// How far the pomodoro's clock runs ahead of the wall clock (the time-lapse).
    private var skew: TimeInterval = 0

    private static let fps = 24.0
    /// The footage is rendered at this many pixels per point regardless of the
    /// screen, so the edit can zoom in without upscaling.
    private static let scale: CGFloat = 2
    public static let liveTitle = "Add idempotency keys to refunds"

    init(shell: BoardShell, window: NSWindow) {
        self.shell = shell
        self.window = window
        let root = RepoLocator.repoRoot()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        self.outDir = root.appendingPathComponent("app/.artifacts/promo")
    }

    /// The promo board: every card a real terminal in a sibling of `projectDir`, so
    /// the script's fake agent picks its transcript from the directory name. Two
    /// tasks wait in BACKLOG for the moment NEEDS YOU is cleared.
    public static func seeds(projectDir: String) -> [BoardSeed] {
        let home = (projectDir as NSString).deletingLastPathComponent
        func card(_ title: String, _ dir: String, _ agent: CardAgent, _ state: CardState,
                  worked: TimeInterval = 0, current: TimeInterval = 0) -> BoardSeed {
            let path = dir == "payments-api" ? projectDir : (home as NSString).appendingPathComponent(dir)
            let live = BoardSeed.liveTerminal(projectDir: path, sessionID: "promo/\(dir)",
                                              title: title, agent: agent)
            return BoardSeed(sessionID: live.sessionID, title: title, projectDir: path,
                             agent: agent, state: state, scrollback: "",
                             commandOverride: live.command, cardID: live.cardID,
                             accumulatedWorkingTime: worked, currentWorkingTime: current)
        }
        return [
            card(liveTitle, "payments-api", .claude, .running, worked: 72 * 60, current: 6 * 60),
            card("Add OAuth token refresh", "auth-service", .claude, .running, worked: 54 * 60, current: 9 * 60),
            card("Aggregate quota across pools", "quota-aggregation", .claude, .running,
                 worked: 4_320, current: 17 * 60),
            card("Build the settings panel", "desktop-app", .codex, .running, worked: 2 * 3_600, current: 8 * 60),
            card("Export reports to CSV", "reports", .gemini, .runningTests, worked: 45 * 60, current: 32 * 60),
            card("Embed Ghostty focus handling", "ghostty-focus", .claude, .done, worked: 4 * 3_600 + 12 * 60),
            card(backlogTitle, "public-api", .claude, .parked),
            card("Write the onboarding guide", "docs", .cursor, .parked),
        ]
    }

    static let backlogTitle = "Rate-limit the public API"

    func run() {
        try? FileManager.default.removeItem(at: outDir)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        window.setContentSize(NSSize(width: 1440, height: 900))
        guard let live = card(Self.liveTitle) else { return finish() }
        shell.pomodoro.now = { [unowned self] in Date().addingTimeInterval(self.skew) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.start = Date()
            self.ticker = Timer.scheduledTimer(withTimeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.captureFrame() }
            }
            self.play(self.story(live: live.id))
        }
    }

    // MARK: - Story

    private struct Beat {
        let name: String
        let after: TimeInterval
        let action: @MainActor () -> Void
    }

    /// Focus, not firefighting: one pomodoro on one card while the other agents'
    /// questions are held, a time-lapsed run to a real break, the held questions
    /// handed back, answered one by one through ⌃Tab, and — NEEDS YOU empty — the
    /// next task pulled from the backlog.
    private func story(live: UUID) -> [Beat] {
        [
            Beat(name: "board", after: 0) {},
            Beat(name: "focus", after: 2.2) { self.shell.pomodoroRingClicked() },
            Beat(name: "drill-in", after: 2.2) {
                if let card = self.card(id: live) { self.shell.drill(into: card) }
            },
            Beat(name: "type", after: 3.0) { self.type("also log the key on every retry\n", into: live) },
            Beat(name: "interrupt", after: 2.6) {
                self.moveCard("Add OAuth token refresh", to: .waitingForInput)
                self.moveCard("Aggregate quota across pools", to: .waitingForInput)
            },
            Beat(name: "back", after: 2.4) { self.shell.returnToBoard() },
            Beat(name: "timelapse", after: 3.0) {
                self.fastForward(by: PomodoroConstants.work, over: 2.6)
            },
            Beat(name: "rest", after: 2.8) {},
            Beat(name: "break-timelapse", after: 3.0) {
                self.fastForward(by: PomodoroConstants.shortBreak, over: 1.4)
            },
            Beat(name: "tray", after: 1.6) {},
            Beat(name: "release", after: 3.0) { self.shell.pomodoro.endBreak() },
            Beat(name: "switch", after: 2.6) { self.controlTab() },
            Beat(name: "commit", after: 1.6) { self.releaseControl() },
            Beat(name: "answer", after: 1.6) { self.type("1", titled: "Add OAuth token refresh") },
            Beat(name: "switch-2", after: 2.4) {
                self.moveCard("Add OAuth token refresh", to: .running)
                self.controlTab()
            },
            Beat(name: "commit-2", after: 1.2) { self.releaseControl() },
            Beat(name: "answer-2", after: 1.8) { self.type("1", titled: "Aggregate quota across pools") },
            Beat(name: "clear", after: 2.4) {
                self.moveCard("Aggregate quota across pools", to: .running)
                self.shell.returnToBoard()
            },
            Beat(name: "pull", after: 2.8) {
                self.moveCard(Self.backlogTitle, to: .running)
                if let card = self.card(Self.backlogTitle) { self.shell.drill(into: card) }
            },
            Beat(name: "type-3", after: 1.0) {
                self.type("cap each API key at 100 requests a minute\n", titled: Self.backlogTitle)
            },
            Beat(name: "end", after: 4.0) { self.finish() },
        ]
    }

    /// ⌃Tab through the shell's real key monitor path: the switcher opens (or
    /// advances) exactly as it does for a held Control key.
    private func controlTab() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)
        else { return }
        _ = shell.handleTaskSwitchEvent(event)
    }

    /// Letting go of ⌃ commits the highlighted task. `NSEvent.keyEvent` refuses
    /// `.flagsChanged`, so the event is built from a CGEvent.
    private func releaseControl() {
        guard let backing = CGEvent(keyboardEventSource: nil, virtualKey: 0x3B, keyDown: false)
        else { return }
        backing.type = .flagsChanged
        backing.flags = []
        guard let event = NSEvent(cgEvent: backing) else { return }
        _ = shell.handleTaskSwitchEvent(event)
    }

    /// Time-lapse: the pomodoro's clock runs `seconds` ahead over `duration` of real
    /// time, ticked every frame so the ring counts down smoothly.
    private func fastForward(by seconds: TimeInterval, over duration: TimeInterval) {
        let steps = Int(duration * Self.fps)
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) / Self.fps) {
                self.skew += seconds / Double(steps)
                self.shell.pomodoro.tick()
            }
        }
    }

    private func play(_ beats: [Beat]) {
        guard let beat = beats.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + beat.after) {
            self.beats.append((beat.name, Date().timeIntervalSince(self.start)))
            beat.action()
            self.play(Array(beats.dropFirst()))
        }
    }

    private func moveCard(_ title: String, to column: BoardColumn) {
        if let card = card(title) { shell.move(cardID: card.id, to: column) }
    }

    private func type(_ text: String, titled title: String) {
        if let card = card(title) { type(text, into: card.id) }
    }

    /// Types like a person: one character per tick through the card's real PTY.
    private func type(_ text: String, into cardID: UUID) {
        guard let card = card(id: cardID) else { return }
        for (i, ch) in text.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.045) {
                self.shell.e2eSend(Array(String(ch).utf8), into: card)
            }
        }
    }

    private func card(_ title: String) -> BoardCard? { shell.cards.first { $0.title == title } }
    private func card(id: UUID) -> BoardCard? { shell.cards.first { $0.id == id } }

    // MARK: - Frames

    /// Skips a tick rather than queueing unbounded 2x bitmaps when the encoders
    /// fall behind; the concat durations keep the timing honest either way.
    private func captureFrame() {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let image = renderWindow() else { inFlight.signal(); return }
        let name = String(format: "frame-%05d.png", frames.count)
        frames.append((name, Date().timeIntervalSince(start)))
        let url = outDir.appendingPathComponent(name)
        writers.async { [inFlight] in
            Self.writePNG(image, to: url)
            inFlight.signal()
        }
    }

    /// The window's frame view (titlebar included), rendered from its layer tree
    /// into a bitmap of `scale` pixels per point.
    private func renderWindow() -> CGImage? {
        guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer
        else { return nil }
        let size = view.bounds.size
        guard let ctx = CGContext(
            data: nil, width: Int(size.width * Self.scale), height: Int(size.height * Self.scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: Self.scale, y: Self.scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    private nonisolated static func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private func finish() {
        ticker?.invalidate()
        writers.sync(flags: .barrier) {}
        var lines: [String] = []
        for (i, frame) in frames.enumerated() {
            let next = i + 1 < frames.count ? frames[i + 1].at : frame.at + 1 / Self.fps
            lines.append("file '\(frame.file)'")
            lines.append("duration \(String(format: "%.4f", next - frame.at))")
        }
        if let last = frames.last { lines.append("file '\(last.file)'") }
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: outDir.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        let beatJSON = beats.map { ["name": $0.name, "t": ($0.at * 1000).rounded() / 1000] as [String: Any] }
        if let data = try? JSONSerialization.data(withJSONObject: beatJSON, options: [.prettyPrinted]) {
            try? data.write(to: outDir.appendingPathComponent("beats.json"))
        }
        print("promo: \(frames.count) frames, \(beats.count) beats → \(outDir.path)")
        shell.e2eTeardown()
        exit(frames.isEmpty ? 1 : 0)
    }
}
