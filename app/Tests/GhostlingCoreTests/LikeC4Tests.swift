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

    @Test func customModelDirDiscoversSourcesOutsideDocsArchitecture() throws {
        // saha/v2 tasks keep their LikeC4 project under `model/`, not docs/architecture.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("likec4-modeldir-\(UUID().uuidString)")
        let model = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try "model {}".write(to: model.appendingPathComponent("stories.c4"),
                             atomically: true, encoding: .utf8)

        #expect(LikeC4.resolve(projectDir: root) == .noSources)   // default dir sees nothing
        let sources = LikeC4.sources(projectDir: root, modelDir: "model")
        #expect(sources.map(\.lastPathComponent) == ["stories.c4"])
        let cacheBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("likec4-cache-\(UUID().uuidString)")
        #expect(LikeC4.resolve(projectDir: root, modelDir: "model", cacheBase: cacheBase,
                               cliPath: nil) == .degraded(sources: sources))
    }

    /// The one seam the CLI-free tests can't touch: a REAL `likec4 build` through the
    /// Swift wrapper against a saha/v2 task's `model/` dir must land a servable SPA that
    /// exposes the task's view ids (what the story pane deep-links to). Skips without
    /// the CLI so the suite stays hermetic on machines that lack node.
    @Test func realBuildOfV2ModelDirExposesTaskViewIDs() throws {
        guard let cli = LikeC4.cliPath() else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("likec4-realbuild-\(UUID().uuidString)")
        let model = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try """
        specification {
          element actor
          element container
          element story
        }
        """.write(to: model.appendingPathComponent("spec.c4"), atomically: true, encoding: .utf8)
        try """
        model {
          dev = actor 'Developer'
          app = container 'App'
        }
        views {
          view task-context {
            title 'context'
            include *
          }
        }
        """.write(to: model.appendingPathComponent("task.c4"), atomically: true, encoding: .utf8)
        try """
        model {
          us-001 = story 'US-001: sample story'
        }
        views {
          dynamic view us-001-flow {
            title 'US-001 flow'
            dev -> app 'opens'
          }
        }
        """.write(to: model.appendingPathComponent("stories.c4"), atomically: true, encoding: .utf8)

        let sources = LikeC4.sources(projectDir: root, modelDir: "model")
        let hash = try #require(LikeC4.hash(of: sources))
        let cacheBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("likec4-realbuild-cache-\(UUID().uuidString)")
        let dir = LikeC4.cacheDir(hash: hash, base: cacheBase)
        defer { try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: cacheBase) }

        #expect(LikeC4.build(cli: cli, projectDir: root, modelDir: "model", into: dir))
        #expect(LikeC4.resolve(projectDir: root, modelDir: "model",
                               cacheBase: cacheBase) == .ready(dir: dir))

        // The built SPA must know both view ids or deep-linking `#/us-001-flow` is dead.
        let contents = try FileManager.default
            .subpathsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".js") || $0.hasSuffix(".html") }
            .compactMap { try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }
            .joined()
        #expect(contents.contains("us-001-flow"))
        #expect(contents.contains("task-context"))
    }

    @Test func resolveWithSourcesButNoCacheDegradesOrBuilds() throws {
        let project = try tempProject(["a.c4": "model {}"])
        let cacheBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("likec4-cache-\(UUID().uuidString)")
        // No cached build here. Without the CLI → degrade; with it → needsBuild. Assert
        // it's exactly one of those two, never noSources / ready (which would be wrong).
        #expect(LikeC4.resolve(projectDir: project, cacheBase: cacheBase, cliPath: nil) == .degraded(
            sources: LikeC4.sources(projectDir: project)))
        if LikeC4.cliPath() != nil {
            if case .needsBuild = LikeC4.resolve(projectDir: project, cacheBase: cacheBase) {} else {
                Issue.record("expected needsBuild when the CLI is installed")
            }
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

    @Test func rejectsTraversalOutsideRoot() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("server-parent-\(UUID().uuidString)")
        let root = parent.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "<html>ROOT</html>".write(to: root.appendingPathComponent("index.html"),
                                      atomically: true, encoding: .utf8)
        try "SECRET".write(to: parent.appendingPathComponent("secret.txt"),
                           atomically: true, encoding: .utf8)

        let server = StaticFileServer(root: root)
        let base: URL = try await withCheckedThrowingContinuation { cont in
            server.start { url in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: CancellationError()) }
            }
        }
        defer { server.stop() }

        let (data, response) = try await URLSession.shared
            .data(from: base.appendingPathComponent("../secret.txt"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8)?.contains("ROOT") == true)
    }
}
