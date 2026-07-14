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

    @Test("enable() is a safe no-op without InjectionIII, and is idempotent")
    func enableIsSafeWithoutInjection() {
        // No InjectionIII bundle on the test host → the guarded path just logs and
        // installs the repaint observer. Calling it twice must not crash either.
        DevHotReload.enable()
        DevHotReload.enable()
    }
}
