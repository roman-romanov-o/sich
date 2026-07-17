# Integration Test Spec: Remote Hook Install + Probe

**Related:** US-005, US-002 (AC-1), [code-changes/remote-host-state.md](../../code-changes/remote-host-state.md)
**Priority:** High
**Status:** Draft
**Suite:** `app/Tests/GhostlingAppTests/RemoteHookInstallTests.swift` (new)

## Overview

Install the forwarder on a host; read back what is actually there. Covered at integration
level because the ssh hop is substituted — the file operations and the hash comparison are
real.

## Dependencies

- A temp dir standing in for the remote `~/.claude/`.
- A substitute child at the install/probe argv seam.

## Test Cases

### TC-INT-012: Install writes byte-identical bytes (US-005 AC-1)

**Description:** Two ways to ship this broken, both specified against:

1. **The channel must not allocate a PTY.** A PTY translates LF → CRLF; every byte after
   the first newline shifts. This is not hypothetical — `argv(for:)` **hardcodes `-t`**
   (`RemoteTmuxCommand.swift:109`), so inheriting the obvious pattern ships the bug.
2. **The script must be piped on stdin, never interpolated into a remote shell word.**
   `forwarderScript` contains `$HOME`, `$GHOSTLING_CARD_ID`, `$file`, `$@`. An unquoted
   heredoc expands them on the far side, and the result is a host that reports
   `staleVersion` **forever** while running a subtly broken forwarder.

**Expected:**
- Remote bytes `==` `forwarderScript` bytes, exactly.
- The install argv contains **no `-t`** and no interpolation of the script into a word.

---

### TC-INT-013: A freshly-installed host reads `installed` (US-005 AC-2)

**Expected:** `installed`.

**This case does *not* catch the `-t` bug, and an earlier draft of this spec claimed it
did.** The claim was false for the same reason the spec exists: LF→CRLF translation needs a
**real ssh PTY**, and against a substituted local child `-t` is an inert string in an argv
nobody hands to ssh. The case passes with `-t` and without it.

The `-t` coverage lives in two real places instead, and this case is worth writing for what
it *does* assert — that the whole install → probe → `installed` round trip closes:
- **TC-INT-012** asserts the install argv contains no `-t`. Cheap, exact, and red today if
  the `-t` pattern is inherited from `argv(for:)`.
- **TC-E2E-019** runs the probe over a real ssh channel to a real host, which is the only
  place a PTY can actually translate a byte.

---

### TC-INT-014: Install state is probe-derived, never cached (US-005 AC-2)

**Setup:** install successfully (→ `installed`); then make the probe **fail**.

**Expected:** state becomes `unknown`. **A cached boolean passes a naive test and ships
the bug** — that is why the failure is staged *after* success rather than before.

---

### TC-INT-015: All four states, and `unknown` is never collapsed (US-005 AC-3)

| Remote condition | Expected |
|---|---|
| bytes match ours | `installed` |
| file absent | `notInstalled` |
| bytes differ | `staleVersion` |
| probe itself failed | `unknown` |

**Assert the negative:** `unknown` must never render as `installed`. This is the
silent-failure class of `board-status-bug-was-missing-global-hooks`, where "the card never
moves" turned out to be missing hooks rather than the feature under suspicion.

---

### TC-INT-016: The comparand is a hash, computed on the laptop (US-005)

**Description:** There is **no version to compare against**. `forwarderScript` carries no
version marker of any kind — it stamps nothing into the file it writes, so a probe has
nothing to read back. `staleVersion` as first written had no writable test spec, because
nothing on disk could make it true.

(An earlier draft supported this with `grep -c version HookInstaller.swift` → **0**. The
actual count is **1**: `--help|-h|-V|--version) return 1 ;;` at `:328`, the shim's own
argument parsing — unrelated to the forwarder's contents. The conclusion stands; the
evidence offered for it did not.)

**Expected:**
- Ours = `sha256(forwarderScript)`, hashed at runtime in `GhostlingApp` — `HookInstaller`
  is an internal `enum` and `forwarderScript` is `private let`, so **no other module can
  compute the local half**. This is why `installArgv(for:script:)` takes the script as a
  parameter: the App owns the bytes; `GhostlingCore` builds argvs and never learns what a
  forwarder is.
- Theirs = the probe `cat`s the remote file and hashes **on the laptop**. Assert **no
  remote hash tool is invoked**: `sha256sum` (GNU) vs `shasum -a 256` (BSD) is exactly the
  userland split US-002 exists to handle, and this avoids buying into it for a few KB.
- A local edit to `forwarderScript` makes hosts read `staleVersion`. **That is correct,
  not a false positive** — the remote genuinely is running older code.

---

### TC-INT-017: The forwarder parses under GNU userland (US-002 AC-1)

**Description:** The fixture must be built under **GNU coreutils semantics**, not the
Mac's. Two concrete divergences: `plutil` **does not exist** on Linux (the forwarder's
`plutil -extract` gate), and GNU `base64` **wraps at 76 columns** while the forwarder's
`base64 | tr -d '\n'` assumes it can strip that.

**Expected:** a GNU-shaped `turn_diff` line normalizes correctly. A fixture captured on
macOS is the same shape as the code under test and proves nothing about the host the
operator actually uses.

**Note:** this is the automatable half. The real Linux box is
[e2e/real-linux-host-signoff.md](../e2e/real-linux-host-signoff.md) TC-E2E-017.

---

### TC-INT-018: The install/probe argvs pass `PoolFirewall` (US-005 AC-6, US-003 AC-5)

**Expected:** both are generated from a constrained spec, never composed from free text,
and both route through the firewall. **No new remote binary is distributed** (US-005 AC-5)
— this ships the same shell script the laptop already writes.
