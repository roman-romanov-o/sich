# US-009: Choose a Remote Host and Folder at Card Creation

**Priority:** Must Have
**Status:** Draft
**Persona:** Operator (the developer running agents on the board)
**Estimated Complexity:** L

## User Story

As an **operator**,
I want to **pick where a new card runs — this laptop or one of my remote boxes — and pick the folder on that box from the ones I have used before**,
So that **starting remote work costs one dialog instead of hand-typing a host and an absolute path every time**.

## Acceptance Criteria

- [ ] **AC-1:** `CreateCardPalette` offers a "where does this run?" stage with remote as a **first-class** choice, not a hidden alternate path.
- [ ] **AC-2:** Choosing a host offers a **per-host recents list** of previously used folders. Recents are host-qualified (`Codable {host: String?, path: String}`) — a path from host A never appears under host B, and never under local.
- [ ] **AC-3:** A card created through the palette is indistinguishable, downstream, from one created via ⌘⇧R: same spec, same identity binding, same restore behaviour.
- [ ] **AC-4:** The palette flow is verified by **dispatching real input events** (NSEvent / keyDown) against the real surface — never by calling handlers directly. This repo has shipped an interaction green and broken three times by testing the method instead of the path.
- [ ] **AC-5:** **The ⌘⇧R NSAlert is retired only after this stage is proven**, and is removed **last**.

## Edge Cases

1. **A host with no recents yet**
   - Trigger: first card on a new box.
   - Expected behavior: a way to enter a path by hand. The recents list is a shortcut, not the only door — and this is where the destination validation from US-001 gets exercised by a real human typing.

2. **A recent folder no longer exists remotely**
   - Trigger: the directory was deleted or renamed on the host.
   - Expected behavior: not silently swallowed. Either checked (an ssh round-trip, with the latency that implies) or surfaced when the session opens where it did not expect to be.

3. **The host is unreachable while the palette is open**
   - Trigger: Tailscale off.
   - Expected behavior: the recents list still renders from local state; only a live check would fail. Creation must not be blocked by an unreachable host.

## Technical Notes

**Sequencing, deliberately:** ⌘⇧R is currently this task's **own demo path** — the demo is "open ⌘⇧R, run `claude` in the tmux, watch the card go running → waiting → done." Retiring it early would make unfinished palette UI a hard prerequisite for demonstrating US-004, US-002 and US-006, coupling all the transport work to a UI change. So the NSAlert survives until this stage replaces it, and is removed last. That is why a Must-Have story sits at the end of the phase.

**A full remote tree browser is out of scope.** A recents list is ~10% of the cost and most of the value, and it sidesteps the ssh-latency UX problem entirely rather than solving it.

Honest sizing note: this is research's item 8, which research assigned to 10b. Its inclusion here (in reduced form) is a decision, not a drift — recorded in the task's Scope section.

## Dependencies

- **Requires:** US-006 (the palette writes the spec that restore reads — building the writer before the format is settled means writing it twice), US-004 (a card created here must bind), US-001 (a typed destination is caller data, and this story is where a human types one).
- **Enables:** retiring ⌘⇧R.

## Execution History

| Iteration | Phase | Result | Notes |
|-----------|-------|--------|-------|
| - | - | - | Not yet executed |

## Questions

- [ ] Where does the host list come from — the recents store, `~/.ssh/config`, Tailscale status, or hand-added entries? Reading `~/.ssh/config` is the least effort and the most surprising (it lists hosts the operator has no agent work on).
- [ ] Does AC-2's list check remote existence on open (an ssh round-trip per render) or trust the store and fail later? Edge case 2 has no free answer.

## Related

- Task: [task-description.md](../task-description.md) — success criterion 8, the sequencing constraint in Scope
- Design Decision: [DD-003](../design-decisions/DD-003-location-model-and-remote-restore.md) (host-qualified recents)
