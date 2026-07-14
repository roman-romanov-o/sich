import Foundation

/// Shared git-worktree resolution. A `git worktree` checkout's `.git` is a *file*
/// (`gitdir: <main>/.git/worktrees/<name>`), not a directory holding `HEAD`
/// directly — every directory-derived label (branch chip, repo chip/colour) that
/// assumes `.git` is a directory silently breaks for worktrees, since they're how
/// this project itself runs parallel task sessions.
enum GitWorktree {
    /// The directory that actually holds `HEAD`/`refs` for `path`: `<path>/.git`
    /// itself for a normal checkout, or the resolved `gitdir:` target for a
    /// worktree checkout. nil if `path` isn't inside a git repo at all.
    static func gitDir(of path: String) -> String? {
        let dotGit = (path as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }

        guard let raw = try? String(contentsOfFile: dotGit, encoding: .utf8) else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "gitdir: "
        guard line.hasPrefix(prefix) else { return nil }
        let target = String(line.dropFirst(prefix.count))
        return (target as NSString).isAbsolutePath
            ? target
            : (path as NSString).appendingPathComponent(target)
    }

    /// For a worktree checkout, the root of the *main* repository it was created
    /// from — resolved via `<gitdir>/commondir`, a relative path every worktree's
    /// gitdir carries back to the main `.git`. nil for a normal checkout (there's
    /// no separate "main" to point at) or a non-repo.
    static func mainRepoRoot(of path: String) -> String? {
        guard let gitDir = gitDir(of: path) else { return nil }
        let commondirFile = (gitDir as NSString).appendingPathComponent("commondir")
        guard let raw = try? String(contentsOfFile: commondirFile, encoding: .utf8) else { return nil }
        let relative = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let commonDir = (relative as NSString).isAbsolutePath
            ? relative
            : ((gitDir as NSString).appendingPathComponent(relative) as NSString).standardizingPath
        // commonDir is `<main>/.git`; its parent is the main repo root.
        return (commonDir as NSString).deletingLastPathComponent
    }

    /// True when `path` is a linked git *worktree* checkout (its `.git` is a file
    /// pointing back at `<main>/.git/worktrees/<name>`), not a normal clone or a
    /// non-repo. This is exactly the isolated checkout a task card is dropped into
    /// when "own git worktree" is on — the drill-in surfaces it so the operator can
    /// tell edits land on a side branch, not the shared main tree.
    static func isWorktree(_ path: String) -> Bool {
        mainRepoRoot(of: path) != nil
    }

    /// The branch `path` currently has checked out, read from its resolved gitdir's
    /// `HEAD` (`ref: refs/heads/<branch>`). nil for a detached HEAD or a non-repo —
    /// the caller falls back to a bare "worktree" label.
    static func currentBranch(of path: String) -> String? {
        guard let gitDir = gitDir(of: path) else { return nil }
        let head = (gitDir as NSString).appendingPathComponent("HEAD")
        guard let raw = try? String(contentsOfFile: head, encoding: .utf8) else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
    }
}
