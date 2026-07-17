import AppKit
import Testing

@testable import GhostlingApp

/// Hot code swapping (InjectionIII) is a DEBUG-only dev convenience — it can't be
/// meaningfully unit-tested end-to-end (it needs the InjectionIII.app bundle and a
/// live edit). What we *can* pin is the contract the app launch relies on:
/// `enable()` is safe to call unconditionally and degrades to a no-op when the
/// bundle isn't installed, so wiring it into `main.swift` never risks a crash on a
/// machine without InjectionIII (the common case, incl. CI).
@MainActor
@Suite("Dev hot reload")
struct DevHotReloadTests {

    @Test("enable() has a safe disabled no-op path, and is idempotent")
    func enableIsSafeWithoutInjection() {
        // Tests should not load a real InjectionIII install from the developer's
        // machine; the guarded path still installs the repaint observer, and
        // calling it twice must not crash.
        DevHotReload.enable(environment: ["GHOSTLING_DISABLE_HOT_RELOAD": "1"])
        DevHotReload.enable(environment: ["GHOSTLING_DISABLE_HOT_RELOAD": "1"])
    }

    @Test("bundle path can be overridden for nonstandard installs")
    func bundlePathOverride() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ghostling-injection-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("macOSInjection.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(DevHotReload.findInjectionBundlePath(
            environment: ["GHOSTLING_INJECTION_BUNDLE": bundle.path],
            homeDirectory: root.path
        ) == bundle.path)
    }

    @Test("bundle path supports user Applications installs")
    func userApplicationsBundlePath() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ghostling-home-\(UUID().uuidString)", isDirectory: true)
        let bundle = home
            .appendingPathComponent("Applications/InjectionIII.app/Contents/Resources/macOSInjection.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(DevHotReload.findInjectionBundlePath(environment: [:], homeDirectory: home.path) == bundle.path)
    }
}
