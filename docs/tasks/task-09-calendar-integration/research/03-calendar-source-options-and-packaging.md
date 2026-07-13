# Research: Calendar data source options and the packaging problem

**Date:** 2026-07-08
**Status:** Complete
**Researcher:** Sahaidachny Research Agent

## Summary

EventKit is the right source: native, read-only-capable, covers Google/Exchange/iCloud accounts already configured in macOS Calendar, no network code, no webview. The real obstacle is packaging: ghostling is a bare SwiftPM executable run via `swift run` — no `.app` bundle, no `Info.plist`, no entitlements anywhere in `app/` — and modern macOS TCC calendar access requires a usage-description string and attributes consent to a responsible process. The sibling `macos-flow` repo contributes **nothing** for calendars: it has no calendar code at all (the memory-note framing "calendar/todoist-sync engine" is wrong — it is a Pomodoro engine plus a *Todoist* sync blueprint).

## Research Questions

1. EventKit vs Google Calendar API vs reusing `macos-flow` — which fits the constraints (native AppKit, watcher-not-spawner, no webviews)?
2. Can the current build/run story (`swift run ghostling`, SwiftPM executable) obtain calendar permission at all?
3. What does `macos-flow` actually offer?

## Key Findings

### 1. The app is an unbundled SwiftPM executable — the hard part of EventKit is TCC, not code

**Evidence:** `app/Package.swift` — `platforms: [.macOS(.v13)]`, plain `.executableTarget(name: "ghostling", ...)`; `find app -name Info.plist -o -name "*.entitlements"` finds none outside the vendored `ghostty-vt.xcframework` and `.build/` dSYMs. `README.md` documents no bundling step; the product is run as a SwiftPM binary.

**Implication:** On macOS 14+ (Sonoma/Sequoia), `EKEventStore.requestFullAccessToEvents` requires `NSCalendarsFullAccessUsageDescription` in the process's Info.plist; a binary without one gets an immediate denial/crash-on-request. For an unbundled executable the string must be embedded via linker flags (`-sectcreate __TEXT __info_plist Info.plist`), which SwiftPM allows through `linkerSettings: [.unsafeFlags(...)]` on the executable target. Additionally, TCC attributes the consent prompt to the *responsible process* — for `swift run` that is the invoking terminal app, so the permission grant may land on Ghostty/Terminal rather than ghostling, and behave differently between `swift run` and direct binary invocation. **These specifics (embedded-plist sufficiency per macOS version, responsible-process attribution under `swift run`) must be verified by a spike on the operator's actual OS before planning commits to EventKit.** The clean long-term fix is a real `.app` bundle — a packaging step this project will need eventually anyway (Dock icon, notifications, login item).

### 2. EventKit fits every product constraint; note there is no "free/busy-only" permission tier

**Evidence:** Apple EventKit API surface (macOS 14+): access levels are *full access* and *write-only* — there is no read-only or free/busy-only tier on macOS (unlike iOS 17's granular calendar options, which also don't include free/busy-only). Task-06's contract wants free/busy only (`task-description.md` ~line 135).

**Implication:** The *process* will technically be able to read titles/attendees even though the *product contract* forbids using them. The privacy boundary must therefore be enforced in our own adapter type — strip to `[start, end, allDay, calendarSource]` at the EventKit boundary, never persist or log event content — and stated in a DD. This is acceptable (same trust model as reading `~/.claude` transcripts) but should be an explicit, testable invariant: the `GhostlingCore` availability type simply has no fields for titles.

### 3. Google Calendar API is dominated by EventKit for this product

**Evidence:** product constraints (native, local-first, no webviews — `docs/tasks/task-06-proactive-mission-control/task-description.md` forbids reading event content by default; DD-001 in task-01 chose native AppKit; OAuth web flows would need a browser round-trip); EventKit already surfaces Google accounts the user adds to macOS Calendar/Internet Accounts.

**Implication:** A direct Google API integration buys nothing unless the operator's calendar is *not* in macOS Calendar.app: it adds OAuth client management, token storage, network failure modes, and Google-side quota — to fetch data EventKit can deliver locally with zero network code. Reject unless the one open question (below) answers "my calendar is not and will not be in Calendar.app". Even then, prefer adding the Google account to macOS Calendar over writing an API client.

### 4. `macos-flow` has NO calendar capability — do not plan around reusing it for this task

**Evidence:** `~/MyProjects/macos-flow` exists; full grep for `calendar|eventkit|todoist` hits only `docs/tasks/task-02-todoist-sync/**` (planning docs for Todoist task sync, unimplemented blueprint). Source is `MacOSFlow/Engine/{PomodoroState,TimerEngine}.swift`, menu-bar/overlay views, notification/hotkey services. It *does* have `MacOSFlow.entitlements` + `Info.plist` + an Xcode project — i.e., it is properly bundled, unlike ghostling.

**Implication:** `macos-flow` is relevant to task-09 only as (a) the accepted DD-002 loose-coupling precedent (sibling app → local log → kanban tails it) and (b) an example of a bundled macOS app in this ecosystem. Routing calendar data *through* macos-flow (teaching the Pomodoro app EventKit and having the kanban tail its log) would add a moving part for no benefit — the kanban can read EventKit itself; watcher-not-spawner constrains spawning agents, not reading the OS calendar store.

### 5. Fallback source requiring zero TCC work exists: manual free-until

**Evidence:** task-06 Phase A (`task-description.md` ~line 1113): "Manual `available until` / absence input; no inferred calendar-free claim", with `ManualAssertion` semantics (§6.2 "Manual assertions").

**Implication:** The manual path is not a degraded afterthought — it is the *specified first phase* and needs no permissions, no bundle, no EventKit. If the TCC spike fails or drags, task-09 still ships value: the availability row + advisor awareness driven by a typed-in "free until 14:00".

## Validated Assumptions

| Assumption | Status | Evidence |
|------------|--------|----------|
| Sibling `macos-flow` exists | Confirmed | `~/MyProjects/macos-flow` present |
| `macos-flow` offers a reusable calendar/sync engine | Incorrect | No calendar code; only Pomodoro engine + Todoist-sync *planning docs* |
| The app can just call EventKit | Partial | API yes; TCC consent for an unbundled `swift run` binary is unverified and likely fragile |
| Google Calendar needs its own API integration | Incorrect (probably) | EventKit reads Google accounts configured in macOS Calendar; needs user confirmation of their setup |
| No webviews constraint blocks OAuth flows | Confirmed | Native-AppKit stance (DD-001, task-05 "explicitly NO webview") makes browser-based OAuth unattractive |

## Risks Identified

### 1. TCC/packaging spike fails for unbundled binary (Severity: High, blocking for the EventKit path)

**Description:** Embedded-Info.plist + responsible-process behavior under `swift run` is folklore-level territory that changes across macOS releases; the operator runs a recent macOS.

**Mitigation:** Phase 0 spike (like the libghostty Phase 00 spike): tiny EventKit probe target, test (a) direct binary, (b) `swift run`, (c) minimal `.app` wrapper script. Decide bundle-or-not on evidence. Budget the `.app` wrapper as the likely outcome.

### 2. Full-access permission over-grants relative to the free/busy contract (Severity: Medium)

**Description:** macOS offers no free/busy-only read permission; the OS prompt will say "full calendar access".

**Mitigation:** Strip at the adapter boundary (no title fields in the core type); document in a DD; surface in-app copy that only busy intervals are used.

### 3. Delegate/subscribed calendars and multiple accounts (Severity: Low)

**Description:** Busy-union must span all calendars the user considers binding; subscribed/holiday calendars may pollute busy time (all-day events are busy by default per task-06).

**Mitigation:** Per-calendar include toggle (default: all writable + selected subscribed), stored locally.

## Dependencies Discovered

- `EventKit.framework` — system framework, no package dependency; link from `GhostlingApp` (keep `GhostlingCore` EventKit-free for testability).
- Possibly a `.app` bundling script (new `scripts/` step) if the spike says unbundled TCC is unreliable.

## Open Questions

- [ ] Is the operator's working calendar (Google?) configured in macOS Calendar.app? (Determines whether EventKit alone suffices — one question to the user.)
- [ ] Spike result: does an embedded-Info.plist unbundled binary get a usable TCC calendar prompt on the operator's macOS version, and does `swift run` attribution break it?
- [ ] Does `EKEventStoreChanged` fire for subscribed/CalDAV calendars promptly, or is a slow poll needed as backstop?

## Recommendations

### Proceed With
EventKit read-only free/busy adapter in `GhostlingApp`, preceded by a small TCC/packaging spike; manual free-until input as the always-available fallback and first deliverable.

### Avoid
Direct Google Calendar API client; routing calendar through `macos-flow`; any event *writing*; reading titles/attendees into core types.

### Consider
Making the `.app` bundle wrapper its own small deliverable — several future features (notifications for attention events, login item) will hit the same wall.

## References

- `app/Package.swift`
- `~/MyProjects/macos-flow/MacOSFlow/` (engine + entitlements layout)
- `docs/tasks/task-02-estimation/design-decisions/DD-002-pomodoro-integration-coupling.md`
- `docs/tasks/task-06-proactive-mission-control/task-description.md` §6.2, §17
