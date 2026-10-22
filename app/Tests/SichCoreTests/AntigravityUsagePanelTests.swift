import Foundation
import Testing
@testable import SichCore

/// `AntigravityUsagePanel` against the "Models & Quota" page as DESCRIBED by the
/// `agy` changelog (per-model buckets, `Disabled` rows without a bar). The probe
/// has not yet captured the real page (needs a signed-in `agy`); the parser is
/// deliberately generic, so these tests pin the contract, not the pixels.
struct AntigravityUsagePanelTests {
    private let now = Date(timeIntervalSince1970: 1_756_000_000)

    private var legacyPanel: String {
        """
        ╭──────────────────────────────────────────────────────────────╮
        │ Models & Quota                                                │
        │                                                               │
        │ Gemini 3 Pro        ████████░░░░░░░░░░░░  38% used   resets in 2h 13m │
        │ Gemini 3 Flash      ██░░░░░░░░░░░░░░░░░░  10% used   resets in 4h 50m │
        │ Claude Opus 4.5     ████████████████░░░░  81% used   resets in 1h 5m  │
        │ GPT-OSS             Disabled                                   │
        │                                                               │
        │ Esc to close                                                  │
        ╰──────────────────────────────────────────────────────────────╯
        """
    }

    private var liveAgyPanel: String {
        """
        └ Models & Quota
          Account: user@example.com
        GEMINI MODELS
          Models within this group: Gemini Flash, Gemini Pro
          Weekly Limit Remaining
            [███████████████████████████████████████████████░░░] 94.99%
            95% remaining · Refreshes in 167h 53m
        CLAUDE AND GPT MODELS
          Models within this group: Claude Opus, Claude Sonnet, GPT-OSS
          Weekly Limit Remaining
            [██████████████████████████████████████████████████] 100.00%
            Quota available
          │Within each group, models share a weekly limit. Quota is consumed
          │proportionally to the cost of the tokens.
          ↑/↓ Scroll · pgup/pgdown Page · ctrl+end Bottom · ctrl+home Top · esc Close
        """
    }

    @Test func parsesLiveAgyMultiLineBlocks() throws {
        let reading = try #require(AntigravityUsagePanel.parse(screen: liveAgyPanel, now: now))
        #expect(reading.buckets.count == 2)
        #expect(reading.buckets[0].label == "Gemini Models")
        #expect(abs(reading.buckets[0].usedPercent - 5.01) < 0.001)
        #expect(reading.buckets[0].resetsAt == now.addingTimeInterval(167 * 3600 + 53 * 60))

        #expect(reading.buckets[1].label == "Claude And Gpt Models")
        #expect(reading.buckets[1].usedPercent == 0.0)
        #expect(reading.buckets[1].resetsAt == nil)

        #expect(reading.tightest?.label == "Gemini Models")
        let src = AntigravityUsagePanel.source(from: reading)
        #expect(src.provider == "antigravity" && src.pool == "antigravity")
        #expect(src.reading.inferred == false && src.reading.available == true)
        #expect(abs((src.reading.remainingFraction ?? 0) - 0.9499) < 0.001)
        #expect(src.reading.refillKind == .weekly)
        #expect(src.reading.reset == now.addingTimeInterval(167 * 3600 + 53 * 60))

        let display = AntigravityUsagePanel.displaySources(from: reading)
        #expect(display.first?.pool == "antigravity_weekly")
    }

    @Test func parsesScreenshotWithMultipleModelGroupsAndWeeklyLimits() throws {
        let screenshotText = """
        GEMINI MODELS
          Models within this group: Gemini Flash, Gemini Pro

          Weekly Limit Remaining
            [██████████████████████████████░░░░░░░░░░░░░░░░░░░░] 75.47%
            75% remaining · Refreshes in 150h 50m

        CLAUDE AND GPT MODELS
          Models within this group: Claude Opus, Claude Sonnet, GPT-OSS

          Weekly Limit Remaining
            [██████████████████████████████████████████████████] 100.00%
            Quota available

        │Within each group, models share a weekly limit. Quota is consumed
        │proportionally to the cost of the tokens.
        """
        let reading = try #require(AntigravityUsagePanel.parse(screen: "Models & Quota\n" + screenshotText, now: now))
        #expect(reading.buckets.count == 2)
        #expect(reading.buckets[0].label == "Gemini Models")
        #expect(abs(reading.buckets[0].usedPercent - 24.53) < 0.001)
        #expect(reading.buckets[0].refillKind == .weekly)
        #expect(reading.buckets[0].resetsAt == now.addingTimeInterval(150 * 3600 + 50 * 60))

        #expect(reading.buckets[1].label == "Claude And Gpt Models")
        #expect(reading.buckets[1].usedPercent == 0.0)
        #expect(reading.buckets[1].refillKind == .weekly)

        #expect(reading.tightest?.label == "Gemini Models")
        let src = AntigravityUsagePanel.source(from: reading)
        #expect(abs((src.reading.remainingFraction ?? 0) - 0.7547) < 0.001)
        #expect(src.reading.refillKind == .weekly)
    }

    @Test func parsesDistinctLimitTypesPerModelGroup() throws {
        let mixedPanel = """
        Models & Quota
        GEMINI MODELS
          Daily Limit Remaining
            [████████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░] 50.00%
            50% remaining · Resets in 3h 30m
        CLAUDE AND GPT MODELS
          Weekly Limit Remaining
            [████████████████████████████████████████░░░░░░░░░░] 80.00%
            80% remaining · Refreshes in 120h 0m
        """
        let reading = try #require(AntigravityUsagePanel.parse(screen: mixedPanel, now: now))
        #expect(reading.buckets.count == 2)
        #expect(reading.buckets[0].refillKind == .rollingWindow)
        #expect(reading.buckets[1].refillKind == .weekly)

        let display = AntigravityUsagePanel.displaySources(from: reading)
        #expect(display.contains(where: { $0.pool == "antigravity_5h" }))
        #expect(display.contains(where: { $0.pool == "antigravity_weekly" }))
    }

    @Test func parsesLegacySingleLineMeteredBucketsAndSkipsDisabled() throws {
        let reading = try #require(AntigravityUsagePanel.parse(screen: legacyPanel, now: now))
        #expect(reading.buckets.map(\.label) == ["Gemini 3 Pro", "Gemini 3 Flash", "Claude Opus 4.5"])
        #expect(reading.buckets.map(\.usedPercent) == [38, 10, 81])
        #expect(reading.buckets[0].resetsAt == now.addingTimeInterval(2 * 3600 + 13 * 60))
    }

    @Test func tightestBucketDrivesTheGauge() throws {
        let reading = try #require(AntigravityUsagePanel.parse(screen: legacyPanel, now: now))
        #expect(reading.tightest?.label == "Claude Opus 4.5")
        let src = AntigravityUsagePanel.source(from: reading)
        #expect(src.provider == "antigravity" && src.pool == "antigravity")
        #expect(src.reading.inferred == false && src.reading.available == true)
        #expect(abs((src.reading.remainingFraction ?? 0) - 0.19) < 0.001)
        #expect(src.reading.refillKind == .rollingWindow)
        #expect(src.reading.reset == now.addingTimeInterval(3600 + 5 * 60))
        #expect(QuotaProjection.gauge(for: src).state == .active)
    }

    @Test func remainingPhrasingIsInvertedToUsed() throws {
        let screen = "Models & Quota\nGemini 3 Pro   25% left   resets in 30m\n"
        let reading = try #require(AntigravityUsagePanel.parse(screen: screen, now: now))
        #expect(reading.buckets.first?.usedPercent == 75)
    }

    @Test func fullyUsedBucketIsExhausted() throws {
        let screen = "Models & Quota\nGemini 3 Pro   100% used\n"
        let reading = try #require(AntigravityUsagePanel.parse(screen: screen, now: now))
        #expect(AntigravityUsagePanel.source(from: reading).reading.state == .exhausted)
    }

    @Test func nonQuotaScreenOrNoBucketsIsNil() {
        #expect(AntigravityUsagePanel.parse(screen: "Welcome to Antigravity\n? for shortcuts", now: now) == nil)
        #expect(AntigravityUsagePanel.parse(screen: "Models & Quota\nGPT-OSS  Disabled\n", now: now) == nil)
    }

    @Test func probeSpecStaysInteractiveAndAcceptsTheTrustDialog() {
        let spec = AntigravityUsageProbe.spec
        #expect(spec.launch == "agy")
        #expect(!spec.launch.contains("-p") && !spec.launch.contains("--print"))
        #expect(spec.readyMarkers == ["? for shortcuts"])
        #expect(spec.trustPrompt == "trust this folder")
    }
}
