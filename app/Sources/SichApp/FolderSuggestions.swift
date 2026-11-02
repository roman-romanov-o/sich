import Foundation
import SichCore

/// Where the create palette's folder field gets its completions. One seam for both
/// destinations so the palette never knows whether a listing came off this disk or
/// over ssh; a test hands in canned listings and never touches either.
@MainActor
protocol FolderSuggestionSource {
    /// The subfolders of `parent` on `host` (`nil` = this Mac) — plus, when the source
    /// looked a level further, each subfolder's own children — or `nil` when the folder
    /// cannot be listed. `completion` always runs on the main actor; a local answer
    /// may arrive before this call returns.
    func subdirectories(
        of parent: String, on host: String?,
        completion: @escaping @MainActor (FolderCompletion.Tree?) -> Void)
}

/// The production source: one bulk directory read for this Mac (synchronous — the
/// kernel answers in well under a millisecond, and instant is the point), and one
/// bounded ssh command per far-side folder, off the main thread and one at a time,
/// so a slow link only delays the suggestions, never the typing, and a dead host
/// holds one worker rather than one per keystroke.
struct PaletteFolderSource: FolderSuggestionSource {
    let remoteRunner: any RemoteCommandRunner
    private static let remoteQueue = DispatchQueue(label: "sich.folder-listing", qos: .userInitiated)

    func subdirectories(
        of parent: String, on host: String?,
        completion: @escaping @MainActor (FolderCompletion.Tree?) -> Void
    ) {
        guard let host else {
            completion(Self.localFolders(in: parent).map { FolderCompletion.Tree(children: $0) })
            return
        }
        guard let spec = RemoteTmuxSpec.parse(destination: host, sessionName: "sich"),
              let argv = try? RemoteTmuxCommand.listFoldersArgv(for: spec)
        else {
            completion(nil)
            return
        }
        let runner = remoteRunner
        let input = Data((parent + "\n").utf8)
        Self.remoteQueue.async {
            let result = runner.run(argv: argv, input: input)
            let tree = result.flatMap { r -> FolderCompletion.Tree? in
                r.succeeded ? FolderCompletion.tree(fromFind: r.standardOutput) : nil
            }
            DispatchQueue.main.async { completion(tree) }
        }
    }

    /// One `contentsOfDirectory` call with the directory flag prefetched — a single bulk
    /// attribute read, not a `stat` per entry. `dir` is already absolute: the palette
    /// resolves `~` and bare names before asking. Symlinked folders count: the key
    /// resolves through the link.
    static func localFolders(in dir: String) -> [String]? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey], options: [])
        else { return nil }
        return entries.compactMap { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                ? url.lastPathComponent : nil
        }
    }
}
