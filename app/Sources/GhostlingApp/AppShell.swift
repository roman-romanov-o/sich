import AppKit
import GhostlingCore

/// Minimal AppKit window/app lifecycle hosting one ``TerminalSurface`` running an
/// interactive shell. This is the launchable, screenshottable proof of the
/// Phase 01 substrate: a real, legible, interactive shell pane inside our app.
///
/// The session is launched through ``SessionRegistry`` so the pool firewall
/// guards the launch path, and a timer reconciles lifecycle so the window never
/// shows a dead-but-`running` session.
@MainActor
public final class AppShell: NSObject, NSApplicationDelegate {
    private let registry = SessionRegistry()
    private let command: [String]
    private var window: NSWindow?
    private var surface: TerminalSurface?
    private var reconcileTimer: Timer?
    private var session: Session?

    /// - Parameter command: the interactive command to host (defaults to the
    ///   user's login shell). Never `claude -p` — the registry's firewall refuses
    ///   it before a window is ever shown.
    public init(command: [String]? = nil) {
        self.command = command ?? Self.defaultShell()
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try launchSession()
        } catch {
            presentLaunchFailure(error)
            return
        }
        installReconcileTimer()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Launch

    private func launchSession() throws {
        let session = try registry.launch(
            command: command,
            projectDir: FileManager.default.currentDirectoryPath,
            agentType: .shell,
            flowTag: .interactive,
            rows: 24, cols: 80
        )
        self.session = session
        makeWindow(for: session)
    }

    private func makeWindow(for session: Session) {
        let surface = TerminalSurface(session: session.pty)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Ghostling — \(command.first ?? "shell")"
        window.contentView = surface
        window.makeFirstResponder(surface)
        window.center()
        window.makeKeyAndOrderFront(nil)
        surface.startReading()
        self.surface = surface
        self.window = window
    }

    // MARK: - Lifecycle reconcile

    private func installReconcileTimer() {
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }   // fires on the main run loop
        }
    }

    private func reconcile() {
        for dead in registry.reconcile() {
            // Classify for the *user-facing* surface: a non-zero EXIT (e.g. a
            // Ctrl-C-then-Ctrl-D logout, $?=130) is an exit, never a "crash";
            // only a terminating signal is a crash (TC-E2E-104).
            let disposition = SessionDisposition(state: dead.state)
            window?.title = "Ghostling — \(command.first ?? "shell") [\(disposition.shortLabel)]"
            surface?.markEnded(disposition)   // show the end cleanly, not hung
        }
    }

    // MARK: - Helpers

    private func presentLaunchFailure(_ error: Error) {
        FileHandle.standardError.write(Data("launch failed: \(error)\n".utf8))
        NSApp.terminate(nil)
    }

    private static func defaultShell() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return [shell]
    }
}
