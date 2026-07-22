import Foundation
import Testing

@testable import SichCore

/// Integration checks against REAL git in throwaway temp dirs: the provisioner's
/// whole value is what `git worktree add` actually does, so a mock proves nothing.
@Suite("Git worktree provisioning")
struct WorktreeProvisionerTests {
    /// A temp git repo with one commit (worktrees need a HEAD to branch from).
    private func makeRepo(in base: URL) throws -> URL {
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let runner = FoundationTaskScaffoldRunner()
        let git = URL(fileURLWithPath: "/usr/bin/git")
        for args in [
            ["init", "-q"],
            ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "seed"],
        ] {
            let r = try runner.run(executable: git, arguments: args, directory: repo)
            try #require(r.exitCode == 0, Comment(rawValue: r.standardError))
        }
        return repo
    }

    private func makeTempBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-wt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test("a repo dir gets a checked-out worktree on a fresh task/<slug> branch")
    func provisionsWorktreeAndBranch() throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try makeRepo(in: base)
        let provisioner = GitWorktreeProvisioner(
            baseDirectory: base.appendingPathComponent("worktrees", isDirectory: true))

        let provisioned = try #require(provisioner.provision(repoDir: repo.path, slug: "fix-login"))

        #expect(provisioned.branch == "task/fix-login")
        #expect(provisioned.path.hasSuffix("repo/fix-login"))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: provisioned.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: provisioned.path + "/.git"),
                "the worktree is a real git checkout")
    }

    @Test("a second task with the same slug gets a suffixed worktree, not a failure")
    func slugCollisionGetsSuffix() throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try makeRepo(in: base)
        let provisioner = GitWorktreeProvisioner(
            baseDirectory: base.appendingPathComponent("worktrees", isDirectory: true))

        let first = try #require(provisioner.provision(repoDir: repo.path, slug: "same"))
        let second = try #require(provisioner.provision(repoDir: repo.path, slug: "same"))

        #expect(first.path != second.path)
        #expect(second.branch == "task/same-2")
    }

    @Test("a non-repo dir yields nil — the caller falls back to the plain dir")
    func nonRepoFallsBack() throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let plain = base.appendingPathComponent("not-a-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let provisioner = GitWorktreeProvisioner(
            baseDirectory: base.appendingPathComponent("worktrees", isDirectory: true))

        #expect(provisioner.provision(repoDir: plain.path, slug: "x") == nil)
    }
}
