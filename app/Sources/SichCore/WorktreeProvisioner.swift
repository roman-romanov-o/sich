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
    /// Tear down a task's worktree checkout (and prune its admin entry) when the
    /// card is deleted, so a removed task leaves no stray checkout behind. Returns
    /// `true` on a clean removal. Default: a no-op returning `false`, so test doubles
    /// and non-git provisioners need not implement it.
    func remove(worktreeAt path: String) -> Bool
}

public extension WorktreeProvisioning {
    func remove(worktreeAt path: String) -> Bool { false }
}

/// The real `git worktree add` provisioner: one checkout per task under
/// `~/.sich/worktrees/<repo>/<slug>`, on a fresh `task/<slug>` branch cut from
/// the repo's current HEAD. Kept OUTSIDE the repo so it never pollutes `git status`
/// or needs a `.gitignore` entry. A slug that already has a worktree/branch gets a
/// numeric suffix (`slug-2`…) instead of failing the whole creation.
public struct GitWorktreeProvisioner: WorktreeProvisioning, @unchecked Sendable {
    private static let git = URL(fileURLWithPath: "/usr/bin/git")
    private static let maxSlugAttempts = 5

    private let runner: any ProcessRunning
    private let baseDirectory: URL
    private let fileManager: FileManager

    public init(
        runner: any ProcessRunning = FoundationProcessRunner(),
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.baseDirectory = baseDirectory
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".sich/worktrees", isDirectory: true)
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

    /// `git worktree remove --force <path>` resolved from the worktree itself, then a
    /// `prune` so the main repo's admin dir doesn't keep a dangling entry. `--force`
    /// because a task checkout routinely has uncommitted edits (that's the point of
    /// the isolated branch) and the operator already chose to delete the task. Only
    /// touches linked worktrees — refuses a path that isn't one, so it can never be
    /// aimed at a real repo root.
    public func remove(worktreeAt path: String) -> Bool {
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        guard isLinkedWorktree(dir), let root = repoRoot(of: path) else { return false }
        let removed = (try? runner.run(
            executable: Self.git,
            arguments: ["worktree", "remove", "--force", path],
            directory: dir.deletingLastPathComponent()
        ))?.exitCode == 0
        // Prune the admin entry regardless — a manual `rm -rf` of the checkout would
        // otherwise leave a phantom worktree registration behind.
        _ = try? runner.run(
            executable: Self.git,
            arguments: ["worktree", "prune"],
            directory: root
        )
        return removed
    }

    /// A linked worktree's per-worktree git dir (`--git-dir`) differs from the shared
    /// `--git-common-dir`; for a normal checkout they're the same. This is the robust
    /// "is it safe to `worktree remove` this" gate — a main checkout fails it, so the
    /// delete can never be aimed at the primary repo.
    private func isLinkedWorktree(_ dir: URL) -> Bool {
        guard let result = try? runner.run(
            executable: Self.git,
            arguments: ["rev-parse", "--git-dir", "--git-common-dir"],
            directory: dir
        ), result.exitCode == 0 else { return false }
        let lines = result.standardOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.count == 2 && lines[0] != lines[1]
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
