# Code Change: Remote Host State + Card Surface

**Type:** Internal interface (module boundary — `GhostlingCore` types, `GhostlingApp` surface)
**Consumers:** `BoardShell`, `SessionCard`, the create palette
**Status:** Draft

## Overview

Three related state shapes and the one surface that renders them. Grouped because they
share a single rule: **a remote card must never be silently unreadable.** Every "we don't
know" here is an explicit, distinguishable value — never a guess, never a bare blank.

---

## 1. `CardState.unreachable` (new case)

Joins the existing enum (`BoardCard.swift`), whose current cases are `idle`, `running`,
`waitingForInput` (`"waiting-for-input"`), `runningTests` (`"running-tests"`), `blocked`,
`done`, `unknown`.

| Property | Value | Reason |
|----------|-------|--------|
| `rawValue` | `"unreachable"` | `CardState` is `String`-`Codable`; a new case is additive for decode. |
| `needsAttention` | **`false`** | The existing rule is `self == .waitingForInput \|\| self == .blocked`. An unreachable host is not an agent asking for you; lighting attention for it would dilute the one signal the product exists to protect. |
| `detectorFallback` / `atRestFallback` | `nil` | Existing default for non-`done`. |

**Distinct from `unknown`.** `unknown` means "not positively determined." `unreachable`
means "positively determined to be gone." Collapsing them loses the only actionable half.

### Transition contract

| Trigger | Latency |
|---------|---------|
| The relay's ssh child **exits** | → `unreachable` within **X = 5s** |
| Keepalive timeout (`ServerAliveInterval=15` × `ServerAliveCountMax=3`, ~45s worst case) | → `unreachable`, same transition |

Both paths reach the same state; **latency and X are asserted separately** — a test that
only measures the fast path leaves the slow path unproven.

The **negative assertion is load-bearing**: an unreachable card must not read `running` or
`waitingForInput`. A frozen `running` card is worse than a blank one — it is a lie the
operator will act on.

*Note: `N` (the old retry-count knob) is **retired, not assigned**. Supervision is a
transport concern, not a card-state one.*

---

## 2. `RemoteHookInstallState` (new enum)

| Case | Meaning |
|------|---------|
| `installed` | The probe read the remote forwarder and its bytes match ours. |
| `notInstalled` | The probe ran and found nothing. Actionable. |
| `staleVersion` | The probe read the remote forwarder and its bytes **differ** from ours. Actionable. |
| `unknown` | **The probe itself failed.** |

### What "version" means — the comparand

**There is no version to compare against today.** `grep -c version app/Sources/GhostlingApp/HookInstaller.swift` returns **0**: the forwarder script carries no version marker, no date, no id. `staleVersion` as previously written had no writable test spec, because nothing on disk could make it true.

**Decision: compare SHA-256 over the script bytes, hashed locally on both sides.**

- **Ours:** `sha256(forwarderScript)` — the embedded string at `HookInstaller.swift`'s `forwarderScript`, hashed at runtime. Nothing to maintain and nothing to forget.
  **The comparison lives in `GhostlingApp`, not `GhostlingCore`:** `HookInstaller` is an internal `enum` and `forwarderScript` is `private let`, so no other module can compute the local half. This is why `installArgv(for:script:)` takes the script as a **parameter** — the App owns the bytes and passes them down; `GhostlingCore` builds argvs and never learns what a forwarder is.
- **Theirs:** the probe `cat`s the remote forwarder over ssh and hashes the bytes **on the laptop**. It does **not** run a remote hash tool: `sha256sum` (GNU) vs `shasum -a 256` (BSD) is exactly the userland split US-002 exists to handle, and this avoids buying into it for a file of a few KB.

> ⚠️ **The probe channel must NOT allocate a PTY.** This is a byte comparison, and a PTY
> translates LF → CRLF — every byte after the first newline shifts, every host reports
> `hooks outdated`, forever. A chip that cries wolf is worse than no chip: it trains the
> operator to ignore the one surface that tells them why the board is silent.
>
> This is not hypothetical. The repo's only ssh argv builder hardcodes `-t`
> (`RemoteTmuxCommand.swift:109`), so `probeArgv(for:)` inheriting the obvious pattern
> ships the bug. **AC: a freshly-installed host reads `installed`** — that test goes red
> against a `-t` probe and green without it, which is the only reason it is worth writing.
- Match → `installed`. Differ → `staleVersion`. Absent → `notInstalled`. ssh/read failure → `unknown`.

**Rejected: a `# ghostling-forwarder: v1` marker line.** It is more readable and it is the option US-005's open question leaned toward, but it must be *remembered* — edit the script, forget the bump, and every host reports `installed` while running different code. That is a silent failure whose symptom is "the card never moves", i.e. the precise shape of `board-status-bug-was-missing-global-hooks`. A derived comparand cannot be forgotten; a maintained one can.

This answers US-005's worry that "a hash makes every local edit look stale" — it does, and that is **correct**, not a false positive. If the embedded script changed, the remote genuinely is running older code. The worry conflates dev-loop churn with real staleness; the cost is a chip that reads `hooks outdated` during development, one click from resolved.

The known trade-off: a hash says *different*, not *older*, so a hand-edited remote forwarder also reads `staleVersion`. That is the honest answer — the app does not know whose edit is newer — and the action (re-push ours) is the same either way. It also means the contract must hold the `forwarderScript` doc comment's "kept byte-identical to `.claude/scripts/ghostling-forward.sh`" guarantee: if those two drift, hosts installed from the repo script report stale against the embedded one.

**Always probe-derived, never a cached flag.** The test asserts this by making the probe
fail *after* a successful install and requiring the state to become `unknown` — a cached
boolean passes a naive test and ships the bug.

**`unknown` is never collapsed into `installed`.** Assert the negative. This is exactly
the silent-failure class of `board-status-bug-was-missing-global-hooks`, where "the card
never moves" turned out to be missing hooks rather than the feature under suspicion.

`installRemote(host:)` mirrors `HookInstaller.installGlobal` (`HookInstaller.installGlobal`)
— **note the path: `app/Sources/GhostlingApp/`, not `GhostlingCore/`.** No new remote
binary and no new trust surface: it ships the same shell script the laptop already writes.

---

## 3. The surface: a host chip on `SessionCard`

**This names what US-005 AC-4 and US-004's open question left unnamed.**

Rendered as a chip alongside `repoChip()` (`SessionCard.swift:100`), built **the same
custom-drawn layer-backed way** — "the chip IS the label" (`SessionCard.swift:252`).
That render path is not a style preference: a stock `NSButton` was the lone outlier that
caused the invisible-pill defect, and `cacheDisplay`/`CALayer.render` do not faithfully
composite stock AppKit control layers, which makes them **non-evidence** for a visual AC.

| Install state | Chip |
|---------------|------|
| `installed` | `roman@host` — dim, inert |
| `notInstalled` | `roman@host · hooks not installed` — actionable, click installs |
| `staleVersion` | `roman@host · hooks outdated` — actionable, click updates |
| `unknown` | `roman@host · hook status unknown` — inert, distinct from `installed` |

**Card state** renders through the existing state-colour path (`BoardTheme.stateColor`),
with `unreachable` visually distinct from both `done` and "not observed".

### Testing rule (non-negotiable in this repo)

The actionable chip's AC must be proven by **dispatching a real `NSEvent`** at the chip
and asserting the install fires — never by calling the handler. This repo shipped an
interaction green-and-broken **three times** (the Esc case) by testing the method instead
of the input path. Prove red → green.

"Not observed" is **never shown bare**: it distinguishes "hooks not installed on `<host>`"
(actionable) from "not started by ghostling" (not actionable). *(This criterion moves here
from US-004 AC-5 — it is install-state messaging, and it belongs with the state machine
that owns it, not with identity binding.)*

> **Flagged for confirmation at `/saha:plan`:** the chip is this contract's proposal,
> chosen because it is the surface where "not observed" would otherwise read bare and the
> only one already carrying per-card provenance. A hosts panel is the plausible
> alternative. Overrule here rather than at implementation time.

---

## 4. Host-qualified recents (new format)

```swift
Codable { host: String?, path: String }   // host == nil ⇒ local
```

Replaces the bare `[String]` of local paths. A remote **macOS** host and the laptop can
hold byte-identical paths, so an unqualified recent is ambiguous the moment a second host
exists — the same collision that forces `ghostling_host` in
[remote-hook-event-channel.md](remote-hook-event-channel.md).

| Case | Behavior |
|------|----------|
| Old `[String]` recents on disk | Decode as `host: nil`. No data loss, no version bump. |
| Remote path no longer exists | Offered; failure surfaces on open. **See open question.** |

## Open Questions

- [ ] Where does the host list come from? `~/.ssh/config` is the least effort and the most
      surprising (it lists hosts the operator never meant to expose to a board).
- [ ] Check remote path existence at palette-open (a round trip per host, slow) or
      trust-and-fail-later (fast, worse error)?
- [ ] Card deleted while its remote tmux session survives, then a new card takes the same
      `(host, name)`: it attaches to a session carrying the **dead** card's ID. Reap on
      delete, or refuse the name while the remote session lives?

## Related

- **Stories:** US-007, US-005, US-009, US-004
- **Decisions:** DD-001 (down-trigger, `X`, `N` retired), DD-002, DD-003 (recents)
