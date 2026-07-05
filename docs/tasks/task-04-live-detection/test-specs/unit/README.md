# Unit Tests

Focused specs for the tricky logic (ordering, rotation, close, watcher
invariant). Each maps to one target symbol in the matrix (`../README.md`).
Unit tests only where the logic is genuinely tricky — everything else is proven
by the integration specs.

> **Dropped in review:** TC-UNIT-004 (`seq` monotonic — unachievable, ordering
> uses `timestamp`) and TC-UNIT-011 (`ppid` distinctness — `ppid` deferred, no
> producer). Producer rotation moved to TC-PROD-005 (`../producer/`).

## TC-UNIT-003 — rotation re-arms with no loss/dup (reader, by inode)
- **Given** the reader mid-stream at offset N
- **When** `events.jsonl` rotates and a fresh file is created — including one already grown past N
- **Then** the reader detects the **inode change**, resets its offset, and continues; every event is delivered exactly once across the boundary. (Guards the `resolveStart` bug: today it only resets when `saved > fileSize`, so a fresh file already past the old offset silently skips its head.)
- **Symbol:** `HookEventTailTests.rotation_reArmsNoLossNoDup`

## TC-UNIT-012 — updatedAt tiebreak, fresh wins
- **Given** two sessions sharing a `projectDir` — one freshly `running`, one holding a stale `blocked`/`waiting`
- **When** `liveState(forDir:)` resolves the card
- **Then** the entry with the newest `HookSessionStore.Entry.updatedAt` wins; the stale state never out-ranks the fresh one. (Replaces the timestamp-free `activityRank` max at `BoardShell.swift:509`; `updatedAt` already exists at `HookSessionStore.swift:20`.)
- **Symbol:** `HookSessionStoreTests.updatedAtTiebreak_freshWins`

## TC-UNIT-013 — permission hook sets attention
- **Given** a real Claude Notification/permission hook payload
- **When** normalized by `HookNormalizer`
- **Then** it maps to `permissionRequest` → `.waitingForInput` → `needsAttention` deterministically (not inferred from silence). Guards that the *real* payload shape normalizes to `permissionRequest`, not `unknown` — no new "`question`" kind is added.
- **Symbol:** `HookNormalizerTests.permissionHook_setsAttention`

## TC-UNIT-014 — deterministic close vs hard-kill decay
- **Given** a running session
- **When** a `sessionEnd`/exit arrives → the card closes immediately (no 30s wait); **when** the process is hard-killed with no `sessionEnd` → the card decays via the long backstop.
- **Symbol:** `HookSessionStoreTests.sessionEnd_closesNow_hardKillDecays`

## TC-UNIT-021 — corrupt current snapshot falls back
- **Given** a corrupt/partial current snapshot and a valid `-previous`
- **When** the app loads at launch
- **Then** it restores from `-previous` — no blank state, no crash.
- **Symbol:** `SessionResumeTests.corruptCurrent_fallsBackToPrevious`

## TC-UNIT-022 — restore never spawns headless (watcher invariant)
- **Given** a snapshot describing a pane that had an agent running
- **When** restore runs
- **Then** the pane/shell reopens but **no `claude -p` process is spawned** (assert on the spawn path / a stubbed launcher records zero headless launches).
- **Symbol:** `SessionResumeTests.restore_neverSpawnsHeadless`
- **Guards** the product's hard watcher-not-spawner invariant.

## TC-UNIT-024 — cwd reported semantically
- **Given** shell-integration installed
- **When** a command runs
- **Then** the reported cwd comes from the integration signal, not process scanning.
- **Symbol:** `ShellIntegrationTests.cwdReportedNotInferred`

## TC-UNIT-025 — schema version mismatch ignored, never crashes
- **Given** a snapshot whose `version` is older/newer than the current build understands
- **When** the app loads it at launch
- **Then** it migrates if it can, else ignores that snapshot and starts clean — it never crashes on an unknown schema.
- **Symbol:** `SessionResumeTests.versionMismatch_ignoredNotCrash`

## TC-UNIT-026 — dead underlying process → restore as closed
- **Given** a snapshot pane whose underlying process did not survive
- **When** restore runs
- **Then** the pane is restored as **closed/dead**, not as a live-but-frozen terminal (and still no headless spawn — see TC-UNIT-022).
- **Symbol:** `SessionResumeTests.deadProcess_restoresAsClosed`
