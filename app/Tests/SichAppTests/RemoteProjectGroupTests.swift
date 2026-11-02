import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// A remote card files under the repo it works in, not the box it runs on: the
/// far-side folder's leaf is its project key, so a remote `a1-os` and a local
/// `a1-os` share one lane header — and the card itself says which host and
/// folder it sits in, now that the header no longer does.
@MainActor
struct RemoteProjectGroupTests {

    private func local(_ dir: String, id: String = "local") -> BoardCard {
        BoardCard(sessionID: id, title: "local work", projectDir: dir, agent: .claude, state: .running)
    }

    private func remote(destination: String, dir: String?, id: String = "sich") -> BoardCard {
        BoardCard(
            sessionID: "remote/\(destination)/\(id)", title: "remote work",
            projectDir: destination, agent: .claude, state: .running, remoteDir: dir)
    }

    @Test func aRemoteCardGroupsWithTheLocalCheckoutOfTheSameRepo() {
        let groups = BoardView.projectGroups([
            local("/Users/roman/MyProjects/a1-os"),
            remote(destination: "roman@box.invalid", dir: "/home/roman/work/a1-os"),
        ])
        #expect(groups.map(\.label) == ["a1-os"])
        #expect(groups.first?.cards.count == 2)
    }

    @Test func differentRemoteFoldersAreDifferentProjects() {
        let groups = BoardView.projectGroups([
            remote(destination: "roman@box.invalid", dir: "/home/roman/work/a1-os", id: "a"),
            remote(destination: "roman@box.invalid", dir: "/home/roman/work/relay", id: "b"),
        ])
        #expect(groups.map(\.label) == ["a1-os", "relay"])
    }

    /// Until the far side has said where it is, the destination is all we know.
    @Test func anUnplacedRemoteCardFilesUnderItsDestination() {
        let groups = BoardView.projectGroups([remote(destination: "roman@box.invalid", dir: nil)])
        #expect(groups.map(\.label) == ["roman@box"])
    }

    @Test func aLocalCardHasNoRemotePlace() {
        #expect(local("/tmp/proj").remoteDestination == nil)
        #expect(SessionCard.remotePlace(of: local("/tmp/proj")) == nil)
    }

    /// The card face carries `host:leaf` so a remote card is still recognisably
    /// remote under a header it shares with local work.
    @Test func theCardNamesItsHostAndFolder() throws {
        let card = remote(destination: "roman@box.invalid", dir: "/home/roman/work/a1-os")
        #expect(SessionCard.remotePlace(of: card) == "roman@box:a1-os")
        let view = SessionCard(card: card, hostState: { _ in .installed })
        let place = try #require(identified("remote-place", in: view) as? NSTextField)
        #expect(place.stringValue == "roman@box:a1-os")
        #expect(place.toolTip == "roman@box.invalid:/home/roman/work/a1-os")
    }

    @Test func anUnplacedCardNamesOnlyItsHost() {
        let card = remote(destination: "roman@box.invalid", dir: nil)
        #expect(SessionCard.remotePlace(of: card) == "roman@box")
    }

    /// The host keeps its first label only — the tailnet suffix is the same on every
    /// box and was what the ellipsis ate — while a port survives and an IP is left whole.
    @Test(arguments: [
        ("roman@studio.tail00ee33.ts.net", "roman@studio"),
        ("roman@studio.tail00ee33.ts.net:2200", "roman@studio:2200"),
        ("studio.local", "studio"),
        ("box:2222", "box:2222"),
        ("roman@192.168.1.20", "roman@192.168.1.20"),
        ("roman@box", "roman@box"),
    ])
    func destinationsShortenToTheirFirstLabel(_ full: String, _ short: String) {
        #expect(BoardTheme.shortDestination(full) == short)
    }

    /// The board's own path: a card created with a start folder is shown under that
    /// folder's leaf, and its face says where it is, with nothing having reported
    /// a cwd yet. Through `createRemoteTmuxSession`, the method ⌘⇧R calls; the host
    /// is `.invalid`, so the spawned ssh dies on lookup.
    @Test func aBoardBuiltRemoteCardIsPlacedFromItsSpec() throws {
        let shell = BoardShell(seeds: [])
        let root = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }
        let spec = try #require(RemoteTmuxSpec.parse(
            destination: "roman@place.invalid", sessionName: "agent",
            remoteDir: "/srv/checkouts/a1-os"))

        let card = try #require(shell.createRemoteTmuxSession(spec: spec))
        root.layoutSubtreeIfNeeded()

        let shown = try #require(shell.displayCards().first { $0.id == card.id })
        #expect(shown.remoteDir == "/srv/checkouts/a1-os")
        #expect(BoardTheme.projectLabel(for: shown) == "a1-os")
        let view = try #require(sessionCard(for: card.id, in: root))
        let place = try #require(identified("remote-place", in: view) as? NSTextField)
        #expect(place.stringValue == "roman@place:a1-os")
    }

    // MARK: - lookup

    private func sessionCard(for id: UUID, in view: NSView) -> SessionCard? {
        if let card = view as? SessionCard, card.card.id == id { return card }
        for sub in view.subviews {
            if let found = sessionCard(for: id, in: sub) { return found }
        }
        return nil
    }

    private func identified(_ name: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == name { return view }
        for sub in view.subviews {
            if let found = identified(name, in: sub) { return found }
        }
        return nil
    }
}
