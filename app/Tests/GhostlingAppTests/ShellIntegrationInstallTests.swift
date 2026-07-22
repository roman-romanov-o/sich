import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

/// TC-INT-023 / US-004 AC2 + edge cases: the shell-integration install must be driven by
/// the **real launch path** (`BoardShell.installShellIntegration`, the seam
/// `applicationDidFinishLaunching` calls), be idempotent across launches, and preserve
/// the operator's existing rc verbatim — mirroring the hook installer's marker-block
/// merge. Everything is injected into a fresh temp dir, so the test NEVER writes the real
/// `~/.zshrc`, terminfo, or install root.
@MainActor
@Suite(.serialized)
struct ShellIntegrationInstallTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostling-shellint-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// A second launch is a pure no-op (no duplicate marker block / rc lines); the
    /// pre-existing rc content is intact; both integration files land in the root — all
    /// through the `BoardShell` launch seam, not the installer leaf directly.
    @Test func install_idempotent_preservesRc() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rc = dir.appendingPathComponent(".zshrc")
        let root = dir.appendingPathComponent("shell-integration")

        let priorRc = "export EDITOR=vim\nalias ll='ls -la'\n"
        try priorRc.write(to: rc, atomically: true, encoding: .utf8)

        // First launch installs; a second launch (fresh delegate) is a no-op.
        #expect(BoardShell().installShellIntegration(shell: .zsh, installRoot: root, rc: rc))
        #expect(!BoardShell().installShellIntegration(shell: .zsh, installRoot: root, rc: rc))

        let rcAfter = try String(contentsOf: rc, encoding: .utf8)
        // Prior content preserved verbatim, at the head — the block is only appended.
        #expect(rcAfter.hasPrefix(priorRc))
        // Exactly one marker block survives two launches (no duplicate lines).
        #expect(occurrences(of: ShellIntegrationInstaller.beginMarker, in: rcAfter) == 1)
        #expect(occurrences(of: ShellIntegrationInstaller.endMarker, in: rcAfter) == 1)

        // Both integration files are installed under the injected root.
        let integration = root.appendingPathComponent(ShellIntegrationInstaller.integrationName)
        let terminfo = root.appendingPathComponent(ShellIntegrationInstaller.terminfoName)
        #expect(FileManager.default.fileExists(atPath: integration.path))
        #expect(FileManager.default.fileExists(atPath: terminfo.path))
        let integrationBody = try String(contentsOf: integration, encoding: .utf8)
        #expect(integrationBody.contains(#"PATH="$HOME/.ghostling/bin:$PATH""#))
    }

    @Test func install_replacesStaleIntegrationPayload() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rc = dir.appendingPathComponent(".zshrc")
        let root = dir.appendingPathComponent("shell-integration")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let integration = root.appendingPathComponent(ShellIntegrationInstaller.integrationName)
        try "old generated integration\n".write(to: integration, atomically: true, encoding: .utf8)

        #expect(BoardShell().installShellIntegration(shell: .zsh, installRoot: root, rc: rc))
        let upgraded = try String(contentsOf: integration, encoding: .utf8)
        #expect(upgraded == ShellIntegrationInstaller.integrationScript)
        #expect(upgraded.contains("$HOME/.ghostling/bin"))
    }

    /// Edge case: a non-zsh shell degrades gracefully — the launch seam no-ops and never
    /// rewrites or corrupts the rc it doesn't own (a launch must never break the shell).
    @Test func nonZshShellDegradesGracefully_rcUntouched() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rc = dir.appendingPathComponent(".bashrc")
        let root = dir.appendingPathComponent("shell-integration")

        let priorRc = "export PS1='\\u@\\h \\$ '\n"
        try priorRc.write(to: rc, atomically: true, encoding: .utf8)

        #expect(!BoardShell().installShellIntegration(shell: .bash, installRoot: root, rc: rc))

        let rcAfter = try String(contentsOf: rc, encoding: .utf8)
        #expect(rcAfter == priorRc)  // byte-for-byte unchanged
        #expect(!rcAfter.contains(ShellIntegrationInstaller.beginMarker))
    }
}
