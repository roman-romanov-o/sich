import AppKit
import GhostlingCore
import Testing

@testable import GhostlingApp

/// Panel-level coverage for the two-pool quota visibility (US-006), bound to the
/// E2E spec cases TC-E2E-201..204. These drive the REAL render path — they inject
/// stubbed source readings, run them through `QuotaProjection`, call
/// `QuotaPanel.render`, and assert on the built `[QuotaGaugeRow]` view-model
/// (titles, remaining/reset text, estimated cue, exhausted/unknown state) — so the
/// render is verified, not just the value type.
///
/// The pixel AC ("the four gauges render distinctly on screen") is intentionally
/// NOT here: a faithful screenshot + human sign-off owns that, the same loop
/// checkpoint Phase 03 used. Everything assertable headlessly is covered below.
@MainActor
@Suite("Quota panel render (US-006 — TC-E2E-201..204)")
struct QuotaPanelTests {

    private func render(_ sources: [QuotaSourceInput]) -> QuotaPanel {
        let panel = QuotaPanel(frame: NSRect(x: 0, y: 0, width: 460, height: 560))
        panel.render(gauges: QuotaProjection.gauges(from: sources))
        return panel
    }

    private func row(_ panel: QuotaPanel, pool: String) -> QuotaGaugeRow? {
        panel.rows.first { $0.gauge.pool == pool }
    }

    /// TC-E2E-201: interactive (40% window / 30% weekly used) + Agent SDK 60%
    /// remaining → TWO distinct Anthropic gauges, each its own remaining + reset,
    /// NOT merged into one number.
    @Test("both Anthropic pools render as two distinct gauges, never merged (TC-E2E-201)")
    func bothAnthropicPoolsDistinct() throws {
        let panel = render([
            QuotaSeed.interactive(remainingFraction: 0.60, reset: QuotaSeed.hoursFromNow(1.17)),
            QuotaSeed.agentSDKCredit(remainingFraction: 0.60, reset: QuotaSeed.daysFromNow(12)),
        ])
        let anthropic = panel.rows.filter { $0.gauge.provider == "anthropic" }
        // Two separate rendered subviews — not one combined gauge.
        #expect(anthropic.count == 2)
        let interactive = try #require(row(panel, pool: "interactive"))
        let sdk = try #require(row(panel, pool: "agent_sdk_credit"))
        #expect(interactive !== sdk)
        #expect(interactive.titleText.contains("interactive"))
        #expect(sdk.titleText.contains("Agent SDK"))
        // Each carries its OWN remaining + reset — proof they were not netted.
        #expect(interactive.remainingText.contains("60%"))
        #expect(sdk.remainingText.contains("60%"))
        #expect(!interactive.resetText.isEmpty)
        #expect(!sdk.resetText.isEmpty)
        // The asymmetry is already visible at the happy path: window vs hard-stop.
        #expect(interactive.gauge.fallback == .windowReset)
        #expect(sdk.gauge.fallback == .none)
    }

    /// TC-E2E-202: Codex present, Gemini absent → Codex gauge with remaining;
    /// Gemini gauge "unknown / not tracked" (state == .unknown, remaining == nil),
    /// NOT implied 100% free.
    @Test("Codex gauge present; absent Gemini shows unknown / not tracked (TC-E2E-202)")
    func codexPresentGeminiUnknown() throws {
        let panel = render([
            QuotaSeed.codex(remainingFraction: 0.40, reset: QuotaSeed.hoursFromNow(20)),
            QuotaSeed.geminiAbsent(),
        ])
        let codex = try #require(row(panel, pool: "codex"))
        let gemini = try #require(row(panel, pool: "gemini"))
        #expect(codex.gauge.state == .active)
        #expect(codex.remainingText.contains("40%"))
        // Gemini: explicit unknown — not 0, not 100%, and the text says so.
        #expect(gemini.isUnknown)
        #expect(gemini.gauge.state == .unknown)
        #expect(gemini.gauge.remainingFraction == nil)
        #expect(gemini.remainingText.contains("unknown"))
        #expect(gemini.remainingText.contains("not tracked"))
    }

    /// TC-E2E-203: an inferred interactive reading → its gauge confidence ==
    /// .estimated AND a visible "estimated" cue; a measured gauge is NOT marked.
    @Test("inferred gauge marked estimated with a visible cue; measured is not (TC-E2E-203)")
    func inferredShowsEstimatedCue() throws {
        let panel = render([
            QuotaSeed.interactive(remainingFraction: 0.55, inferred: true, reset: QuotaSeed.hoursFromNow(2)),
            QuotaSeed.agentSDKCredit(remainingFraction: 0.60, reset: QuotaSeed.daysFromNow(10)),
        ])
        let interactive = try #require(row(panel, pool: "interactive"))
        let sdk = try #require(row(panel, pool: "agent_sdk_credit"))
        #expect(interactive.gauge.confidence == .estimated)
        #expect(interactive.showsEstimatedCue)
        // The measured pool is NOT falsely down-rated.
        #expect(sdk.gauge.confidence == .measured)
        #expect(!sdk.showsEstimatedCue)
    }

    /// TC-E2E-204: Agent SDK credit = 0 (hard-stop, fallback none) + interactive
    /// locked out → both gauges .exhausted, each shows reset/refill, and the
    /// hard-stop vs window-reset asymmetry is represented (fallback none vs
    /// windowReset).
    @Test("both pools exhausted show reset/refill and the hard-stop vs window asymmetry (TC-E2E-204)")
    func exhaustedPoolsShowAsymmetry() throws {
        let panel = render([
            QuotaSeed.interactive(
                remainingFraction: 0.0, inferred: true, state: .exhausted,
                reset: QuotaSeed.hoursFromNow(3)
            ),
            QuotaSeed.agentSDKCredit(
                remainingFraction: 0.0, state: .exhausted, reset: QuotaSeed.daysFromNow(11)
            ),
        ])
        let interactive = try #require(row(panel, pool: "interactive"))
        let sdk = try #require(row(panel, pool: "agent_sdk_credit"))
        // Both unmistakably exhausted.
        #expect(interactive.isExhausted)
        #expect(sdk.isExhausted)
        #expect(interactive.remainingText.contains("exhausted"))
        #expect(sdk.remainingText.contains("exhausted"))
        // Each shows its reset/refill.
        #expect(!interactive.resetText.isEmpty)
        #expect(!sdk.resetText.isEmpty)
        // The asymmetry is represented: Agent SDK = hard-stop / no fallback;
        // interactive = window reset. With the redundant prefix gone, the VERB carries it —
        // a hard-stop credit "refills", a window you're merely waiting out comes "back".
        #expect(sdk.gauge.fallback == .none)
        #expect(sdk.resetText.contains("refills in"))
        #expect(interactive.gauge.fallback == .windowReset)
        #expect(interactive.resetText.contains("back in"))
        #expect(!interactive.resetText.contains("window"), "the 5H/WEEKLY column header already says which window this is")
    }

    /// The countdown must FIT, not just exist: at a 94 pt cell width a
    /// `"window · resets in 2h 14m"` caption ellipsized away the one part that matters.
    /// The line is now the countdown and nothing else.
    @Test("reset line surfaces a highlighted 'time left' countdown that fits the cell")
    func resetCountdownIsSurfaced() throws {
        let active = QuotaGaugeRow(gauge: QuotaGauge(
            provider: "anthropic", pool: "interactive", state: .active, confidence: .measured,
            fallback: .windowReset, remainingFraction: 0.4, reset: QuotaSeed.hoursFromNow(2.25)
        ))
        #expect(active.resetText == "in 2h 15m", "countdown only — no prefix eating the width")
        #expect(
            active.resetText.size(withAttributes: [.font: BoardTheme.monoSmall]).width
                <= QuotaLayout.cellWidth,
            "the countdown must render un-truncated inside the cell"
        )

        let exhausted = QuotaGaugeRow(gauge: QuotaGauge(
            provider: "anthropic", pool: "interactive_weekly", state: .exhausted, confidence: .measured,
            fallback: .weeklyReset, remainingFraction: 0.0, reset: QuotaSeed.hoursFromNow(30)
        ))
        #expect(exhausted.resetText.contains("back in"), "exhausted → when you're unblocked")
        #expect(exhausted.resetText.contains("1d"), "weekly-scale wait rolls up to days")
    }

    /// The percent rides inside the bar (phone-battery style) rather than on its own text
    /// row, which is what buys the countdown a full-width line in a shorter cell.
    @Test("percent is drawn inside the bar, not on a row under it")
    func percentRidesInsideTheBar() throws {
        let row = QuotaGaugeRow(gauge: QuotaGauge(
            provider: "anthropic", pool: "interactive_5h", state: .active, confidence: .measured,
            fallback: .windowReset, remainingFraction: 0.92, reset: QuotaSeed.hoursFromNow(2)
        ))
        row.layoutSubtreeIfNeeded()
        #expect(row.barLabelText == "92%")
        #expect(
            row.barLabelText.size(withAttributes: [.font: BoardTheme.gaugeLabel]).width
                <= QuotaLayout.cellWidth
        )
        // An exhausted pool can't lean on the fraction — an empty bar and a full red one
        // both need the number said out loud.
        let dry = QuotaGaugeRow(gauge: QuotaGauge(
            provider: "anthropic", pool: "interactive_5h", state: .exhausted, confidence: .measured,
            fallback: .windowReset, remainingFraction: 0.0, reset: QuotaSeed.hoursFromNow(2)
        ))
        #expect(dry.barLabelText == "0%")

        // An inferred number must never read as a measured one — the whole point of the
        // confidence split. Inside the bar that cue is a "~", doubled by the amber fill.
        let guessed = QuotaGaugeRow(gauge: QuotaGauge(
            provider: "anthropic", pool: "interactive_5h", state: .active, confidence: .estimated,
            fallback: .windowReset, remainingFraction: 0.55, reset: QuotaSeed.hoursFromNow(1)
        ))
        #expect(guessed.barLabelText == "~55%")
        #expect(guessed.showsEstimatedCue)
    }

    /// The provider column identifies each harness visually (badge) and shows its
    /// live board load — "N working" / "N waiting" — sourced from the cards the
    /// shell passes in, so pool demand renders beside pool remaining.
    @Test("provider rows show the harness badge plus its working/waiting task load")
    func providerRowsShowHarnessLoad() throws {
        func c(_ agent: CardAgent, _ state: CardState) -> BoardCard {
            BoardCard(sessionID: UUID().uuidString, projectDir: "/tmp/p",
                      agent: agent, flow: .b, state: state)
        }
        let panel = QuotaPanel(frame: NSRect(x: 0, y: 0, width: 460, height: 560))
        panel.render(
            gauges: QuotaProjection.gauges(from: [
                QuotaSeed.interactive(remainingFraction: 0.60, reset: QuotaSeed.hoursFromNow(1)),
                QuotaSeed.codex(remainingFraction: 0.40, reset: QuotaSeed.hoursFromNow(20)),
            ]),
            cards: [
                c(.claude, .running), c(.claude, .running), c(.claude, .waitingForInput),
                c(.codex, .blocked),
                c(.claude, .done),   // at rest — must not inflate the load
            ]
        )
        #expect(panel.tallies[.claude] == AgentTaskTally(working: 2, waiting: 1))
        #expect(panel.taskLines["claude"] == ["2 working", "1 waiting"])
        #expect(panel.taskLines["codex"] == ["1 waiting"])

        // Both provider rows carry a visual harness badge (glyph + tooltip), not text.
        let badges = allSubviews(of: panel).compactMap { $0 as? HarnessBadge }
        #expect(badges.contains { $0.agent == .claude && $0.toolTip == "Claude Code" })
        #expect(badges.contains { $0.agent == .codex && $0.toolTip == "Codex" })

        // A board-less render (the standalone quota window) shows no load lines.
        panel.render(gauges: [])
        #expect(panel.taskLines.values.allSatisfy { $0.isEmpty })
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }

    /// The per-minute ticker re-evaluates the countdown against the live clock —
    /// once the reset instant has passed the line collapses to "now".
    @Test("refreshReset re-evaluates the countdown against the clock")
    func refreshResetTicks() throws {
        let reset = QuotaSeed.hoursFromNow(1)
        let row = QuotaGaugeRow(gauge: QuotaGauge(
            provider: "anthropic", pool: "interactive", state: .active, confidence: .measured,
            fallback: .windowReset, remainingFraction: 0.4, reset: reset
        ))
        row.refreshReset(now: reset.addingTimeInterval(60))   // one minute past the reset
        #expect(row.resetText.contains("now"))
    }
}
