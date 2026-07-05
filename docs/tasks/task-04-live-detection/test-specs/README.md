# Test Specifications

Every acceptance criterion binds to exactly one named `TC-*` case; the
execution-dod gate binds these back to green test symbols. Timing ACs are
asserted deterministically ("read fired on write"), never by wall-clock.

> **Ground-truth correction (post-review):** dropped **TC-UNIT-004** (global
> monotonic `seq` — the stateless forwarder can't produce it; ordering uses the
> existing `timestamp`) and **TC-UNIT-011** (`ppid` distinctness — `ppid` is
> deferred, has no producer, and isn't needed for any AC). Added **TC-PROD-005**
> (producer-side rotation/bounding) and the two US-003 edge cases
> **TC-UNIT-025/026**.

## Coverage Matrix (AC → TC → target test symbol)

| Story | AC | TC | Target test symbol |
|-------|----|----|--------------------|
| US-001 | incremental read returns only appended bytes (regression guard) | TC-INT-001 | `HookEventTailTests.readNew_returnsOnlyAppendedEvents` |
| US-001 | FS-watch fires the read (event-driven, no backstop) | TC-INT-002 | `SessionsFeedTests.fsWrite_triggersReadWithoutBackstop` |
| US-001 | reader survives rotation (inode-reset, no loss/dup) | TC-UNIT-003 | `HookEventTailTests.rotation_reArmsNoLossNoDup` |
| US-001 | producer rotates/bounds the log | TC-PROD-005 | `tests/unit/test_forward_rotation.py::test_forwarder_rotates_past_threshold` |
| US-002 | dropped Stop recovered via JSONL fallback | TC-INT-010 | `ReconcilerTests.droppedStop_recoveredViaJSONL` |
| US-002 | freshest state wins by `updatedAt` | TC-UNIT-012 | `HookSessionStoreTests.updatedAtTiebreak_freshWins` |
| US-002 | permission hook → needs-attention | TC-UNIT-013 | `HookNormalizerTests.permissionHook_setsAttention` |
| US-002 | sessionEnd closes; hard-kill decays | TC-UNIT-014 | `HookSessionStoreTests.sessionEnd_closesNow_hardKillDecays` |
| US-005 | live re-render while drilled in | TC-INT-015 | `BoardShellTests.applySessions_rendersWhileFocused` |
| US-003 | snapshot written + restored | TC-INT-020 | `SessionResumeTests.quitWritesSnapshot_launchRestores` |
| US-003 | corrupt → `-previous` fallback | TC-UNIT-021 | `SessionResumeTests.corruptCurrent_fallsBackToPrevious` |
| US-003 | restore never spawns `claude -p` | TC-UNIT-022 | `SessionResumeTests.restore_neverSpawnsHeadless` |
| US-003 | schema version mismatch → migrate/ignore, never crash | TC-UNIT-025 | `SessionResumeTests.versionMismatch_ignoredNotCrash` |
| US-003 | dead process → restore pane as closed | TC-UNIT-026 | `SessionResumeTests.deadProcess_restoresAsClosed` |
| US-004 | idempotent install, rc preserved | TC-INT-023 | `ShellIntegrationInstallTests.install_idempotent_preservesRc` |
| US-004 | cwd reported semantically | TC-UNIT-024 | `ShellIntegrationTests.cwdReportedNotInferred` |

## By Type

- **integration/** — TC-INT-001/002/010/015/020/023 (`integration/*.md`)
- **unit/** — TC-UNIT-003/012/013/014/021/022/024/025/026 (`swift test`, `unit/*.md`)
- **producer/** — TC-PROD-005 (`pytest` driving the bash forwarder — `.claude/scripts/ghostling-forward.sh` is not Swift)
- **e2e/** — none for this task; the live-board latency demo is a manual/visual check flagged `needs_human_visual` by the DoD gate.

## Notes

- Symbol names are the *contract* the implementer creates; the DoD-native gate
  fails if an AC has no bound green symbol (no silent unbound ACs).
- `TC-UNIT-022` guards the watcher-not-spawner invariant — it must assert no
  `claude -p` process is spawned on restore.
- Ordering is by `timestamp`/`updatedAt` (both already on the models); there is
  no `seq` and no `ppid` key. If `ppid` is ever added it is enrichment on top of
  timestamp order, never the sole key (observed other-terminal sessions lack it).
- Flaky-timing guard: prefer asserting the FS-source *fired* over measuring
  latency (see the `GridTextTests fromPTY` PTY-EOF flake precedent).
