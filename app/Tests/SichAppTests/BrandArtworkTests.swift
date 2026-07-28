import AppKit
import Foundation
import Testing

/// Guards the checked-in brand artwork the README renders on GitHub.
///
/// The source artwork (`assets/sich-icon.png`) is an opaque export: a rounded tile
/// baked onto a white square. `make-icon.swift` crops and clips that white away for
/// the app icon, but the README used the raw source for a long time and showed a
/// white block — glaring in dark mode. The derived flat PNG is what fixes it, and
/// nothing in a build or a screenshot would catch a regression back to the opaque
/// file, so pin the two facts that matter: the README points at the derived
/// artwork, and that artwork really is transparent outside its rounded silhouette.
@Suite("Brand artwork")
struct BrandArtworkTests {

    /// Repository root, resolved from this test file (Tests/SichAppTests/… → app → root).
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SichAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repository root
    }

    private func pixels(of relativePath: String) throws -> NSBitmapImageRep {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        let image = try #require(NSImage(contentsOf: url), "missing artwork at \(relativePath)")
        let tiff = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff))
    }

    @Test("the README renders the derived flat icon, not the opaque source export")
    func readmeUsesTheTransparentArtwork() throws {
        let readme = try String(
            contentsOf: repositoryRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        #expect(readme.contains("assets/sich-icon-flat.png"))
        #expect(!readme.contains("src=\"assets/sich-icon.png\""))
    }

    @Test("the flat icon is transparent at its corners and opaque at its centre")
    func flatIconHasATransparentSurround() throws {
        let bitmap = try pixels(of: "assets/sich-icon-flat.png")
        #expect(bitmap.hasAlpha)

        let maxX = bitmap.pixelsWide - 1
        let maxY = bitmap.pixelsHigh - 1
        // Two pixels in from each corner: far enough past the rounded silhouette
        // that a white plate would be unambiguous, close enough to stay outside it.
        let corners = [(2, 2), (maxX - 2, 2), (2, maxY - 2), (maxX - 2, maxY - 2)]
        for (horizontal, vertical) in corners {
            let alpha = bitmap.colorAt(x: horizontal, y: vertical)?.alphaComponent
            #expect(alpha == 0, "corner (\(horizontal), \(vertical)) is not transparent")
        }

        let centre = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        #expect(centre?.alphaComponent == 1)
    }
}
