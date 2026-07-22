import Foundation

/// The operator's login shell, resolved from `$SHELL`'s basename. Only `zsh` has a
/// bundled Ghostty integration today; every other shell degrades gracefully — the
/// installer no-ops rather than risk corrupting an rc whose syntax it doesn't own.
enum LoginShell: Equatable {
    case zsh
    case bash
    case fish
    case other(String)

    init(path: String) {
        switch (path as NSString).lastPathComponent {
        case "zsh": self = .zsh
        case "bash": self = .bash
        case "fish": self = .fish
        case let name: self = .other(name)
        }
    }

    /// The operator's current shell from `$SHELL`, defaulting to zsh (the macOS default).
    static var current: LoginShell {
        LoginShell(path: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
    }
}

/// The semantic cwd signal a shell REPORTS via Ghostty shell-integration's OSC 7
/// sequence (`ESC ] 7 ; file://host/path ST`): the cwd the shell itself declares on
/// each prompt. This is the "reported, not inferred" mechanism US-004 AC1 asks for —
/// the path is read straight off the terminal's OSC stream, never derived by scanning
/// the process tree the way `CutoverGuard`'s `ps` query does.
enum ShellIntegration {
    /// Extract the filesystem path from an OSC 7 cwd report, or nil for any other
    /// escape (e.g. an OSC 0 title set carries no cwd — the mechanism never guesses).
    static func reportedCwd(fromOSC sequence: String) -> String? {
        let body = strippedEnvelope(sequence)
        guard body.hasPrefix("7;") else { return nil }
        let uri = String(body.dropFirst(2))
        guard let url = URL(string: uri), url.scheme == "file" else { return nil }
        let path = url.path
        return path.isEmpty ? nil : path
    }

    /// Strip the OSC introducer (`ESC ]`) and the string terminator (`ESC \` or BEL),
    /// leaving the bare `Ps ; Pt` payload.
    private static func strippedEnvelope(_ sequence: String) -> String {
        var body = Substring(sequence)
        if body.hasPrefix("\u{1B}]") { body = body.dropFirst(2) }
        if body.hasSuffix("\u{1B}\\") {
            body = body.dropLast(2)
        } else if body.hasSuffix("\u{07}") {
            body = body.dropLast()
        }
        return String(body)
    }
}

/// Installs Ghostty shell-integration (`ghostty-integration.zsh` + the `xterm-ghostty`
/// terminfo) so the shell REPORTS cwd/command boundaries semantically (OSC 7 / OSC 133)
/// instead of the board inferring them from a process scan. Mirrors `HookInstaller` /
/// `enable-board-hooks.sh`: idempotent via a begin/end marker block, the operator's
/// pre-existing rc preserved verbatim. The **app** does this at launch (a different
/// process from the agent); it spawns nothing — it only writes files. Every path is
/// injectable so tests never touch the real `~/.zshrc`, terminfo, or install root.
enum ShellIntegrationInstaller {
    static let beginMarker = "# >>> sich shell-integration >>>"
    static let endMarker = "# <<< sich shell-integration <<<"
    static let integrationName = "ghostty-integration.zsh"
    static let terminfoName = "xterm-ghostty"

    /// Install for `shell`, sourcing the integration from `installRoot` in `rc`. Returns
    /// true if anything was written; false on a fully-installed no-op or an unsupported
    /// shell (which is left untouched — never corrupted).
    @discardableResult
    static func install(
        shell: LoginShell = .current,
        rc: URL,
        installRoot: URL
    ) -> Bool {
        guard shell == .zsh else { return false }  // degrade gracefully; rc untouched
        let wroteFiles = installFiles(into: installRoot)
        let wroteRc = injectSource(into: rc, installRoot: installRoot)
        return wroteFiles || wroteRc
    }

    // MARK: - Integration + terminfo files

    /// Write the integration script and terminfo into `installRoot`, replacing stale
    /// generated copies while leaving byte-identical files alone. This keeps upgrades
    /// idempotent without stranding existing installations on old integration logic.
    private static func installFiles(into installRoot: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: installRoot, withIntermediateDirectories: true)
        let wroteScript = writeIfChanged(
            integrationScript, to: installRoot.appendingPathComponent(integrationName))
        let wroteTerminfo = writeIfChanged(
            terminfoSource, to: installRoot.appendingPathComponent(terminfoName))
        return wroteScript || wroteTerminfo
    }

    private static func writeIfChanged(_ content: String, to path: URL) -> Bool {
        if (try? String(contentsOf: path, encoding: .utf8)) == content { return false }
        return (try? content.write(to: path, atomically: true, encoding: .utf8)) != nil
    }

    // MARK: - rc marker block

    /// Append the source-marker block to `rc`, preserving its prior content verbatim.
    /// If the block's begin marker is already present this is a no-op — the idempotency
    /// guard, mirroring `enable-board-hooks.sh`. Returns true if the rc was written.
    private static func injectSource(into rc: URL, installRoot: URL) -> Bool {
        let existing = (try? String(contentsOf: rc, encoding: .utf8)) ?? ""
        guard !existing.contains(beginMarker) else { return false }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let updated = existing + separator + markerBlock(installRoot: installRoot)
        return (try? updated.write(to: rc, atomically: true, encoding: .utf8)) != nil
    }

    /// The idempotent source block: fenced by begin/end markers so a re-install finds
    /// its own fingerprint and no-ops (no duplicate rc lines).
    private static func markerBlock(installRoot: URL) -> String {
        let script = installRoot.appendingPathComponent(integrationName).path
        return """
        \(beginMarker)
        [ -r "\(script)" ] && source "\(script)"
        \(endMarker)

        """
    }

    // MARK: - Bundled integration payloads

    /// The bundled zsh integration: report cwd (OSC 7) and mark command boundaries
    /// (OSC 133) on every prompt so the board reads them semantically. Standalone and
    /// idempotent — sourced from the operator's rc by the marker block above.
    static let integrationScript = """
        #!/usr/bin/env zsh
        # Sich shell-integration (zsh). Reports cwd + command boundaries to the
        # terminal (OSC 7 / OSC 133) so the mission-control board reads them semantically
        # instead of scanning processes. Standalone; sourced by ShellIntegrationInstaller.

        # Keep Sich's transparent agent shims ahead of paths a user's startup
        # files may prepend. Outside a managed task terminal the shims pass through;
        # inside one they attach status hooks using SICH_CARD_ID.
        case "$PATH" in
          "$HOME/.sich/bin"|"$HOME/.sich/bin":*) ;;
          *)
            PATH="$HOME/.sich/bin:$PATH"
            ;;
        esac
        export PATH

        # OSC 7: report the working directory on every prompt.
        _sich_report_cwd() {
          printf '\\033]7;file://%s%s\\033\\\\' "${HOST}" "${PWD}"
        }

        # OSC 133;A: mark the start of each prompt so command boundaries are semantic.
        _sich_prompt_mark() {
          printf '\\033]133;A\\033\\\\'
        }

        autoload -Uz add-zsh-hook 2>/dev/null || true
        if command -v add-zsh-hook >/dev/null 2>&1; then
          add-zsh-hook precmd _sich_report_cwd
          add-zsh-hook precmd _sich_prompt_mark
        fi

        """

    /// The bundled `xterm-ghostty` terminfo source, layered on `xterm-256color` so the
    /// entry resolves even without Ghostty's full database compiled in.
    static let terminfoSource = """
        xterm-ghostty|Ghostty,
        \tuse=xterm-256color,

        """
}
