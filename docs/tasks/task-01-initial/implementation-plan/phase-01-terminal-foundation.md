# Phase 01: Terminal Foundation

**Status:** ✅ **Complete — human-approved 2026-06-20.** `app/` `swift test` **28/28** green. PTY-read seam, pool firewall, **windowed `NSView` `TerminalSurface` + `AppShell` + `ghostling-app` executable, and a typed Swift `SessionRegistry` (lifecycle: clean-exit / SIGKILL / non-zero-exit) all built (iteration 1, 2026-06-17)**. **US-001 AC1 render = human-approved 2026-06-17.** Iteration 2 (2026-06-20) fixed a lifecycle-presentation defect found *during* that sign-off — a Ctrl-D/EOF logout carrying a non-zero `$?` was mislabeled "crashed" and the window read as stuck — via a pure `SessionDisposition` seam (signal → crashed; any WIFEXITED code → exited + a "session ended (exit N)" banner). **The Ctrl-D re-confirm is now human-approved 2026-06-20** ("all is working": logout reads `[exited]` + banner, not `[crashed]` + stuck). All US-001 ACs (render + lifecycle presentation) are human-confirmed; no residue remains.
**Estimated Effort:** XL
**Dependencies:** Phase 00 (**GO** — met).

> **Built so far (2026-06-16, `app/README.md`):** a SwiftPM package vendoring `ghostty-vt.xcframework`; `PTYSession` spawns a child in a pty we own and reads its output **in-process** into a `libghostty-vt` `Terminal` (the US-004 keystone, ported from the C spike); `fork()`/`execvp()` isolated in a tiny C target (`CPtySupport`) so the forked child never touches the Swift runtime; `PoolFirewall` on the spawn path refuses `claude -p` / `--print` structurally; `ghostling-probe` is a runnable headless demo. **Remaining:** the `NSView` that *renders* the `libghostty-vt` screen + routes keystrokes back to `PTYSession.write` (Step 1 surface), and a Swift `SessionRegistry`/lifecycle (Step 2) — the part `swift test` can't fully assert; verify by launch + visual check (as with upstream `ghostling`).

## Objective

Turn the spike into the real product foundation: a macOS app shell that hosts managed sessions in embedded libghostty terminals, with session lifecycle and the **pool firewall** enforced in code. This is the DD-001 substrate every other phase sits on.

## Scope

### Stories Included

| Story | Priority | Complexity |
|-------|----------|------------|
| US-001 | Must Have | XL |

### Out of Scope (Deferred)

- Board UI (Phase 03), state detection (Phase 02), quota (Phase 04). Phase 01 delivers terminals + a session registry, not the overview.

## Implementation Steps

### Step 1: App shell + embedded TerminalSurface

**Description:** A real (non-throwaway) AppKit app shell; a reusable `TerminalSurface` component wrapping libghostty (render + input + in-process PTY read), promoted from the spike against the pinned revision.

**Files to Create/Modify (indicative — Swift/AppKit per DD-001; exact layout TBD):**
- `app/TerminalSurface.swift` — libghostty wrapper (render/input/PTY read). Single responsibility: one surface = one PTY.
- `app/AppShell.swift` — window/app lifecycle.

**Technical Notes:**
- Keep `TerminalSurface` free of product logic — it only renders and exposes a PTY read/write stream. Modular & reusable per code-style rules.

**Acceptance Criteria:**
- [ ] An interactive `claude`/shell renders inside the app; existing Ghostty config/keybindings honored. *(surface built — `TerminalSurface` NSView renders `Terminal.lines()` + routes keys via `KeyEncoder`, hosted by `AppShell`/`ghostling-app`; the on-screen render is a pixel AC **awaiting human visual sign-off**)*
- [x] PTY output is readable in-process. ✓ (`PTYSession` → `libghostty-vt` `Terminal`, asserted by `PTYReadTests`)

**Tests:** TC-E2E-101, TC-E2E-102

### Step 2: Session lifecycle + registry

**Description:** Launch/attach/track managed sessions; a `SessionRegistry` holding session id, project dir, agent type, flow tag, PTY handle, lifecycle state. Detect process exit/crash.

**Files to Create/Modify (indicative):**
- `app/Session.swift`, `app/SessionRegistry.swift`

**Technical Notes:**
- Registry is the single source of truth the board (Phase 03) and state detector (Phase 02) read from. For any repeatable/complex data, prefer typed models (Pydantic V2 if a Python sidecar holds them).

**Acceptance Criteria:**
- [x] A launched session is tracked with metadata; a clean exit and an abrupt kill are both reflected (not left `running`). ✓ (iteration 1 — `Session`/`SessionRegistry` + green `SessionRegistryTests`: `.exited` / `.crashed` via SIGKILL / `.crashed` via non-zero exit code)
- [x] The *user-facing surface* presents the end cleanly (US-001 Edge Case 2): a terminating **signal** reads as "crashed" (TC-E2E-104), but a **WIFEXITED** with any code reads as "exited (N)" — never "crashed" — and the window shows a "session ended (exit N)" banner instead of freezing. ✓ (iteration 2 — pure `SessionDisposition` seam + green `SessionDispositionTests` / `LogoutDispositionEndToEndTests`; registry classification kept frozen)

**Tests:** TC-E2E-104

### Step 3: Pool firewall (mandatory guard)

**Description:** Enforce in code that the app only ever spawns **interactive** sessions — never `claude -p` / Agent SDK. Primary enforcement at the **process-spawn boundary**.

**Files to Create/Modify (indicative):**
- `app/SessionLauncher.swift` — the only place sessions are spawned; rejects any `-p`/`--print`/SDK entrypoint.

**Technical Notes:**
- Owning a read/write PTY makes dispatch-creep trivially easy — this guard is mandatory, not optional (DD-001). Process-boundary assertion is primary; an endpoint allow/deny network shim is defense-in-depth (mechanism TBD in this step).

**Acceptance Criteria:**
- [x] No code path spawns `claude -p` or calls an Agent SDK entrypoint. ✓ (`PoolFirewall` on the only spawn path; refuses `-p`/`--print` structurally)
- [x] A test can observe zero headless invocations from the app. ✓ (`PoolFirewallTests` + the `ghostling-probe` refusal path)

**Tests:** TC-E2E-103

## Definition of Done

- [ ] US-001 acceptance criteria met; TC-E2E-101/102/103/104 pass against a fake-agent fixture.
- [ ] Pool-firewall guard reviewed specifically.
- [ ] Pinned libghostty smoke test in CI.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Promoting spike code to production reveals libghostty gaps | Medium | High | Phase 00 already exercised the risky path; keep the surface thin |
| Pool firewall bypassed by a later convenience feature | Medium | High | Single chokepoint (`SessionLauncher`); TC-E2E-103 as a regression guard |
| Maintaining a terminal emulator is large/ongoing | High | Medium | Accepted via DD-001; keep `TerminalSurface` minimal, lean on libghostty |

## Notes

- DD-003 (cross-platform) assumed **macOS-first** here. If reversed, `TerminalSurface`/`AppShell` are the platform-coupled seams to abstract.

## Related

- **Stories:** US-001
- **Decisions:** DD-001; DD-003 (assumed macOS-first)
- **Tests:** TC-E2E-101..104
