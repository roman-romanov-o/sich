import AppKit
import SichCore
import Testing

@testable import SichApp

/// The first-launch setup sheet, driven by REAL dispatched events (interaction-AC rule).
@MainActor
private func mount(_ view: NSView) -> NSWindow {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
    view.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        view.topAnchor.constraint(equalTo: root.topAnchor),
        view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = root
    window.makeKeyAndOrderFront(nil)
    root.layoutSubtreeIfNeeded()
    return window
}

@MainActor
private func click(_ view: NSView, in window: NSWindow) throws {
    window.contentView?.layoutSubtreeIfNeeded()
    let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    let hit = try #require(window.contentView?.hitTest(center))
    #expect(hit === view, "the pill must own its own click point")
    window.sendEvent(try #require(NSEvent.mouseEvent(
        with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
}

@MainActor
private func press(_ keyCode: UInt16, in window: NSWindow) {
    window.sendEvent(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: keyCode)!)
}

@MainActor
@Suite("Agent setup sheet")
struct AgentSetupSheetTests {
    @Test("a real click on Install asks for that agent; Return can't start with nothing ready")
    func installClickAndBlockedStart() throws {
        let sheet = AgentSetupSheet(states: [:])
        let window = mount(sheet)
        var installed: [CardAgent] = []
        var started = false
        sheet.onInstall = { installed.append($0) }
        sheet.onStart = { started = true }

        try click(try #require(sheet.rows[.codex]).actionForTesting, in: window)
        #expect(installed == [.codex])
        press(36, in: window)
        #expect(!started, "no agent is ready yet")
    }

    @Test("installing shows live output and disables the pill; ready unlocks Return")
    func progressThenReady() throws {
        let sheet = AgentSetupSheet(states: [.claude: .installing(line: "Downloading 42%")])
        let window = mount(sheet)
        var installs = 0
        var started = false
        sheet.onInstall = { _ in installs += 1 }
        sheet.onStart = { started = true }
        let row = try #require(sheet.rows[.claude])
        #expect(row.detailText == "Downloading 42%")
        try click(row.actionForTesting, in: window)
        #expect(installs == 0, "an install in flight can't be started twice")

        sheet.update([.claude: .ready(path: "/Users/new/.local/bin/claude")])
        #expect(row.actionForTesting.isHidden)
        press(36, in: window)
        #expect(started)
    }

    @Test("Esc skips")
    func escSkips() {
        let sheet = AgentSetupSheet(states: [:])
        let window = mount(sheet)
        var skipped = false
        sheet.onSkip = { skipped = true }
        press(53, in: window)
        #expect(skipped)
    }

    @Test("a failed install shows the installer's last line and offers Retry")
    func failureOffersRetry() throws {
        let sheet = AgentSetupSheet(states: [.cursor: .failed(line: "curl: (6) Could not resolve host")])
        _ = mount(sheet)
        let row = try #require(sheet.rows[.cursor])
        #expect(row.detailText == "curl: (6) Could not resolve host")
        #expect(row.actionForTesting.title == "Retry")
    }
}

@MainActor
@Suite("Uninstalled agents")
struct UninstalledAgentTests {
    @Test("the quota panel drops an agent this Mac can't run — no endless 'measuring…'")
    func quotaHidesUninstalled() {
        let panel = QuotaPanel(frame: NSRect(x: 0, y: 0, width: 460, height: 560))
        panel.installedAgents = [.claude]
        panel.render(gauges: [])
        #expect(badges(in: panel) == [.claude])
        panel.installedAgents = nil
        panel.render(gauges: [])
        #expect(badges(in: panel) == [.claude], "unknown inventory keeps today's panel")
    }

    @Test("an unknown pool is dropped, not drawn as an 'n/a' bar")
    func unknownPoolHidden() {
        let panel = QuotaPanel(frame: NSRect(x: 0, y: 0, width: 460, height: 560))
        panel.installedAgents = [.claude, .codex]
        let unknown = QuotaGauge(provider: "codex", pool: "codex_weekly",
                                 state: .unknown, confidence: .estimated)
        panel.render(gauges: [unknown])
        #expect(badges(in: panel) == [.claude], "installed Codex with nothing to read stays out")
    }

    @Test("no agent at all: the lane offers 'Add an agent', and a real click opens setup")
    func emptyStateAddsAgent() throws {
        let panel = QuotaPanel(frame: NSRect(x: 0, y: 0, width: 460, height: 560))
        panel.installedAgents = []
        var asked = 0
        panel.onAddAgent = { asked += 1 }
        panel.render(gauges: [])
        let window = mount(panel)
        #expect(badges(in: panel).isEmpty)
        let add = try #require(find(in: panel, id: "quota-add-agent"))
        try click(add, in: window)
        #expect(asked == 1)
    }

    private func find(in view: NSView, id: String) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { find(in: $0, id: id) }.first
    }

    private func badges(in view: NSView) -> [CardAgent] {
        ((view as? HarnessBadge).map { [$0.agent] } ?? []) + view.subviews.flatMap(badges(in:))
    }
}
