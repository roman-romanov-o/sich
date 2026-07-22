import AppKit
import CryptoKit
import SichCore

/// Renders mermaid fences to images via the `mmdc` CLI, cached in memory and on disk by a
/// content hash. Non-blocking: the first lookup for an uncached diagram returns nil (so the
/// renderer shows the source + install-hint fallback immediately) and kicks off a background
/// render; when it lands, `onReady` fires so the host re-renders the doc with the image.
// ponytail: shells to mmdc (already installed) with a SHA256 disk cache. Upgrade path:
// bundle a renderer if the CLI dependency ever becomes a problem.
@MainActor
final class MermaidRenderer {
    /// Called on the main thread when a previously-pending diagram finishes rendering.
    var onReady: (() -> Void)?

    private var memory: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    /// Sync lookup for `NativeMarkdownRenderer`'s `renderMermaid` closure: cached image or nil.
    func image(for source: String) -> NSImage? {
        let key = Self.hash(source)
        if let img = memory[key] { return img }
        let png = Self.cacheDir.appendingPathComponent("\(key).png")
        if let img = NSImage(contentsOf: png) { memory[key] = img; return img }
        schedule(source, key: key, png: png)
        return nil
    }

    private func schedule(_ source: String, key: String, png: URL) {
        guard !inFlight.contains(key), Self.mmdcPath != nil else { return }
        inFlight.insert(key)
        let mmdc = Self.mmdcPath!
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Self.run(mmdc, source: source, output: png)
            DispatchQueue.main.async {
                self.inFlight.remove(key)
                guard ok, let img = NSImage(contentsOf: png) else { return }
                self.memory[key] = img
                self.onReady?()
            }
        }
    }

    // MARK: - CLI plumbing (nonisolated: runs off the main thread)

    nonisolated private static func run(_ mmdc: String, source: String, output: URL) -> Bool {
        let input = output.deletingPathExtension().appendingPathExtension("mmd")
        guard (try? source.write(to: input, atomically: true, encoding: .utf8)) != nil else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: mmdc)
        p.environment = LikeC4.environment(forCLI: mmdc)
        p.arguments = ["-i", input.path, "-o", output.path, "-b", "transparent", "-t", "dark"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: output.path)
    }

    /// SHA256 so the cache key is stable across process launches (String.hashValue is not).
    nonisolated private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Sich/mermaid", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let mmdcPath: String? =
        ["/opt/homebrew/bin/mmdc", "/usr/local/bin/mmdc"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
}
