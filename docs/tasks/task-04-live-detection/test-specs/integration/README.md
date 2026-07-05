# Integration Tests

Cross-module specs (tail → normalizer → store → board). Given/When/Then; each
maps to one target symbol in the matrix (`../README.md`).

## TC-INT-001 — incremental read returns only appended events
- **Given** an `events.jsonl` already read to offset N
- **When** one event is appended and `readNew()` runs
- **Then** exactly that event is returned and the offset advances by its byte length (the file head is not re-read).
- **Symbol:** `HookEventTailTests.readNew_returnsOnlyAppendedEvents`
- **Proves:** US-001 incremental read (Phase 01 Step 1).

## TC-INT-002 — FS write triggers a read without the backstop
- **Given** the DispatchSource file-watch is armed and the backstop timer is stubbed/disabled
- **When** an event is appended to `events.jsonl`
- **Then** the feed performs a read (assert the source handler fired), proving event-driven delivery independent of the timer.
- **Symbol:** `SessionsFeedTests.fsWrite_triggersReadWithoutBackstop`
- **Proves:** US-001 ≤250ms/event-driven (Phase 01 Step 2). *Assert the fire, not wall-clock latency.*

## TC-INT-010 — dropped Stop recovered via JSONL fallback
- **Given** a session in `running` and a hook stream missing its `Stop`
- **When** the JSONL transcript tail contains the terminal transition and reconciliation runs
- **Then** the card leaves `running` (recovered), with no duplicate Stop (dedupe by `sessionID` + `timestamp`).
- **Symbol:** `ReconcilerTests.droppedStop_recoveredViaJSONL`
- **Proves:** US-002 dropped-hook recovery (Phase 02 Step 1).

## TC-INT-015 — board re-renders while drilled in
- **Given** `focusedCardID != nil` (drilled into a terminal)
- **When** `applySessions` receives a state change for any session
- **Then** the board re-renders (no early return); the focused surface is not disturbed.
- **Symbol:** `BoardShellTests.applySessions_rendersWhileFocused`
- **Proves:** US-005 (Phase 02 Step 5).

## TC-INT-020 — snapshot written on quit, restored on launch
- **Given** open panes with known cwd + session identity
- **When** the app quits then relaunches with a valid snapshot
- **Then** the pane tree is restored matching the pre-quit layout (cwd + identity).
- **Symbol:** `SessionResumeTests.quitWritesSnapshot_launchRestores`
- **Proves:** US-003 AC1/AC2 (Phase 03 Step 1).

## TC-INT-023 — shell-integration install is idempotent, preserves rc
- **Given** an existing shell rc
- **When** install runs twice
- **Then** the integration + terminfo are present, the rc's prior content is intact, and no duplicate block is added.
- **Symbol:** `ShellIntegrationInstallTests.install_idempotent_preservesRc`
- **Proves:** US-004 AC2 (Phase 03 Step 2).
