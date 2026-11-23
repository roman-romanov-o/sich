import Foundation

/// Which coding-agent CLIs this Mac can actually run — the question a first launch
/// must answer before it lets anyone create a card. A card names its agent through
/// the Sich shim (`~/.sich/bin/<agent>`), and the shim resolves the real binary by
/// walking the card shell's PATH and then the directories the official installers
/// write to (``installDirs(home:)``). Detection walks the SAME list, so "installed"
/// here means "a card can start it", not merely "a file exists somewhere".
///
/// Sign-in is deliberately not checked: every agent runs its own login on first
/// launch inside the card's terminal, which is a better onboarding than any we could
/// draw — and it avoids reading another app's keychain item.
public enum AgentInventory {
    /// The agents Sich can set up, in the order a new user should meet them.
    public static let offered: [CardAgent] = [.claude, .codex, .cursor, .antigravity]

    /// The executable each agent's official installer puts on disk.
    public static func binaryName(for agent: CardAgent) -> String {
        switch agent {
        case .claude: return "claude"
        case .codex: return "codex"
        case .cursor: return "agent"
        case .antigravity: return "agy"
        case .gemini: return "gemini"
        }
    }

    /// The vendor's own one-line installer. Each one is non-interactive and writes
    /// to `~/.local/bin`, so it needs neither Homebrew, npm, nor `sudo`.
    public static func installCommand(for agent: CardAgent) -> String {
        switch agent {
        case .claude: return "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: return "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
        case .cursor: return "curl https://cursor.com/install -fsS | bash"
        case .antigravity: return "curl -fsSL https://antigravity.google/cli/install.sh | bash"
        case .gemini: return "npm install -g @google/gemini-cli"
        }
    }

    /// Where the installers put binaries, searched after PATH. A fresh macOS shell has
    /// none of `~/.local/bin` on PATH, so without this an agent installed a second ago
    /// would still be "not found". Keep in sync with the shims' search loop.
    public static func installDirs(home: String) -> [String] {
        ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// The first executable `binaryName(for:)` on `searchPath` + ``installDirs(home:)``,
    /// skipping `excludedDirs` (Sich's own shim directory, which would find itself).
    public static func locate(
        _ agent: CardAgent,
        searchPath: [String],
        home: String,
        excludedDirs: Set<String>,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let name = binaryName(for: agent)
        for dir in searchPath + installDirs(home: home) where !dir.isEmpty {
            if excludedDirs.contains(standardized(dir)) { continue }
            let candidate = (dir as NSString).appendingPathComponent(name)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// Every offered agent that resolves, mapped to its binary.
    public static func scan(
        searchPath: [String],
        home: String,
        excludedDirs: Set<String>,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [CardAgent: String] {
        var found: [CardAgent: String] = [:]
        for agent in offered {
            found[agent] = locate(agent, searchPath: searchPath, home: home,
                                  excludedDirs: excludedDirs, isExecutable: isExecutable)
        }
        return found
    }

    static let pathMarker = "__SICH_PATH__"

    /// The PATH a card's shell will see. A Finder-launched app inherits launchd's bare
    /// PATH, while a card runs an interactive login shell that reads the user's rc
    /// files — where npm, nvm and Homebrew add themselves. Asking that same shell is the
    /// only faithful answer. Returns nil when the shell fails or outlives `timeout`
    /// (a slow or broken rc file must never hold up the app).
    public static func loginShellPath(shell: String, timeout: TimeInterval = 5) -> [String]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '\\n\(pathMarker)%s\\n' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return parsePath(fromShellOutput: text)
    }

    /// The marked PATH line out of whatever else the rc files printed.
    static func parsePath(fromShellOutput text: String) -> [String]? {
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix(pathMarker) }) else {
            return nil
        }
        let value = line.dropFirst(pathMarker.count)
        return value.split(separator: ":").map(String.init)
    }

    /// Run `agent`'s official installer to completion — call off the main thread.
    /// `onLine` receives each non-empty output line (stdout and stderr merged) so the
    /// caller can show live progress; the result carries the last one, which is what
    /// an installer prints when it fails. stdin is closed: an installer that stops to
    /// ask a question fails fast instead of hanging an invisible process.
    public static func runInstaller(
        for agent: CardAgent,
        onLine: @escaping @Sendable (String) -> Void
    ) -> (succeeded: Bool, lastLine: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", installCommand(for: agent)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let last = LastLine()
        output.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = Self.strippingEscapes(String(line)).trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                last.set(trimmed)
                onLine(trimmed)
            }
        }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return (false, error.localizedDescription)
        }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        return (process.terminationStatus == 0, last.get())
    }

    /// Installers colour their output; the setup sheet shows plain text.
    static func strippingEscapes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    private final class LastLine: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func set(_ line: String) { lock.lock(); value = line; lock.unlock() }
        func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func standardized(_ dir: String) -> String {
        (dir as NSString).standardizingPath
    }
}
