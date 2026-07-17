# Unit Test Specs

Only where the logic is pure and the stakes are real. Neither of these is glue.

| Spec | Stories | Cases | Why not higher |
|------|---------|-------|----------------|
| [ssh-argv-and-firewall.md](ssh-argv-and-firewall.md) | US-001 | TC-UNIT-001..007 | Total functions over strings, enforcing the product's one economic invariant. **TC-UNIT-004 distinguishes the correct guard from the plausible wrong one — no E2E could: both guards produce a running ssh.** |
| [dedup-keys.md](dedup-keys.md) | US-008 | TC-UNIT-008..011 | Keys are pure functions of bytes. The **behaviour** they protect is asserted at E2E (TC-E2E-006) — these assert the keys themselves. |

US-001's unit-heaviness is a deliberate departure from "unit-only coverage is a red flag,"
argued in [../coverage-matrix.md](../coverage-matrix.md). It closes a hole reachable from
⌘⇧R in shipped code today.
