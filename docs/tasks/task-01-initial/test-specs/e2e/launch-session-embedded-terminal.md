# E2E Test Spec: Launch a Session in the Embedded Terminal

**Related Stories:** US-001 (and touches US-002)
**Priority:** Critical
**Status:** Draft

## Overview

The DD-001 foundation: an interactive session runs inside the app's own libghostty terminal, the app reads its PTY directly, and the **pool firewall** holds (no `claude -p` / Agent SDK call originates from the app).

## Harness note

- Drives the native app via XCUITest (or equivalent) plus a **fake-agent fixture** in place of paid `claude`. A real `claude` run is **never** invoked by the suite.
- **TC-E2E-101 is the GATE for the entire E2E layer, not a peer test.** It is the DD-001 Phase-0 embedding smoke test. If it fails on the pinned libghostty revision (the API is "roadmap, not released" as of 2026-06-15), then TC-E2E-102/103/104 *and* every board E2E that relies on direct PTY read are unbuildable as specified, and the harness pivots to the **Option-3 fallback (ride cmux's socket)** — which re-targets the read-path assertions (see TC-E2E-102). Surfaced in the root README's "Phase-0 dependency" note.

## Preconditions

- macOS test host; pinned libghostty revision built into the app.
- Fake-agent fixture available as a launchable command that behaves like an interactive agent (reads stdin, writes PTY, emits hooks).

## Test Cases

### TC-E2E-101: Embedded terminal renders and runs an interactive shell (Phase-0 smoke)

**Description:** A real interactive shell renders inside the app and accepts input. Gates DD-001's substrate. (US-001 AC#1)

**Steps:**
1. Open a new embedded terminal in the app.
2. Type a shell command (e.g. `echo hello-ghostty`) and press Enter.

**Expected Results:**
- The libghostty surface renders; the typed command echoes and produces `hello-ghostty`.
- The user's existing Ghostty config/keybindings are honored.
- If this fails on the pinned revision, the build is red (do not ship a broken terminal).

---

### TC-E2E-102: App reads the session PTY directly (happy path)

**Description:** Output produced in the session is readable by the app without AppleScript/screen-scrape. (US-001 AC#2)

**Steps:**
1. Launch the fake-agent fixture in the embedded terminal.
2. Have the fixture print a known marker line.

**Expected Results:**
- The app's PTY reader observes the marker line directly.
- This read path is what feeds US-004 state detection — assert it is in-process, not via Ghostty.app scripting.

> **Option-3 fallback coupling:** this assertion is bound to the chosen DD-001 outcome (we own the PTY). If Phase-0 (TC-E2E-101) fails and the project falls back to riding cmux, the read path becomes cmux's `surface.read_text` **socket** — and this assertion *inverts* (read via socket, not in-process). Re-target this case if/when the fallback is taken.

---

### TC-E2E-103: Pool firewall — no `claude -p` / Agent SDK call originates from the app (critical guard)

**Description:** Launching/managing a session never triggers a headless Agent SDK call by the app. (US-001 AC#3, DD-001 / watcher constraint)

**Steps:**
1. Start and interact with a managed session via the app.
2. Capture all child processes the app spawns and all outbound API calls it makes (process monitor + network/sandbox shim).

**Expected Results:**
- The app spawns an **interactive** session (shell + interactive `claude`/fixture) only.
- **Zero** invocations of `claude -p` or direct Agent SDK endpoints originate from the app process tree.
- This assertion is mandatory (owning a read/write PTY makes dispatch-creep easy — it must be tested, not assumed).

> **Assertion mechanism (for the implementation plan):** the **process-spawn boundary** is the cleanly testable layer — assert no child process is launched with a `-p`/`--print` flag and no Agent-SDK entrypoint is invoked. The complementary **network** assertion (no traffic to Agent-SDK endpoints) needs the plan to specify *how* it distinguishes Agent-SDK traffic from interactive-pool traffic (endpoint allow/deny shim). Prefer the process-boundary assertion as primary; treat the network shim as defense-in-depth.

---

### TC-E2E-104: Session crash is surfaced (error path)

**Description:** An unexpectedly dying session is reflected, not hung. (US-001 edge case)

**Steps:**
1. Launch the fake agent; kill its process abruptly.

**Expected Results:**
- The terminal surface shows the abrupt exit; the card moves to `blocked`/`done`-with-error (not stuck `running`).

## Cleanup

- Kill any fixture processes; reset the embedded terminal surfaces.
