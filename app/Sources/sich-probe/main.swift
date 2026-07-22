import Foundation
import SichCore

// A runnable, headless demonstration of the Phase 01 keystone: open a managed
// session on a command, read its pty output in-process via libghostty-vt, and
// print the rendered screen. Every launch passes the pool firewall first.
//
// Usage:  swift run sich-probe [command [args...]]
//         (defaults to `/bin/echo hello from sich`)

let argv = Array(CommandLine.arguments.dropFirst())

// `swift run sich-probe quota` — exercise the REAL live-usage path end to end
// (keychain token → GET /api/oauth/usage → decode), to confirm our binary can read
// the cross-app keychain item. Prints the resulting interactive reading or "fell back".
if argv.first == "quota" {
    let token = UsageEndpointReader.keychainToken()
    print("keychain token: \(token == nil ? "DENIED/absent" : "read OK (\(token!.count) chars)")")
    if let data = await UsageEndpointReader.fetch(), let src = UsageEndpointReader.interactiveSource(from: data) {
        let r = src.reading
        let pct = r.remainingFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        print("interactive: MEASURED (live endpoint) · remaining \(pct) "
            + "· \(r.refillKind.rawValue) · reset \(r.reset.map { "\($0)" } ?? "—")")
    } else {
        print("interactive: fell back to local estimate (endpoint unreachable / token denied)")
    }
    exit(0)
}

// `swift run sich-probe usage` — one full hidden-pty `/usage` scrape end to
// end (spawn claude → trust/ready → type /usage → parse panel): the manual smoke
// for the shipped measured-quota path. Prints the parsed reading or the fallback.
if argv.first == "usage" {
    ClaudeUsageProbe.spawningEnabled = true
    print("scraping /usage via hidden pty (up to ~75s)...")
    if let r = ClaudeUsageProbe.scrape() {
        print("session: \(r.sessionUsedPercent)% used · resets \(r.sessionResetsAt.map { "\($0)" } ?? "—")")
        print("week:    \(r.weekUsedPercent)% used · resets \(r.weekResetsAt.map { "\($0)" } ?? "—")")
        let src = ClaudeUsagePanel.interactiveSource(from: r)
        let pct = src.reading.remainingFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        print("interactive: MEASURED (usage scrape) · remaining \(pct) · \(src.reading.refillKind.rawValue)")
        exit(0)
    }
    print("scrape failed — the gauge would fall back to the JSONL estimate")
    exit(1)
}

// `swift run sich-probe codex` — read the real on-disk Codex rate-limit
// telemetry end to end (newest rollout → last rate_limits → mapped source).
if argv.first == "codex" {
    if let src = CodexUsageReader.source() {
        let r = src.reading
        let pct = r.remainingFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        print("codex: MEASURED (rollout telemetry) · remaining \(pct) "
            + "· \(r.refillKind.rawValue) · reset \(r.reset.map { "\($0)" } ?? "—")")
        exit(0)
    }
    print("codex: no rollout telemetry found — the gauge stays unknown")
    exit(1)
}

let command = argv.isEmpty ? ["/bin/echo", "hello from sich"] : argv

do {
    let session = try PTYSession(command: command)
    try session.start()
    let bytes = session.drainToEOF()
    session.finish()

    let screen = try session.terminal.plainText()
    print("---- in-process PTY read: \(bytes) bytes (pool: \(session.pool)) ----")
    print(screen)
    print("----------------------------------------------------------------")
} catch let violation as PoolViolation {
    FileHandle.standardError.write(Data("pool firewall: \(violation)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
