import Foundation
import Testing

/// Guards the app bundle's `Info.plist` — the manifest `make-app.sh` copies into
/// `Sich.app` to give the app its real name and icon (the "normal name / normal
/// icon" goal items). A silent drift here (missing icon key, blank name, wrong
/// executable) would ship a generically-named, icon-less bundle again, so pin the
/// keys the bundle depends on.
@Suite("App bundle Info.plist manifest")
struct AppBundleManifestTests {

    /// Resolve `app/packaging/Info.plist` from this test file's location
    /// (Tests/SichAppTests/…  →  app/packaging/Info.plist).
    private func manifest() throws -> [String: Any] {
        let here = URL(fileURLWithPath: #filePath)
        let plist = here
            .deletingLastPathComponent()   // SichAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("packaging/Info.plist")
        let data = try Data(contentsOf: plist)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(parsed as? [String: Any])
    }

    @Test("names the app 'Sich', points at the sich executable and its icon")
    func requiredKeysArePresent() throws {
        let plist = try manifest()
        #expect(plist["CFBundleName"] as? String == "Sich")
        #expect(plist["CFBundleDisplayName"] as? String == "Sich")
        #expect(plist["CFBundleExecutable"] as? String == "sich")
        // Icon file is referenced without the .icns extension (the classic form).
        #expect(plist["CFBundleIconFile"] as? String == "Sich")
        #expect((plist["CFBundleIdentifier"] as? String)?.isEmpty == false)
        #expect(plist["NSHighResolutionCapable"] as? Bool == true)
        // Must match Package.swift's `.macOS(.v14)` deployment target (raised for
        // NSView.displayLink). Claiming 13.0 here doesn't make the binary run on
        // Ventura — it only lets a Ventura user install a bundle that then dies at
        // launch, which is exactly the failure a shared build must not ship.
        #expect(plist["LSMinimumSystemVersion"] as? String == "14.0")
    }

    /// The two things that separate a bundle someone else can run from one that only
    /// works on the machine that built it. Both failures are invisible here — an
    /// arm64-only bundle simply refuses to launch on Intel, and a missing mark is a
    /// `fatalError` from SwiftPM's `Bundle.module` accessor (it falls back to the
    /// builder's absolute `.build` path) the first time a card draws its badge.
    /// Neither shows up in a local run, so pin them at the script level.
    @Test("make-app.sh builds universal and vendors the harness marks into the bundle")
    func packagingScriptKeepsTheBundlePortable() throws {
        let here = URL(fileURLWithPath: #filePath)
        let script = try String(contentsOf: here
            .deletingLastPathComponent()   // SichAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("make-app.sh"), encoding: .utf8)
        #expect(script.contains("--arch arm64 --arch x86_64"))
        #expect(script.contains("cp Sources/SichApp/Resources/*.pdf \"$RESOURCES/\""))
    }
}
