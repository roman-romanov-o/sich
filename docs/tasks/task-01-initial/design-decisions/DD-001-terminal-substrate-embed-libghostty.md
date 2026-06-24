# DD-001: Terminal Substrate — Embed libghostty (Become the Terminal)

**Status:** Accepted
**Date:** 2026-06-15
**Deciders:** Roman (product owner); analysis by Claude (saha research)

## Context

The product (`agentic-coding-kanban`) needs a way to show and drill into the live agentic-coding sessions it manages. The hand-drawn UI mockup (see `research/14-ui-mockup-critique.md`) places a large **"Terminal for the Task"** pane directly inside the app window, alongside the board and the quota panel. That single-window, board-plus-live-terminal experience is the experience the product owner wants.

The question this decision answers: **how does the app relate to the terminal?** Concretely — *"can we embed Ghostty into our app, like cmux does?"*

The honest framing that emerged from research: **"embed Ghostty like cmux" does not mean embedding `Ghostty.app`.** cmux embeds **`libghostty`** — Ghostty's rendering *library* — "the same way apps use WebKit for web views," and builds its **own terminal emulator** around it. So choosing this path means **the kanban app becomes a terminal emulator**, and the sessions it manages run *inside our app* rather than inside `Ghostty.app`.

### Constraints

- **Watcher-not-spawner — POOL discipline (KEEP):** the tool must never auto-invoke `claude -p` / Agent SDK as part of its own operation; that pool is separately capped and hard-stops (`research/10-claude-p-quota-change.md`). **This decision does NOT relax this.** Even when we own the terminal, sessions run *interactive* `claude` in our PTY → they bill the interactive pool. Launch stays human-initiated and suggest-only.
- **"Must work alongside Ghostty, not replace it" (REVERSED by this decision):** the original Terminal constraint in `task-description.md` (reason: "User loves Ghostty"). Embedding libghostty means our app *is* the terminal for managed sessions — i.e., we replace `Ghostty.app` for that workflow. This decision consciously reverses that constraint. **Done:** the Terminal constraint row and the "Replacing Ghostty" Out-of-Scope line in `task-description.md` were amended 2026-06-15 to point here.
- **Quota + two-pool capacity brain remains the differentiator** (`research/12-two-flow-scheduling-model.md`). Owning the terminal changes *nothing* about this; it's still the reason the product exists.

### Requirements

- Render a **live, interactive terminal** for a managed session inside the app window (the mockup's "Terminal for the Task" pane).
- Reliable, real-time **per-session state** (running / waiting-for-input / blocked / done) — Problem 1 from `task-description.md`.
- Read full PTY content (for peek/triage), not just window title + cwd.
- Preserve the two-pool quota/capacity brain unchanged.

## Options Considered

### Option 1: Coexist / Watcher (the original constraint)

**Description:** Keep `Ghostty.app`. Observe sessions from the outside — AppleScript for focus/cwd/title (`research/05-ghostty-integration.md`), agent hooks + JSONL for state. The board is a *launcher into Ghostty*, never a terminal itself.

**Pros:**
- Honors "don't replace Ghostty" — user keeps their loved setup.
- Smallest build; no terminal emulator to maintain.
- No dependency on a pre-stable embedding API.

**Cons:**
- **Cannot deliver the mockup's in-app terminal pane.** `Ghostty.app`'s AppleScript exposes working-dir and title but **not screen-buffer text**, so a live in-app mirror/peek of a native Ghostty tab is not possible — only agent-log-derived state.
- AppleScript is request/response only: no event subscription, 1–5 Hz polling, 50–200 ms latency, fragile identifiers.
- macOS-only.

**Effort:** Low

### Option 2: Embed libghostty — become the terminal (cmux model) — **CHOSEN**

**Description:** Build our own terminal emulator on `libghostty` (as cmux does: Swift/AppKit on macOS, reading the user's existing Ghostty config). The app hosts the PTYs; the board and the embedded terminal live in one window.

**Pros:**
- **The mockup's board + embedded "Terminal for the Task" is natural and first-class** — the pane stops being a constraint violation and becomes the core UX.
- Full PTY **read/write + real events + per-session metadata** → state detection (Problem 1) becomes direct and reliable, not inferred from polling.
- We can parse OSC 9/99/777 notifications ourselves on top of the embedded VT layer (exactly as cmux does), plus scrollback and ports/branch metadata. **Not** a free libghostty primitive — Ghostty's external OSC support is minimal (OSC 8 / OSC 21 only, per `research/05` §5); owning the parser is what *enables* us to implement it.
- Drill-down (report 13, Altitude 2) becomes a real embedded terminal, not an AppleScript focus-jump.

**Cons:**
- **Reverses "don't replace Ghostty"** — for managed sessions, our app supplants `Ghostty.app`.
- **We now maintain a terminal emulator** — a large, permanent surface area far beyond a "minimal POC."
- **Depends on a pre-stable embedding API.** As of 2026-06-15, `libghostty-vt` (parsing + state) ships and is functionally stable, but its **signatures are still in flux**, and the **GPU-rendering / input / ready-made Swift widget layer needed to draw a live terminal view is roadmap, not released**. cmux rides the in-flux internals as a deeply-invested early adopter; we would inherit that breakage budget.
- macOS-first (cmux is Swift/AppKit, macOS-only). Cross-platform is a separate, larger effort.

**Effort:** High

### Option 3: Ride cmux as substrate

**Description:** Don't build a terminal. Let the user run **cmux** (which already embeds libghostty), and build the kanban as a cmux *observer* via its `/tmp/cmux.sock` JSON-RPC API (`surface.read_text`, `workspace.*`, OSC state).

**Pros:**
- Get the embedded-terminal benefits (read_text, metadata) **without building or maintaining a terminal**.
- cmux already solved the hard rendering problem; we add the quota/capacity brain it lacks — which is our whole differentiator.

**Cons:**
- Depends on cmux and on the user adopting cmux (still replaces `Ghostty.app`, just with someone else's app).
- cmux has **no event/push API yet** (polling-only; issue #3325 unshipped) — `research/13`.
- cmux is itself a spawner; we'd be one layer removed from the sessions and from control over the UX in the mockup.

**Effort:** Medium

## Decision

**Chosen Option:** Option 2 — Embed `libghostty` and build our own terminal.

### Rationale

The product owner's target experience **is** the single-window, board-plus-live-terminal app in the mockup, and wants **full control over that terminal** (read/write, events, metadata, the drill-in peek). Option 1 structurally cannot render a live in-app terminal for native Ghostty sessions (AppleScript can't read the screen buffer). Option 3 delivers the UX but cedes control of the terminal to cmux (and cmux currently lacks an event API). Only Option 2 gives the drawn UX *and* direct ownership of the terminal surface.

The owner chose this **deliberately and with the trade-offs on the table** — the analyst's lean was Option 1 (cheapest path to the capacity-brain differentiator) or Option 3 (mockup UX without maintaining a terminal). This record preserves that dissent: Option 2 is the highest-effort, highest-control path, and it accepts maintaining a terminal emulator on a pre-stable API.

### Key Factors

1. **The mockup's integrated terminal pane is the product, not a nice-to-have** — and only owning the terminal makes it first-class.
2. **Reliable, real-time state detection** (Problem 1) is far stronger with direct PTY access than with AppleScript polling + log inference.
3. **Control** over the terminal UX and metadata, rather than depending on cmux's roadmap (no event API yet).
4. The owner explicitly accepts **replacing `Ghostty.app` for managed sessions** — the founding "don't replace Ghostty" constraint is relaxed by choice.

## Consequences

### Positive

- The mockup's "Terminal for the Task" pane becomes a natural, first-class feature instead of a constraint violation (this resolves critique points C2/C3 in `research/14-ui-mockup-critique.md`, which were valid *only* under the now-relaxed watcher constraint).
- State detection, scrollback, and per-session metadata become direct and real-time — no AppleScript polling, no screen-scrape gymnastics. OSC 9/99/777 notification handling we implement ourselves on the owned parser (as cmux did), not inherited from libghostty.
- Drill-down (report 13, Altitude 2) is a true embedded terminal, not a focus-jump into a separate app.

### Negative

- **We are now a terminal-emulator project.** That is a large, permanent maintenance commitment on top of the kanban/quota work — in direct tension with the task's "POC — keep it minimal" effort constraint.
- **Pre-stable dependency risk:** the libghostty embedding API (beyond `libghostty-vt`) is not yet released/stable as of 2026-06-15. We must pin a libghostty revision, track upstream closely, and budget for breakage. (Re-evaluation trigger below.)
- **macOS-first.** Cross-platform support is a separate, larger effort; `libghostty-vt` is cross-platform but the rendering/widget layer maturity varies by platform (cmux is macOS-only).
- The founding **Terminal constraint in `task-description.md` has been amended** (2026-06-15) to remove the contradiction — the Terminal row now points to this decision and "Replacing Ghostty" is struck from Out-of-Scope.

### Neutral

- **Pool discipline is unchanged *in policy* — but now requires active guarding.** Never auto-invoke `claude -p`; managed sessions run interactive `claude` in our PTY → interactive pool; launch stays human-initiated, suggest-only. However, owning a read/write PTY *lowers the technical barrier* to dispatch-creep (`research/10` Risk 3) — "just type the prompt for the user" becomes trivially easy. So the in-code pool firewall (Implementation Notes) is **mandatory, not optional**. This is closer to a guarded-Negative than a free Neutral.
- The **two-pool quota/capacity brain** — the differentiator — is unaffected by this decision; it remains the reason to build.

## Implementation Notes

- **Phase 0 — throwaway libghostty embedding spike (gate, do this FIRST).** Before committing any app architecture to the terminal substrate, build a minimal spike that embeds the libghostty rendering/input layer and runs one interactive shell. Study `ghostling` first. This is what makes the reversibility below *real* rather than aspirational: if the embedding API proves too unstable to depend on, you discover it here — at the cost of a spike, not a rewritten app — and fall back to Option 3 (ride cmux's socket). Do not build the board/quota architecture on top of the terminal until this spike is green.
- **Stack:** follow cmux's proven shape — Swift/AppKit + libghostty C API on macOS first. `ghostling` (the official "minimum viable terminal on the libghostty C API"; repo `ghostty-org/ghostling`, verified via web search 2026-06-15) is the reference implementation to study before committing.
- **Pin and track libghostty:** treat the embedding API as a moving target. Pin a known-good revision; subscribe to upstream API changes; keep an integration smoke test that fails loudly on signature drift.
- **Re-evaluation trigger:** if, during a spike, the libghostty rendering/input/widget layer proves too unstable to embed reliably, **fall back to Option 3 (ride cmux's socket)** rather than Option 1 — it preserves the mockup's UX at lower build/stability cost. Record that as a superseding decision if it happens.
- **Keep the pool firewall explicit in code:** the terminal we host must only ever run user-launched interactive sessions; there is no code path that shells out to `claude -p` / Agent SDK on the app's behalf.

### Spawned sub-decisions (to record as DD-002+ when chosen)

- [ ] **Hybrid vs. in-app-only:** do we *also* observe external `Ghostty.app` sessions (so the board shows everything), or are managed sessions in-app only? If in-app-only, the AppleScript watcher work in `research/05` becomes moot for managed sessions.
- [ ] **Cross-platform stance:** macOS-only v1 (cmux model) vs. a cross-platform plan from the start.
- [ ] **Board topology** (carried from `research/13`/`14`): state-columns + flow-tag vs. swimlanes-by-flow. Independent of this decision.

## Related

- **Task:** [`task-description.md`](../task-description.md) — Terminal constraint requires amendment (see Consequences).
- **Research:** `research/05-ghostty-integration.md` (AppleScript limits / Option 1), `research/13-board-view-and-feature-parity.md` (cmux drill-down, the "we coexist" row this supersedes), `research/14-ui-mockup-critique.md` (the terminal-pane critique this resolves), `research/12-two-flow-scheduling-model.md` (the capacity brain, unaffected).
- **Supersedes:** the "Diverge — cmux replaces Ghostty; we coexist via AppleScript" row in `research/13` and the C2/C3 terminal-pane critique in `research/14` (both valid only under the now-relaxed watcher constraint).

## References

- [Libghostty Is Coming — mitchellh](https://mitchellh.com/writing/libghostty-is-coming)
- [libghostty C API overview](https://mintlify.wiki/ghostty-org/ghostty/api/overview)
- [ghostling — official MVP terminal on the libghostty C API](https://github.com/ghostty-org/ghostling)
- [cmux repo](https://github.com/manaflow-ai/cmux) · [cmux Ghostty config docs](https://manaflow-ai-cmux.mintlify.app/configuration/ghostty-config) · [cmux Socket API](https://manaflow-ai-cmux.mintlify.app/automation/socket-api)
