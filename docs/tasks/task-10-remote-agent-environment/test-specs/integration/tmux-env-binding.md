# Integration Test Spec: tmux Environment Binding

**Related:** US-004 (AC-2, AC-4), [DD-002](../../design-decisions/DD-002-remote-card-identity-binding.md)
**Priority:** Critical
**Status:** Draft
**Suite:** `app/Tests/GhostlingAppTests/TmuxEnvBindingTests.swift` (new)

## Overview

Does `GHOSTLING_CARD_ID` actually reach a pane the operator opens later? This is the
load-bearing half of US-004 and it is **separable from the ssh question entirely**: tmux
is tmux. Run it on **local tmux, no network at all**.

## Dependencies

- **`brew install tmux` — required, and currently absent on this machine.** This is the
  one new tool dependency the task introduces, and it buys the only automated coverage of
  the mechanism most likely to be silently wrong.
- Tests must skip loudly (not silently pass) when tmux is missing. A skipped test that
  reports green is the failure mode this whole task keeps documenting.
- The tmux **version must be asserted and recorded**, because the mechanism was chosen
  around a version floor.

## Test Cases

### TC-INT-007: A later `Ctrl-b c` pane carries the card ID (US-004 AC-2)

**Description:** **The case that matters.** A launch command sets one shell's *process*
env, not the tmux *session* env. Bind only the launch command and the second pane is
unbound — the card silently reads "not observed" while the terminal works fine.

**Testing the launch argv alone ships this green and broken.** That is why the assertion
is on the second pane's actual environment.

**Setup:**
```sh
tmux new-session -d -A -s tc-int-007 \
  'tmux set-environment GHOSTLING_CARD_ID <uuid>; GHOSTLING_CARD_ID=<uuid> exec $SHELL -il'
tmux new-window -t tc-int-007        # the Ctrl-b c equivalent
```

**Expected:**
- The **second** pane's env contains `GHOSTLING_CARD_ID == <uuid>`.
- Red without the `set-environment` half — which is exactly the form the first draft of
  DD-002 had. The test's value is that it goes red against the plausible design.

---

### TC-INT-008: `set-environment` needs no version floor (DD-002)

**Expected:** the command works on the installed tmux, and `new-session -e` is **not**
used. `-e` needs tmux ≥ 3.2 (verified in tmux CHANGES, "CHANGES FROM 3.1c TO 3.2"), while
Ubuntu 20.04 ships 3.0a and Debian 11 ships 3.1c. Under "remote OS: both/varies" that is
not a safe foundation; `set-environment` is tmux 1.0 and costs none of the
version-independence this decision is built on.

**Assert the emitted command contains no `-e` flag** — a regression here is invisible on
the developer's modern tmux and fatal on the operator's Ubuntu box.

---

### TC-INT-009: `-A` attach inherits stale env only under name reuse (US-004 edge case 1)

**Description:** Research called `-A`'s env inheritance the "highest-value finding" and
read it as fatal. **It is not** — on attach, tmux inherits the *original* session's env,
which belongs to the *same card*. Inherited env is stale **only** when a name is reused by
a **different** card, which AC-4 makes impossible. This is a card-modeling bug, not an
identity one.

**Expected:** re-attaching card A's own session yields card A's ID. Assert the revision,
so the fatal reading does not get re-introduced by a future reader of the research doc.

---

### TC-INT-010: A pre-existing hand-made session is not bound silently (US-004 edge case 4)

**Description:** The operator ran `tmux new -s ghostling` themselves before the card
existed. AC-4's uniqueness is scoped *across cards* and does not cover this. `-A`
**attaches and ignores the command argument**, so `set-environment` never runs, the pane
has no ID, and the card reads "not observed" while the terminal works perfectly.

**Expected:** the collision is detected — probe for the ID and either run
`set-environment` **post-attach** or surface the collision. **Must not bind silently to
nothing.**

---

### TC-INT-011: `(host, sanitized name)` is unique across cards (US-004 AC-4)

**Description:** The name field is free text, `sanitizeSessionName` is lossy, and blank
defaults to `"ghostling"` — so two cards named `ghostling` on one host genuinely *are* one
session, because `-A` attaches.

**Expected:** creating a second card that sanitizes to an existing `(host, name)` is
refused or disambiguated. Assert on the **sanitized** form: two distinct raw names can
collide after sanitization, and that is the case that ships.
