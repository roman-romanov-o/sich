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
public enum DevHotReload {
    /// Load the InjectionIII bundle and repaint on each injection. No-op unless
    /// DEBUG and the bundle is installed; safe to call unconditionally at launch.
    public static func enable() {
        #if DEBUG
        loadInjectionBundle()
        observeInjection()
        #endif
    }

    #if DEBUG
    private static func loadInjectionBundle() {
        // InjectionIII.app ships the loader bundle; if the app isn't installed we
        // simply run without hot reload (the flag is a dev convenience, not a dep).
        let path = "/Applications/InjectionIII.app/Contents/Resources/macOSInjection.bundle"
        guard FileManager.default.fileExists(atPath: path) else {
            NSLog("[DevHotReload] InjectionIII not installed — running without hot reload.")
            return
        }
        Bundle(path: path)?.load()
        NSLog("[DevHotReload] Hot reload enabled — save a .swift file to swap it live.")
    }

    private static func observeInjection() {
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
