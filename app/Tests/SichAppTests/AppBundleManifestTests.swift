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
        // Matches the package's deployment target so Gatekeeper won't refuse it.
        #expect(plist["LSMinimumSystemVersion"] as? String == "13.0")
    }
}
