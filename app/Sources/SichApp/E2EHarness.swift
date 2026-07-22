import AppKit
import Foundation
import SichCore

/// A self-driving, ON-SCREEN end-to-end smoke of the assembled `sich` app.
///
/// Why this exists: the unit + headless view-model suites can be fully green while
/// the real binary is unusable — the iter-2 black-terminal drill-in shipped with the
/// suite green, because nothing else launches the REAL product, orders its window on
/// screen, and looks at it. This does: it boots the full stack (window + native
/// in-process poll), asserts the integration invariants no unit can see (including
/// the post-cutover "no python child, no sidecar-port listener" guard), drives a
/// drill-in + return, and captures FAITHFUL on-screen screenshots of each surface.
///
/// It is NOT a pixel-AC auto-pass: the screenshots are boot evidence + design
/// feedback input, never a green checkmark. The machine `checks` are the gate
/// (exit 0 = all passed, 1 = a real integration defect). Triggered only by
/// `SICH_E2E=1`; a normal launch never constructs it.
@MainActor
final class E2EHarness {
    private let shell: BoardShell
    private let window: NSWindow
    private let outDir: URL
    private var checks: [Check] = []
    private var shots: [Shot] = []

    init(shell: BoardShell, window: NSWindow) {
        self.shell = shell
        self.window = window
        let root = RepoLocator.repoRoot()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        self.outDir = root.appendingPathComponent("app/.artifacts/e2e")
    }

    /// Run the scripted smoke across surfaces, writing screenshots + `result.json`
    /// and exiting with the machine-gate verdict. Staged via `after()` rather than
    /// `sleep` so the run loop keeps drawing (a blocked main thread = blank capture).
    func run() {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        captureBoard()
    }

    // MARK: - Stages

    private func captureBoard() {
        window.display()
        shots.append(capture("01-board"))
        checks.append(Check("window_on_screen", window.isVisible))
        checks.append(Check("board_has_cards", !shell.cards.isEmpty, "\(shell.cards.count) cards"))
        checks.append(quotaCheck())
        // Single-binary end state (TC-E2E-301/302): the running app has zero python
        // children and nothing is listening on the old sidecar port.
        checks.append(Check("no_python_child", !CutoverGuard.hasPythonChild(), "child PIDs of this app"))
        let port = CutoverGuard.sidecarPort
        checks.append(Check("no_sidecar_port", !CutoverGuard.portInUse(port), "sidecar port free"))
        after(0.2) { self.captureDrillIn() }
    }

    private func captureDrillIn() {
        guard let first = shell.cards.first else { return finish() }
        shell.drill(into: first)
        // Seed real ANSI colour through the live shell so the captured terminal shot
        // exercises the colour path end-to-end (PTY → emulator → CG draw), not just a
        // monochrome prompt — this is the artifact the visual sign-off looks at.
        shell.e2eSend(Array("printf '\\033[31mRED \\033[32mGREEN \\033[34mBLUE\\033[0m colour-check\\n'\n".utf8), into: first)
        window.contentView?.layoutSubtreeIfNeeded()
        window.display()
        // Give the read loop time to pump the shell's output and paint a frame before
        // the screenshot — otherwise an unpainted terminal reads as breakage when it's
        // just timing.
        after(0.9) {
            self.shots.append(self.capture("02-drillin-terminal"))
            self.checks.append(Check("drillin_shown", !self.shell.drillIn.isHidden))
            self.captureBack()
        }
    }

    private func captureBack() {
        shell.returnToBoard()
        window.display()
        after(0.3) {
            self.shots.append(self.capture("03-back-to-board"))
            self.checks.append(Check(
                "returned_to_board",
                self.shell.drillIn.isHidden && !self.shell.boardView.isHidden))
            self.finish()
        }
    }

    private func finish() {
        write()
        report()
        shell.e2eTeardown()
        exit(checks.allSatisfy { $0.passed } ? 0 : 1)
    }

    // MARK: - Checks

    private func quotaCheck() -> Check {
        let rows = shell.quota.rows
        let live = rows.filter { !$0.isUnknown }.count
        // Gauges must render; "unknown" is a legitimate honest state (a quota source
        // can be genuinely unavailable), so we don't fail on all-unknown — we report
        // the live count so a silently-dead wire is still visible (no silent zero).
        return Check("quota_rendered", !rows.isEmpty, "\(rows.count) gauges, \(live) live")
    }

    // MARK: - Capture

    /// Both paths are faithful here — our terminal renders via Core Graphics in
    /// `draw(_:)` (no GPU/Metal surface), so `cacheDisplay` reproduces the glyphs,
    /// colours and cursor exactly (proven: the drill-in shot shows the real prompt +
    /// coloured cursor). We still PREFER `screencapture` when Screen Recording is
    /// granted: it grabs the genuinely composited on-screen window (the gold
    /// standard, and future-proof if any layer ever goes GPU-backed). Without that
    /// permission `screencapture` just fails and we fall back — no quality loss.
    private func capture(_ name: String) -> Shot {
        let path = outDir.appendingPathComponent("\(name).png")
        let forced = ProcessInfo.processInfo.environment["SICH_CAPTURE"]
        if forced != "layer", screencaptureWindow(to: path), fileNonEmpty(path) {
            return Shot(name: name, path: path.path, method: "screencapture (composited window)")
        }
        // Permission-free fallback. Our whole UI draws via Core Graphics in `draw(_:)`
        // into layer-backed views, so rendering the content view's layer tree
        // (`CALayer.render`) reproduces every glyph/colour/cursor faithfully — no
        // Screen Recording grant needed. (Window-level `cacheDisplay` does NOT
        // composite layer-backed subviews, which is why the terminal came out blank.)
        if layerRenderPNG(to: path) {
            return Shot(name: name, path: path.path,
                        method: "layer-render (permission-free; grant Screen Recording for the composited path)")
        }
        return Shot(name: name, path: path.path, method: "FAILED")
    }

    private func screencaptureWindow(to path: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(window.windowNumber)", path.path]
        // Swallow its stderr: without Screen Recording permission it prints
        // "could not create image from window" and we fall back to the layer-render
        // path intentionally — that diagnostic reads as a failure when it isn't one.
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    /// Render the content view's layer tree into a bitmap. Faithful for our UI
    /// (every surface is a custom `draw(_:)` into a layer-backed view, not a stock
    /// NSControl) and needs no Screen Recording permission, so the visual artifact
    /// exists on any machine — CI included.
    private func layerRenderPNG(to path: URL) -> Bool {
        guard let view = window.contentView, let layer = view.layer,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        layer.render(in: ctx.cgContext)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: path)) != nil
    }

    private func fileNonEmpty(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return false }
        return size > 1024
    }

    // MARK: - Output

    private func write() {
        let obj: [String: Any] = [
            "all_passed": checks.allSatisfy { $0.passed },
            "checks": checks.map { ["name": $0.name, "passed": $0.passed, "detail": $0.detail] },
            "screenshots": shots.map { ["name": $0.name, "path": $0.path, "method": $0.method] },
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: outDir.appendingPathComponent("result.json"))
    }

    private func report() {
        print("---- sich E2E smoke ----")
        for c in checks {
            let tail = c.detail.isEmpty ? "" : " — \(c.detail)"
            print("  [\(c.passed ? "PASS" : "FAIL")] \(c.name)\(tail)")
        }
        for s in shots { print("  shot \(s.name): \(s.path) (\(s.method))") }
        let failed = checks.filter { !$0.passed }.map(\.name)
        print(failed.isEmpty ? "ALL MACHINE GATES PASSED" : "FAILED: \(failed.joined(separator: ", "))")
        print("-----------------------------")
    }

    private func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { work() }
    }

    private struct Check {
        let name: String
        let passed: Bool
        let detail: String
        init(_ name: String, _ passed: Bool, _ detail: String = "") {
            self.name = name
            self.passed = passed
            self.detail = detail
        }
    }

    private struct Shot {
        let name: String
        let path: String
        let method: String
    }
}
