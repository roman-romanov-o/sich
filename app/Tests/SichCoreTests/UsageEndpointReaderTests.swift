import Foundation
import Testing

@testable import SichCore

/// Decode + projection for the real usage endpoint (`GET /api/oauth/usage`). These
/// pin the pure half — payload → interactive `QuotaSourceInput` — over a RECORDED
/// payload (the keychain/network I/O is not exercised here; that path degrades to
/// the local estimate on failure and is covered by the poller's fallback).
@Suite("Usage endpoint decode (real /usage source)")
struct UsageEndpointReaderTests {

    /// A trimmed but faithful capture of a live `/api/oauth/usage` 200 body.
    private let payload = Data("""
    {"five_hour":{"utilization":5.0,"resets_at":"2026-06-27T19:49:59.076134+00:00"},
     "seven_day":{"utilization":32.0,"resets_at":"2026-06-28T23:59:59.076155+00:00"},
     "seven_day_sonnet":{"utilization":2.0,"resets_at":"2026-06-29T00:00:00.076162+00:00"}}
    """.utf8)

    @Test("weekly binds when it has less headroom; reading is measured, not estimated")
    func weeklyBinds() throws {
        let source = try #require(UsageEndpointReader.interactiveSource(from: payload))
        #expect(source.provider == "anthropic")
        #expect(source.pool == "interactive")
        let r = source.reading
        #expect(r.available)
        #expect(r.inferred == false)                       // → gauge renders "measured"
        #expect(r.state == .active)
        // 32% used weekly is tighter than 5% used window → weekly binds.
        #expect(abs((r.remainingFraction ?? -1) - 0.68) < 1e-9)
        #expect(r.refillKind == .weekly)
        // reset = the binding (weekly) constraint's reset, not the window's.
        let expected = ISO8601DateFormatter().date(from: "2026-06-28T23:59:59Z")
        #expect(abs((r.reset ?? .distantPast).timeIntervalSince(expected!)) < 1.0)
    }

    @Test("window binds when it is the tighter constraint")
    func windowBinds() throws {
        let data = Data("""
        {"five_hour":{"utilization":90.0,"resets_at":"2026-06-27T19:49:59Z"},
         "seven_day":{"utilization":40.0,"resets_at":"2026-06-28T23:59:59Z"}}
        """.utf8)
        let r = try #require(UsageEndpointReader.interactiveSource(from: data)).reading
        #expect(abs((r.remainingFraction ?? -1) - 0.10) < 1e-9)  // 90% used window binds
        #expect(r.refillKind == .rollingWindow)
    }

    @Test("100% utilization reads as exhausted")
    func exhausted() throws {
        let data = Data("""
        {"five_hour":{"utilization":20.0,"resets_at":"2026-06-27T19:49:59Z"},
         "seven_day":{"utilization":100.0,"resets_at":"2026-06-28T23:59:59Z"}}
        """.utf8)
        let r = try #require(UsageEndpointReader.interactiveSource(from: data)).reading
        #expect(r.remainingFraction == 0.0)
        #expect(r.state == .exhausted)
    }

    @Test("garbage / missing constraints → nil so the caller falls back to the estimate")
    func malformedFallsBack() {
        #expect(UsageEndpointReader.interactiveSource(from: Data("not json".utf8)) == nil)
        #expect(UsageEndpointReader.interactiveSource(from: Data(#"{"five_hour":{}}"#.utf8)) == nil)
    }
}
