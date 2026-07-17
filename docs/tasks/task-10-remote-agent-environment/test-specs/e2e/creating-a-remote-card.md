# E2E Test Spec: Creating a Remote Card

**Related Stories:** US-009, US-005
**Priority:** High
**Status:** Draft
**Suite:** `app/Tests/GhostlingAppTests/RemoteCreationE2ETests.swift` (new)

## Overview

The operator's actual entry point: pick "remote" in the create palette, choose a host and
a remote directory, get a card. Plus the host chip that tells them whether the box can be
watched at all.

## The binding rule (non-negotiable in this repo)

**Every interaction assertion here dispatches a real input event** — `NSEvent`, `keyDown`,
a real click on the real control — never a direct call to the handler. This has bitten
three times: an Esc handler shipped green and broken because the test called `goBack()`
instead of pressing Esc. A method call proves the method; it leaves the interaction path
unverified, which is the half that was broken.

The related trap, also earned: `cacheDisplay` / `CALayer.render` do **not** faithfully
composite stock AppKit control layers, so they are **non-evidence** for a visual AC. The
host chip is built the same custom-drawn layer-backed way as `repoChip()` — "the chip IS
the label" — precisely so it can be asserted at all. A stock `NSButton` was the lone
outlier that caused the invisible-pill defect four times over.

The precedent for the whole story: `saha-creation-had-no-ui-entry-point` — Planning Mode
was green and unreachable because only tests called `beginSahaCreation`. **"Bound to a
green test" ≠ "reachable by a user."** TC-E2E-012 exists to stop that recurring.

## Preconditions

- Board shell realized in a window (the palette needs a real responder chain).
- A fake host-state source; no network.

## Test Cases

### TC-E2E-012: Remote is a first-class choice in the palette (US-009 AC-1)

**Steps:** open the create palette **by its real shortcut**; assert a remote option is
present and selectable **by dispatching a click**, not by calling its action.

**Expected Results:**
- A remote choice exists, is reachable from the palette, and yields a card whose spec is a
  `RemoteTmuxSpec`.
- Reachability is the assertion. A test that constructs the palette and calls the handler
  reproduces the exact failure this case exists to catch.

---

### TC-E2E-013: A card created via the palette is indistinguishable from ⌘⇧R's (US-009 AC-3)

**Expected Results:** the two paths produce an **equal spec** for equal input. Assert on
the spec, not on the argv — equal specs give equal argvs by construction, and the argv
comparison would pass even if the palette bypassed `argv(for:)` entirely.

---

### TC-E2E-014: Recents are host-qualified (US-009 AC-2)

**Description:** `recentProjectDirs`/`rememberProjectDir` store bare paths today.
`/home/roman/proj` on boxA and on boxB are different places with the same string, and a
local `/Users/roman/proj` is a third.

**Expected Results:**
- A recent entry round-trips with its host and is offered only for that host.
- **A pre-existing unqualified recents list still loads** (its entries read as local)
  rather than being dropped — same additive-decode reasoning as US-006 AC-3.

---

### TC-E2E-015: ⌘⇧R is retired last (US-009 AC-5)

**Expected Results:** the ⌘⇧R `NSAlert` path keeps working until the palette path passes
TC-E2E-012 through TC-E2E-014. Retiring it first would remove the only working entry point
and make the others' failures invisible.

---

### TC-E2E-016: The host chip renders each install state distinctly (US-005 AC-4, AC-7)

**Steps:** drive `RemoteHookInstallState` through all four values; assert the chip **by
dispatching a real click** on it for the actionable states.

**Expected Results:**

| State | Chip |
|---|---|
| `installed` | `roman@boxA` — dim, inert |
| `notInstalled` | `roman@boxA · hooks not installed` — click installs |
| `staleVersion` | `roman@boxA · hooks outdated` — click updates |
| `unknown` | `roman@boxA · hook status unknown` — inert, **distinct from `installed`** |

- **"not observed" is never bare** (AC-7): assert the card never shows an unexplained
  silence while a reason exists. "The card never moves" with no stated cause is the exact
  symptom of `board-status-bug-was-missing-global-hooks`, where the cause was missing
  hooks, not the feature under suspicion.
- ⚠️ **The host chip surface is my proposal, not the user's** — flagged for confirmation
  at `/saha:plan`. If the surface changes, this spec changes with it.

## Cleanup

Close the window; clear the recents defaults key.
