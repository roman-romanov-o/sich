import Foundation

/// Where one task's dedicated git worktree landed: the checkout path the session
/// runs in, and the fresh branch it tracks.
public struct ProvisionedWorktree: Sendable, Equatable {
    public let path: String
    public let branch: String

    public init(path: String, branch: String) {
        self.path = path
        self.branch = branch
    }
}

/// Provisions an isolated git worktree for one task, so parallel task cards on the
/// same repo never collide in a single checkout. Returning `nil` means "no worktree
/// possible here" (not a repo, or git failed) — callers fall back to the repo dir,
/// never block card creation on it.
public protocol WorktreeProvisioning: Sendable {
    func provision(repoDir: String, slug: String) -> ProvisionedWorktree?
}

/// The real `git worktree add` provisioner: one checkout per task under
/// `~/.ghostling/worktrees/<repo>/<slug>`, on a fresh `task/<slug>` branch cut from
/// the repo's current HEAD. Kept OUTSIDE the repo so it never pollutes `git status`
/// or needs a `.gitignore` entry. A slug that already has a worktree/branch gets a
/// numeric suffix (`slug-2`…) instead of failing the whole creation.
public struct GitWorktreeProvisioner: WorktreeProvisioning, @unchecked Sendable {
    private static let git = URL(fileURLWithPath: "/usr/bin/git")
    private static let maxSlugAttempts = 5

    private let runner: any TaskScaffoldRunning
    private let baseDirectory: URL
    private let fileManager: FileManager

    public init(
        runner: any TaskScaffoldRunning = FoundationTaskScaffoldRunner(),
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.baseDirectory = baseDirectory
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".ghostling/worktrees", isDirectory: true)
        self.fileManager = fileManager
    }

    public func provision(repoDir: String, slug: String) -> ProvisionedWorktree? {
        guard let root = repoRoot(of: repoDir) else { return nil }
        for attempt in 1...Self.maxSlugAttempts {
            let name = attempt == 1 ? slug : "\(slug)-\(attempt)"
            if let provisioned = addWorktree(repoRoot: root, name: name) {
                return provisioned
            }
        }
        return nil
    }

    /// The repo's toplevel, or nil for a non-repo dir — the "should we even try"
    /// gate that makes the worktree default safe on arbitrary chosen folders.
    private func repoRoot(of dir: String) -> URL? {
        guard let result = try? runner.run(
            executable: Self.git,
            arguments: ["rev-parse", "--show-toplevel"],
            directory: URL(fileURLWithPath: dir, isDirectory: true)
        ), result.exitCode == 0 else { return nil }
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    private func addWorktree(repoRoot: URL, name: String) -> ProvisionedWorktree? {
        let container = baseDirectory
            .appendingPathComponent(repoRoot.lastPathComponent, isDirectory: true)
        let target = container.appendingPathComponent(name, isDirectory: true)
        guard !fileManager.fileExists(atPath: target.path) else { return nil }
        try? fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        let branch = "task/\(name)"
        guard let result = try? runner.run(
            executable: Self.git,
            arguments: ["worktree", "add", target.path, "-b", branch],
            directory: repoRoot
        ), result.exitCode == 0 else { return nil }
        return ProvisionedWorktree(path: target.path, branch: branch)
    }
}
