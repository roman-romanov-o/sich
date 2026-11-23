import AppKit
import SichCore

/// First-run agent setup: know which agent CLIs this Mac can start, and when none can,
/// put ``AgentSetupSheet`` in front of the board instead of letting a new card die with
/// "claude not found". A Mac that already has an agent never sees the sheet.
extension BoardShell {
    /// Rescan on activation at most this often — the user may have installed an agent
    /// from Terminal, but a login shell per focus change would be wasteful.
    static let agentRescanInterval: TimeInterval = 10

    /// Ask the user's login shell for its PATH and resolve every offered agent on it,
    /// off the main thread. A no-op (inventory stays nil = "assume all") when scanning
    /// is disabled, so tests and the E2E capture never spawn a shell.
    func refreshAgentInventory(completion: (@MainActor () -> Void)? = nil) {
        guard Self.agentScanningEnabled else { return }
        lastAgentScan = Date()
        let home = NSHomeDirectory()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shimDir = (home as NSString).appendingPathComponent(HookInstaller.codexBinDirName)
        Task.detached {
            let path = AgentInventory.loginShellPath(shell: shell)
                ?? (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            let found = AgentInventory.scan(searchPath: path, home: home, excludedDirs: [shimDir])
            await MainActor.run {
                self.applyAgentInventory(found)
                completion?()
            }
        }
    }

    func refreshAgentInventoryIfStale() {
        guard Date().timeIntervalSince(lastAgentScan) > Self.agentRescanInterval else { return }
        refreshAgentInventory()
    }

    func applyAgentInventory(_ found: [CardAgent: String]) {
        let changed = installedAgents != found
        installedAgents = found
        agentSetupSheet?.update(agentSetupStates())
        createPalette?.installedAgents = Set(found.keys)
        quota.installedAgents = Set(found.keys)
        if changed { refresh() }
    }

    /// Each offered agent's row: an install in flight (or its failure) wins over the scan.
    func agentSetupStates() -> [CardAgent: AgentSetupSheet.RowState] {
        var states: [CardAgent: AgentSetupSheet.RowState] = [:]
        for agent in AgentInventory.offered {
            if let override = agentInstallStates[agent] {
                states[agent] = override
            } else if let path = installedAgents?[agent] {
                states[agent] = .ready(path: path)
            } else {
                states[agent] = .missing
            }
        }
        return states
    }

    func presentAgentSetup() {
        guard agentSetupSheet == nil, let root = boardView.superview else { return }
        dismissCreatePalette()
        let sheet = AgentSetupSheet(states: agentSetupStates())
        sheet.onInstall = { [weak self] agent in self?.installAgent(agent) }
        sheet.onStart = { [weak self] in
            self?.dismissAgentSetup()
            self?.openCreatePalette()
        }
        sheet.onSkip = { [weak self] in self?.dismissAgentSetup() }
        agentSetupSheet = sheet
        layoutFullWindow(sheet, in: root)
        refreshAgentInventory()
    }

    func dismissAgentSetup() {
        agentSetupSheet?.removeFromSuperview()
        agentSetupSheet = nil
        boardView.window?.makeFirstResponder(boardView)
    }

    /// Run the vendor's installer, streaming its output into the row, then rescan —
    /// the row turns "ready" only once the binary really resolves for a card.
    func installAgent(_ agent: CardAgent) {
        guard Self.agentScanningEnabled else { return }
        if case .installing = agentInstallStates[agent] { return }
        agentInstallStates[agent] = .installing(line: "")
        Task.detached {
            let result = AgentInventory.runInstaller(for: agent) { line in
                Task { @MainActor in
                    guard case .installing = self.agentInstallStates[agent] else { return }
                    self.agentInstallStates[agent] = .installing(line: line)
                }
            }
            await MainActor.run {
                if result.succeeded {
                    self.agentInstallStates[agent] = nil
                    self.refreshAgentInventory { [weak self] in
                        guard let self, self.installedAgents?[agent] == nil else { return }
                        let name = AgentInventory.binaryName(for: agent)
                        self.agentInstallStates[agent] = .failed(line: "installed, but Sich can’t find `\(name)`")
                    }
                } else {
                    self.agentInstallStates[agent] = .failed(line: result.lastLine)
                }
            }
        }
    }
}
