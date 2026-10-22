import AppKit
import XCTest
@testable import SichApp

/// The board's Claude palette has two halves that have to agree: a theme FILE at
/// `~/.claude/themes/sich.json` and the `custom:sich` reference the shim injects.
/// Either half alone is a Claude session that silently keeps the built-in theme.
/// That the reference reaches only bound terminals is covered by
/// `HookInstallerTests.testClaudeShimInjectsOnlyInsideBoundSichTerminal`.
@MainActor
final class ClaudeThemeTests: XCTestCase {
    func testDocumentTracksAppearanceAndUsesTheBoardPalette() throws {
        let light = ClaudeTheme.document(for: NSAppearance(named: .aqua)!)
        let dark = ClaudeTheme.document(for: NSAppearance(named: .darkAqua)!)

        XCTAssertEqual(light["base"] as? String, "light")
        XCTAssertEqual(dark["base"] as? String, "dark")

        let lightOverrides = try XCTUnwrap(light["overrides"] as? [String: String])
        let darkOverrides = try XCTUnwrap(dark["overrides"] as? [String: String])

        // Ink follows the emulator's own foreground, so Claude's prose is the same
        // colour as the shell output above it.
        let ink = BoardTheme.terminalTheme(for: NSAppearance(named: .aqua)!).foreground
        XCTAssertEqual(lightOverrides["text"], "rgb(\(ink.r),\(ink.g),\(ink.b))")

        // Hues come from this appearance's ANSI ramp — the light ramp is tuned for
        // paper, so success/error/warning must differ between the two sides.
        for token in ["success", "error", "warning", "planMode", "permission"] {
            XCTAssertNotEqual(lightOverrides[token], darkOverrides[token],
                              "\(token) must be re-resolved for the appearance")
        }

        // Every value is in the `rgb(r,g,b)` syntax Claude's own themes use.
        for (token, value) in lightOverrides {
            XCTAssertNotNil(value.range(of: #"^rgb\(\d{1,3},\d{1,3},\d{1,3}\)$"#, options: .regularExpression),
                            "\(token) is not a Claude colour literal: \(value)")
        }
    }

    func testInstallWritesTheReferencedFileAndSkipsUnchangedRewrites() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-theme-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let aqua = NSAppearance(named: .aqua)!

        XCTAssertTrue(ClaudeTheme.install(for: aqua, home: home), "first run writes the theme")
        XCTAssertFalse(ClaudeTheme.install(for: aqua, home: home),
                       "an unchanged rewrite would make every open session reload its palette")
        XCTAssertTrue(ClaudeTheme.install(for: NSAppearance(named: .darkAqua)!, home: home),
                      "a light/dark flip rewrites the file so running sessions re-colour")

        // The file has to sit exactly where `custom:<slug>` looks for it.
        let file = home.appendingPathComponent(".claude/themes/sich.json")
        XCTAssertEqual(ClaudeTheme.themeFile(home: home), file)
        let doc = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(doc["name"] as? String, "Sich")
        XCTAssertEqual(doc["base"] as? String, "dark")
        XCTAssertFalse((doc["overrides"] as? [String: String] ?? [:]).isEmpty)
        XCTAssertEqual(ClaudeTheme.settingsRef, "custom:sich")
    }
}
