import CryptoKit
import Foundation

/// The content state an Architecture pane should render for a bound project, resolved
/// without ever touching the network or spawning an agent. Mirrors how `MermaidRenderer`
/// degrades: no CLI + no prior build → show the `.c4` source, never crash, never block.
public enum LikeC4Content: Equatable {
    /// No `docs/architecture/*.c4` in the project — the pane has nothing to render.
    case noSources
    /// Sources exist but there's no `likec4` CLI and no prior build to fall back to.
    /// The pane shows the concatenated source plus an install hint.
    case degraded(sources: [URL])
    /// A finished static build lives at this directory — serve it as-is (0 rebuilds).
    case ready(dir: URL)
    /// Sources changed / never built; `likec4 build` must populate this directory first.
    case needsBuild(dir: URL, sources: [URL])
}

/// `likec4 build` orchestration: fixed-path CLI detection, source discovery, a content
/// hash for the disk cache, and the transient build itself. All logic here is CLI-free
/// and testable except `build`, which shells out exactly like `MermaidRenderer.run`.
// ponytail: shells to the likec4 CLI (bans `likec4 start`, the resident node server) with a
// SHA256 disk cache. Upgrade path: bundle a renderer if the CLI dep becomes a support burden.
public enum LikeC4 {
    /// Install hint shown when the CLI is missing and there's no cached build (mirrors
    /// `mermaidInstallHint`).
    public static let installHint = "install likec4 (`npm i -g likec4`) to render the architecture model"

    /// Same fixed-path pattern as `MermaidRenderer.mmdcPath` — no `$PATH` guessing.
    public static func cliPath() -> String? {
        ["/opt/homebrew/bin/likec4", "/usr/local/bin/likec4"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Default model location for a project's architecture pane; saha/v2 task specs
    /// pass `model` instead (the per-task LikeC4 project inside the task folder).
    public static let defaultModelDir = "docs/architecture"

    /// The authored model: `<projectDir>/<modelDir>/*.c4`, sorted for a stable hash.
    public static func sources(projectDir: URL, modelDir: String = defaultModelDir) -> [URL] {
        let dir = projectDir.appendingPathComponent(modelDir, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "c4" }.sorted { $0.path < $1.path }
    }

    /// SHA256 over the concatenated sources so an unchanged model rebuilds zero times
    /// across launches (String.hashValue is not stable; the file mtimes are irrelevant).
    public static func hash(of sources: [URL]) -> String? {
        guard !sources.isEmpty else { return nil }
        var hasher = SHA256()
        for url in sources {
            guard let data = try? Data(contentsOf: url) else { return nil }
            hasher.update(data: Data(url.lastPathComponent.utf8))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `~/Library/Caches/Ghostling/likec4/<model-hash>/`.
    public static func cacheDir(hash: String, base: URL? = nil) -> URL {
        let caches = base
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("Ghostling/likec4", isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true)
    }

    /// Decide what the pane should show for `projectDir`, preferring a cached build so an
    /// already-built model renders even when the CLI later disappears. `cacheBase` is a
    /// test seam; production passes nil to use the real Caches directory.
    public static func resolve(
        projectDir: URL,
        modelDir: String = defaultModelDir,
        cacheBase: URL? = nil,
        cliPath: String? = cliPath()
    ) -> LikeC4Content {
        let sources = sources(projectDir: projectDir, modelDir: modelDir)
        guard let hash = hash(of: sources) else { return .noSources }
        let dir = cacheDir(hash: hash, base: cacheBase)
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path) {
            return .ready(dir: dir)
        }
        return cliPath == nil ? .degraded(sources: sources) : .needsBuild(dir: dir, sources: sources)
    }

    /// Run `likec4 build <modelDir> -o <dir>` transiently (node spikes for a few
    /// seconds, then exits — never `likec4 start`). Off-main; returns true iff a static
    /// SPA landed. `nonisolated` so it runs on a background queue like `MermaidRenderer.run`.
    @discardableResult
    public static func build(
        cli: String, projectDir: URL, modelDir: String = defaultModelDir, into dir: URL
    ) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.currentDirectoryURL = projectDir
        p.arguments = ["build", modelDir, "-o", dir.path, "--use-hash-history"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
            && FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path)
    }
}
