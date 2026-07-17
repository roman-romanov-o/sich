import AppKit

// Developer-only hot code swapping via InjectionIII (https://github.com/johnno1962/InjectionIII).
//
// When the app is built in DEBUG and run through `dev.sh` (which adds the
// `-Xlinker -interposable` flag), InjectionIII recompiles a changed .swift file
// into a dylib and swaps its *method bodies* into this running process — so the
// live PTYs, terminal surfaces, sessions and quota state all survive the edit.
//
// Scope (be honest about the boundary):
//   - swaps method bodies only; adding a stored property / new type / changing
//     class layout still needs a full restart,
//   - C targets (libghostty, CPtySupport) never hot-swap,
//   - custom-drawn NSViews won't repaint on their own, so we force a redraw when
//     an injection lands (see the observer below).
//
// This whole type compiles to nothing in release builds (the `enable()` body is
// `#if DEBUG`), and it is only invoked from the real app launch — never tests or
// the E2E capture.
@MainActor
public enum DevHotReload {
    private static var didInstallObserver = false

    /// Load the InjectionIII bundle and repaint on each injection. No-op unless
    /// DEBUG and the bundle is installed; safe to call unconditionally at launch.
    public static func enable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) {
        #if DEBUG
        let bundlePath = findInjectionBundlePath(environment: environment, homeDirectory: homeDirectory)
        loadInjectionBundle(at: bundlePath)
        observeInjection()
        #endif
    }

    #if DEBUG
    static func findInjectionBundlePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> String? {
        if environment["GHOSTLING_DISABLE_HOT_RELOAD"] != nil {
            return nil
        }

        let manager = FileManager.default
        if let override = environment["GHOSTLING_INJECTION_BUNDLE"], manager.fileExists(atPath: override) {
            return override
        }

        let appRelativePath = "Contents/Resources/macOSInjection.bundle"
        let candidates = [
            "/Applications/InjectionIII.app/\(appRelativePath)",
            "\(homeDirectory)/Applications/InjectionIII.app/\(appRelativePath)"
        ]
        return candidates.first { manager.fileExists(atPath: $0) }
    }

    @discardableResult
    private static func loadInjectionBundle(at path: String?) -> Bool {
        guard let path else {
            NSLog("[DevHotReload] InjectionIII not installed — install InjectionIII.app in /Applications or ~/Applications, or set GHOSTLING_INJECTION_BUNDLE.")
            return false
        }
        guard Bundle(path: path)?.load() == true else {
            NSLog("[DevHotReload] Failed to load InjectionIII bundle at \(path).")
            return false
        }
        NSLog("[DevHotReload] Hot reload enabled from \(path) — save a .swift file to swap it live.")
        return true
    }

    private static func observeInjection() {
        guard !didInstallObserver else { return }
        didInstallObserver = true
        // A freshly injected `draw(_:)`/layout method only takes effect on the next
        // display pass, so nudge every window to repaint when an injection lands.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"),
            object: nil,
            queue: .main
        ) { _ in
            // The `.main` queue guarantees main-thread delivery, so we can safely
            // assume main-actor isolation to touch the (main-actor) window views.
            MainActor.assumeIsolated {
                for window in NSApp.windows {
                    window.contentView?.needsLayout = true
                    window.contentView?.needsDisplay = true
                }
            }
        }
    }
    #endif
}
