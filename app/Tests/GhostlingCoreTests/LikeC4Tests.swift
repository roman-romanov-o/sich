import Foundation
import Testing

@testable import GhostlingCore

/// The CLI-free logic behind the Architecture pane: source discovery, a stable content
/// hash, and the resolve() state machine that decides render vs. degrade vs. build.
struct LikeC4Tests {
    private func tempProject(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("likec4-test-\(UUID().uuidString)")
        let arch = root.appendingPathComponent("docs/architecture")
        try FileManager.default.createDirectory(at: arch, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(to: arch.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func noSourcesWhenNoC4Files() throws {
        let project = try tempProject([:])
        #expect(LikeC4.resolve(projectDir: project) == .noSources)
    }

    @Test func hashIsStableAndContentSensitive() throws {
        let project = try tempProject(["a.c4": "model {}", "b.c4": "views {}"])
        let sources = LikeC4.sources(projectDir: project)
        #expect(sources.count == 2)
        let h1 = LikeC4.hash(of: sources)
        #expect(h1 == LikeC4.hash(of: sources))   // stable across calls
        try "model { edited }".write(to: sources[0], atomically: true, encoding: .utf8)
        #expect(LikeC4.hash(of: sources) != h1)   // content-sensitive
    }

    @Test func resolvePrefersCachedBuildEvenWithoutCLI() throws {
        let project = try tempProject(["a.c4": "model {}"])
        let cacheBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("likec4-cache-\(UUID().uuidString)")
        let hash = try #require(LikeC4.hash(of: LikeC4.sources(projectDir: project)))
        let dir = LikeC4.cacheDir(hash: hash, base: cacheBase)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "<html></html>".write(to: dir.appendingPathComponent("index.html"),
                                  atomically: true, encoding: .utf8)
        #expect(LikeC4.resolve(projectDir: project, cacheBase: cacheBase) == .ready(dir: dir))
    }

    @Test func resolveWithSourcesButNoCacheDegradesOrBuilds() throws {
        let project = try tempProject(["a.c4": "model {}"])
        let cacheBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("likec4-cache-\(UUID().uuidString)")
        // No cached build here. Without the CLI → degrade; with it → needsBuild. Assert
        // it's exactly one of those two, never noSources / ready (which would be wrong).
        switch LikeC4.resolve(projectDir: project, cacheBase: cacheBase) {
        case .degraded, .needsBuild: break
        default: Issue.record("expected degraded or needsBuild")
        }
    }
}

struct StaticFileServerTests {
    @Test func servesFilesAndFallsBackToIndexForUnknownRoutes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("server-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "<html>ROOT</html>".write(to: root.appendingPathComponent("index.html"),
                                      atomically: true, encoding: .utf8)
        try "console.log(1)".write(to: root.appendingPathComponent("app.js"),
                                   atomically: true, encoding: .utf8)

        let server = StaticFileServer(root: root)
        let base: URL = try await withCheckedThrowingContinuation { cont in
            server.start { url in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: CancellationError()) }
            }
        }
        defer { server.stop() }

        let (indexData, _) = try await URLSession.shared.data(from: base)
        #expect(String(data: indexData, encoding: .utf8)?.contains("ROOT") == true)

        let (jsData, jsResp) = try await URLSession.shared.data(from: base.appendingPathComponent("app.js"))
        #expect(String(data: jsData, encoding: .utf8) == "console.log(1)")
        #expect(((jsResp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "")
            .contains("javascript"))

        // Unknown client-side route → SPA fallback to index.html (200, not 404).
        let (spaData, spaResp) = try await URLSession.shared
            .data(from: base.appendingPathComponent("task-03-quota-flow"))
        #expect((spaResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: spaData, encoding: .utf8)?.contains("ROOT") == true)
    }
}
