import XCTest

@testable import SichApp

/// ts-int-01 / US-002.AC-1 — the hook forwarder runs on a GNU/Linux host, not only
/// on macOS: the script may name no macOS-only tool (`plutil`) and no absolute
/// `/usr/bin/…` tool path. An absolute path cannot be jailed by a test on macOS (it
/// resolves whatever PATH says), so this is the only way to prove the script does
/// not depend on the host being a Mac.
final class ForwarderPortabilityTests: XCTestCase {

    func testForwarderNamesNoMacOnlyTool() {
        let body = HookInstaller.forwarderBody
        XCTAssertFalse(
            body.contains("plutil"),
            "plutil does not exist under GNU userland")
        let absolute = body.split(separator: "\n").filter {
            $0.contains("/usr/bin/") && !$0.contains("/usr/bin/env")
        }
        XCTAssertTrue(
            absolute.isEmpty,
            "absolute macOS tool paths do not resolve on a Linux host: \(absolute)")
    }
}
