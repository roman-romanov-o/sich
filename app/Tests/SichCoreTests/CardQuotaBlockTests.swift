import Foundation
import Testing

@testable import SichCore

@Suite("Card quota block")
struct CardQuotaBlockTests {

    private func card(agent: CardAgent = .claude) -> BoardCard {
        BoardCard(sessionID: "s-1", projectDir: "/tmp/p", agent: agent, flow: .b, state: .idle)
    }

    private func gauge(
        provider: String, pool: String, remaining: Double, state: QuotaPoolState = .active
    ) -> QuotaGauge {
        QuotaGauge(
            provider: provider, pool: pool, state: state, confidence: .measured,
            fallback: .windowReset, remainingFraction: remaining, reset: nil)
    }

    @Test("exhausted pool yields quota spent block")
    func exhausted() {
        let profile = ClaudeProfile(name: "personal", configDir: "~/.claude-p")
        let gauges = [gauge(provider: "anthropic", pool: "interactive_personal", remaining: 0, state: .exhausted)]
        let block = CardQuotaAdvisor.block(
            for: card(), profileID: profile.id, claudeProfiles: [profile], gauges: gauges)
        #expect(block == .exhausted(reset: nil))
    }

    @Test("unknown gauge yields no block")
    func unknown() {
        let gauges = [QuotaGauge(
            provider: "anthropic", pool: "interactive", state: .unknown, confidence: .measured)]
        let block = CardQuotaAdvisor.block(
            for: card(), profileID: nil, claudeProfiles: [], gauges: gauges)
        #expect(block == .none)
    }

    @Test("low remaining yields pool low block")
    func lowRemaining() {
        let gauges = [gauge(provider: "anthropic", pool: "interactive", remaining: 0.10)]
        let block = CardQuotaAdvisor.block(
            for: card(), profileID: nil,
            claudeProfiles: [.defaultProfile], gauges: gauges)
        #expect(block == .low(remainingPercent: 10, reset: nil))
    }
}

@Suite("Harness handoff")
struct HarnessHandoffTests {

    @Test("handoff prompt points at the prior transcript file")
    func promptContents() {
        let prompt = HarnessHandoff.prompt(
            title: "Fix login",
            projectDir: "/tmp/app",
            priorAgent: .claude,
            priorAccountName: "personal",
            priorTranscriptPath: "/Users/me/.claude/projects/-tmp-app/s.jsonl",
            workLogTail: "2026-01-01 | agent started working",
            taskFolder: "/tmp/app/docs/tasks/task-1")
        #expect(prompt.contains("Fix login"))
        #expect(prompt.contains("personal"))
        #expect(prompt.contains("task-1"))
        #expect(prompt.contains("/Users/me/.claude/projects/-tmp-app/s.jsonl"))
        #expect(prompt.contains("read/search this file"))
        #expect(!prompt.contains("terminal output"))
        #expect(prompt.contains("continue this work"))
    }

    @Test("work log tail truncates to the last lines")
    func workLogTailTruncation() {
        let lines = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let tail = HarnessHandoff.tail(ofWorkLog: lines, maxLines: 5)
        #expect(tail.hasPrefix("line 36"))
        #expect(!tail.contains("line 1\n"))
    }
}
