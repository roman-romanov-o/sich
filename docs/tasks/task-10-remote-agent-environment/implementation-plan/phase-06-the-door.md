# Phase 06: The Door — Remote Host & Folder Picker

**Status:** Not Started
**Estimated Effort:** L
**Dependencies:** Phase 05 (the palette writes the spec restore reads — build the writer
after the format is settled, not before), Phase 04 (a card created here must bind), Phase 01
(a typed destination is caller data validated here by a real human)

## Objective

Give the operator a first-class create-palette flow to pick **where a card runs** (this
laptop or a remote box) and **which folder** on that box, from a host-qualified recents list
with a hand-entry fallback — then retire the ⌘⇧R `NSAlert` **last**. This is US-009, and the
folder picker is the user's headline ask realised in its scoped 10a form.

## Why last, deliberately

⌘⇧R is this task's **own demo path** through Phases 03–05 ("open ⌘⇧R, run `claude`, watch the
card go running → waiting → done"). Retiring it early would make unfinished palette UI a hard
prerequisite for demonstrating all the transport work. So the alert survives until this stage
replaces it and is removed last (US-009 AC-5). A Must-Have story sits at the end on purpose.

## Scope

### Stories Included

| Story | Priority | Complexity |
|-------|----------|------------|
| US-009 Choose a remote host and folder at card creation | Must Have | L |

### The folder picker's scoped shape (recorded decision, not drift)

- **In:** a per-host **recents list** of previously used folders + a hand-entry field. This is
  ~10% of a tree browser's cost and most of its value, and it sidesteps the ssh-latency UX
  problem instead of solving it.
- **Out (→ 10b):** a full remote filesystem tree browser. This is research item 8, which
  research assigned to 10b; its reduced inclusion here is recorded in the task Scope section.

## Implementation Steps

### Step 1: A "where does this run?" stage in the palette

**Files to Create/Modify:**
- `app/Sources/GhostlingApp/CreateCardPalette.swift` — remote as a **first-class** selectable
  stage (AC-1), producing a `RemoteTmuxSpec` identical to ⌘⇧R's for equal input (AC-3).

**Technical Notes:**
- Reachability is the assertion, per `saha-creation-had-no-ui-entry-point`: a flow bound to a
  green test but not reachable by a real shortcut is the recurring failure. TC-E2E-012 opens
  the palette **by its real shortcut** and dispatches a **real click**, never a handler call
  (`interaction-ac-binding-rule` — this repo shipped Esc green-and-broken three times by
  calling `goBack()` instead of pressing Esc).

**Acceptance Criteria:**
- [ ] US-009 AC-1: remote is first-class and reachable.
- [ ] US-009 AC-3: palette-created spec equals a ⌘⇧R spec for equal input (assert the
  **spec**, not the argv — equal specs give equal argvs, and an argv check would pass even if
  the palette bypassed `argv(for:)`).

**Tests:** TC-E2E-012, TC-E2E-013

---

### Step 2: Host-qualified recents (the folder picker)

**Files to Create/Modify:**
- The recents store (`recentProjectDirs`/`rememberProjectDir`) — widen the entry to
  `Codable { host: String?, path: String }` so a path on box A never appears under box B or
  local (DD-003, host-qualified recents).

**Technical Notes:**
- **A pre-existing unqualified recents list must still load** (its entries read as local),
  not be dropped — the same additive-decode reasoning as US-006 AC-3. This is the
  persist-the-spec discipline applied to the recents format: widen the shape, keep the old
  one decodable.
- **Unreachable host must not block creation** (edge case 3): recents render from local
  state; only a live existence check would need the network, and creation must not depend on
  it.
- Hand-entry (edge case 1) is where a **real human types a destination** — the one place
  US-001's destination validation meets live caller input. TC-E2E-012's flow exercises it.

**Acceptance Criteria:**
- [ ] US-009 AC-2: recents are host-qualified and offered only for their host; old
  unqualified lists still load.

**Tests:** TC-E2E-014

---

### Step 3: Retire ⌘⇧R last

**Files to Create/Modify:**
- Remove the ⌘⇧R `NSAlert` create path **only after** TC-E2E-012..014 pass.

**Acceptance Criteria:**
- [ ] US-009 AC-5: the alert path keeps working until the palette path is proven, then is
  removed last.

**Tests:** TC-E2E-015

## Definition of Done

- [ ] US-009 all ACs green; every interaction proven by **dispatched NSEvent**, not a handler
  call (AC-4).
- [ ] Old unqualified recents still decode; unreachable host does not block creation.
- [ ] ⌘⇧R removed only after the palette path passes.
- [ ] `swift test` count strictly increases; `swift build` warning-clean.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Flow bound to a green test but unreachable by a user (`saha-creation-had-no-ui-entry-point`) | Medium | High | TC-E2E-012 opens the palette by its real shortcut and dispatches a real click. |
| Interaction shipped green-and-broken by testing the handler not the path (bit 3×) | Medium | High | AC-4 mandates NSEvent dispatch throughout; no `goBack()`-style handler calls. |
| Widening the recents format drops old entries | Medium | Medium | Additive decode; TC-E2E-014 asserts an old unqualified list still loads as local. |
| Scope creep into a full tree browser | Low | Medium | Recents + hand-entry only; tree browser explicitly 10b, recorded in task Scope. |

## Notes

Both flagged-for-confirmation choices are now the user's decisions (confirmed at
`/saha:plan`): the host chip on `SessionCard` (its render lands in Phase 02; TC-E2E-016 lives
in this spec but belongs to US-005/Phase 02) and accepting bracketed IPv6 in the destination
grammar (Phase 01). The open questions in US-009 (host-list source; whether recents check
remote existence on open) are execution-time refinements, not planning blockers — both
edge-case behaviours are already specified conservatively (render from local state; surface,
don't swallow, a missing dir).

## Related

- **Stories:** US-009
- **Decisions:** DD-003 (host-qualified recents), DD-002 (palette card binds), DD-004 (typed
  destination validated)
- **Contracts:** [remote-spec-snapshot.md](../code-changes/remote-spec-snapshot.md),
  [remote-host-state.md](../code-changes/remote-host-state.md)
- **Tests:** [e2e/creating-a-remote-card.md](../test-specs/e2e/creating-a-remote-card.md)
