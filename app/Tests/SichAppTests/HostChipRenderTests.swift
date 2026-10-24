import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// ts-e2e-05 / TC-E2E-016 — US-005 AC-4 and AC-7: the host chip renders each
/// install state distinctly, and clicking an actionable one asks to install.
///
/// Two rules this file obeys on purpose:
///  * the click is a **real dispatched `NSEvent`** routed through window hit
///    testing. Calling the chip's action closure would prove nothing about
///    whether a gesture can reach it — that shortcut shipped a dead Esc key
///    three times in this repo;
///  * the rendering assertions read the chip's own state (text, colour, hit
///    behaviour) rather than a bitmap. `cacheDisplay`/`CALayer.render` do not
///    faithfully composite AppKit control layers, so a capture here would be
///    non-evidence — which is also why the chip is a custom-drawn ``ChipLabel``
///    and not a stock control.
///
/// Serialized: the assertions read `RemoteHookStatus.shared`, and each test uses
/// its own `.invalid` destination so no state leaks between them. `probingEnabled`
/// stays false throughout, so nothing here can dial a host.
@MainActor
@Suite(.serialized)
struct HostChipRenderTests {

    // MARK: - AC-4: distinct renderings, and a healthy host renders nothing

    /// The chip carries only the detail — the card's project label already names
    /// the destination, and the old `user@host — detail` form truncated away the
    /// actionable half on a normal card width.
    @Test func everyProblemStateRendersItsOwnSentence() throws {
        var rendered: [RemoteHookInstallState: String] = [:]
        for state in RemoteHookInstallState.allCases where state.chipDetail != nil {
            let chip = try chip(forRemote: state, destination: "roman@render.invalid")
            rendered[state] = chip.stringValue
            #expect(!chip.stringValue.contains("roman@render.invalid"),
                    "the destination lives on the repo chip, not here")
            // The face is a short marker; the sentence is the tooltip and the
            // accessibility label, so a truncated card still says what is wrong.
            #expect(chip.toolTip?.hasPrefix(chip.status.text) == true)
            #expect(chip.accessibilityLabel() == chip.status.text)
        }

        #expect(rendered[.notInstalled] == "⚠ no hooks")
        #expect(rendered[.staleVersion] == "⚠ old hooks")
        #expect(rendered[.unknown] == "? hooks")
        #expect(Set(rendered.values).count == rendered.count)
    }

    /// A healthy remote host says nothing at all — the chip is a signal, not
    /// decoration; repeating the destination beside the identical project label
    /// was the visual noise the checklist flagged.
    @Test func aHealthyRemoteHostRendersNoChip() throws {
        let view = SessionCard(
            card: remoteCard(destination: "roman@calm.invalid"), hostState: { _ in .installed })
        #expect(hostChip(in: view) == nil)
    }

    /// The fix that must never regress: a host we could not read is NOT a healthy
    /// host. Silence would claim coverage we do not have, so `unknown` keeps a chip
    /// where `installed` has none.
    @Test func unknownIsNeverRenderedAsInstalled() throws {
        let unknown = try chip(forRemote: .unknown, destination: "roman@dark.invalid")
        let installed = SessionCard(
            card: remoteCard(destination: "roman@dark.invalid"), hostState: { _ in .installed })

        #expect(hostChip(in: installed) == nil)
        #expect(unknown.toolTip == "hook status unknown")
        // Inert: we could not read the host, so a click would be a guess.
        #expect(!unknown.status.isActionable)
    }

    /// Actionable states are the only ones that look clickable, and the tooltip
    /// names the host the click would touch — the one place the destination
    /// still appears on the chip.
    @Test func onlyActionableStatesAreTintedAndClickable() throws {
        for state in RemoteHookInstallState.allCases where state.chipDetail != nil {
            let chip = try chip(forRemote: state, destination: "roman@tint.invalid")
            let actionable = state == .notInstalled || state == .staleVersion
            #expect(chip.status.isActionable == actionable)
            #expect((chip.textColor == BoardTheme.attention) == actionable)
            #expect((chip.toolTip?.contains("click to install") == true) == actionable)
            #expect((chip.themedBackground != nil) == actionable)
            if actionable {
                #expect(chip.toolTip?.contains("roman@tint.invalid") == true)
            }
        }
    }

    /// AC-7's other half. "Nothing has reported on this card" is not a fault the
    /// operator can fix, so it must not borrow the actionable wording — and it is
    /// never left as a bare "not observed".
    @Test func aSessionSichDidNotStartSaysSoInsteadOfLookingBroken() throws {
        let card = BoardCard(
            sessionID: "local-abc", title: "someone else's shell",
            projectDir: "/tmp/proj", agent: .claude, state: .unknown)
        let chip = try #require(hostChip(in: SessionCard(card: card, hostState: { _ in .unknown })))

        #expect(chip.stringValue == "not started by Sich")
        #expect(!chip.status.isActionable)
        #expect(chip.stringValue.lowercased() != "not observed")
        #expect(!chip.stringValue.contains("hooks"))
    }

    /// A normally observed local card reports nothing — the chip is a signal, not
    /// decoration on every card.
    @Test func anObservedLocalCardCarriesNoHostChip() throws {
        let card = BoardCard(
            sessionID: "local-abc", title: "local work", projectDir: "/tmp/proj",
            agent: .claude, state: .running)
        #expect(hostChip(in: SessionCard(card: card, hostState: { _ in .installed })) == nil)
    }

    /// Reachability: the chip must appear on a card the BOARD builds, not only on
    /// one a test constructs. Green-but-unreachable is this repo's classic false
    /// pass, so this goes through `createRemoteTmuxSession` — the method ⌘⇧R calls.
    /// The host is `.invalid`, so the spawned ssh dies on lookup and the probe
    /// (disabled here anyway) never reaches anything.
    @Test func aRemoteCardTheBoardBuiltCarriesTheChip() throws {
        let shell = BoardShell(seeds: [])
        let root = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }
        let spec = try #require(RemoteTmuxSpec.parse(
            destination: "roman@chip.invalid:2200", sessionName: "agent"))

        let card = try #require(shell.createRemoteTmuxSession(spec: spec))
        root.layoutSubtreeIfNeeded()

        let view = try #require(sessionCard(for: card.id, in: root))
        let chip = try #require(hostChip(in: view))
        // AC-4's render path, checked on the view the BOARD put there: the same
        // self-painting label the repo chip is, never a stock control.
        let mounted: NSView = try #require(
            identified("host-chip", in: view), "the chip must be in the card's tree")
        #expect(mounted is ChipLabel)
        #expect(!(mounted is NSButton))
        // No probe has run, so the honest reading is "we do not know" — never
        // silence and never "installed".
        #expect(chip.stringValue == "? hooks")
        #expect(chip.toolTip == "hook status unknown")
    }

    // MARK: - AC-7: a real click installs

    @Test func aRealClickOnAnActionableChipRequestsTheInstall() throws {
        let destination = "roman@click.invalid"
        let (root, window, card) = try mounted(state: .notInstalled, destination: destination)
        defer { window.orderOut(nil) }
        let chip = try #require(hostChip(in: card))

        #expect(RemoteHookStatus.shared.lastRequestedInstall != destination)
        try click(chip, ownedByChip: true, card: card, root: root, window: window)

        #expect(RemoteHookStatus.shared.lastRequestedInstall == destination)
    }

    @Test func aRealClickAlsoUpdatesAStaleHost() throws {
        let destination = "roman@stale.invalid"
        let (root, window, card) = try mounted(state: .staleVersion, destination: destination)
        defer { window.orderOut(nil) }
        let chip = try #require(hostChip(in: card))

        try click(chip, ownedByChip: true, card: card, root: root, window: window)

        #expect(RemoteHookStatus.shared.lastRequestedInstall == destination)
    }

    /// The negative: an inert chip does not eat the gesture. The click point
    /// belongs to the card, so drill-in still works over an unknown-status chip
    /// (`installed` no longer mounts a chip at all — see the render tests above).
    @Test func anInertChipNeitherInstallsNorSwallowsTheClick() throws {
        let destination = "roman@healthy.invalid"
        let (root, window, card) = try mounted(state: .unknown, destination: destination)
        defer { window.orderOut(nil) }
        let chip = try #require(hostChip(in: card))

        try click(chip, ownedByChip: false, card: card, root: root, window: window)

        #expect(RemoteHookStatus.shared.lastRequestedInstall != destination)
    }

    // MARK: - Harness

    private func remoteCard(destination: String) -> BoardCard {
        BoardCard(
            sessionID: "remote/\(destination)/sich", title: "remote work",
            projectDir: destination, agent: .claude, state: .running)
    }

    private func chip(
        forRemote state: RemoteHookInstallState, destination: String
    ) throws -> HostChip {
        let view = SessionCard(card: remoteCard(destination: destination), hostState: { _ in state })
        return try #require(hostChip(in: view))
    }

    private func sessionCard(for id: UUID, in view: NSView) -> SessionCard? {
        if let card = view as? SessionCard, card.card.id == id { return card }
        for sub in view.subviews {
            if let found = sessionCard(for: id, in: sub) { return found }
        }
        return nil
    }

    /// Type-erased lookup, so the render-path assertions are a real runtime check
    /// on the mounted view rather than a cast the compiler folds away.
    private func identified(_ name: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == name { return view }
        for sub in view.subviews {
            if let found = identified(name, in: sub) { return found }
        }
        return nil
    }

    private func hostChip(in view: NSView) -> HostChip? {
        if let chip = view as? HostChip { return chip }
        for sub in view.subviews {
            if let found = hostChip(in: sub) { return found }
        }
        return nil
    }

    /// A real window with a laid-out card in it — the only place hit testing means
    /// anything.
    private func mounted(
        state: RemoteHookInstallState, destination: String
    ) throws -> (root: NSView, window: NSWindow, card: SessionCard) {
        let card = SessionCard(card: remoteCard(destination: destination), hostState: { _ in state })
        card.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(card)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = root
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
        ])
        window.makeKeyAndOrderFront(nil)
        root.layoutSubtreeIfNeeded()
        return (root, window, card)
    }

    /// Dispatch a genuine left-click at the chip's centre and check who owns that
    /// point first — an actionable chip must claim it, an inert one must let the
    /// gesture fall through to the card so drill-in still works over it.
    private func click(
        _ chip: HostChip, ownedByChip: Bool, card: SessionCard, root: NSView, window: NSWindow
    ) throws {
        root.layoutSubtreeIfNeeded()
        #expect(chip.bounds.width > 0 && chip.bounds.height > 0)
        let center = chip.convert(NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil)
        let hit = try #require(root.hitTest(center))
        if ownedByChip {
            #expect(hit === chip, "an actionable chip must own its click point")
        } else {
            #expect(hit !== chip, "an inert chip must not claim the click")
            #expect(hit.isDescendant(of: card), "the click must still land on the card")
        }
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        window.sendEvent(event)
    }
}
