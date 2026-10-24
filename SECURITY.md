# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/roman-romanov-o/sich/security/advisories/new)
rather than in a public issue. You will get an acknowledgement within a week.
Fixes ship in the next release and are credited in the release notes unless
you ask otherwise.

## Supported versions

Only the latest release on the
[Releases](https://github.com/roman-romanov-o/sich/releases) page receives
fixes.

## What Sich touches on your machine

Knowing the surface helps you judge a report:

- It spawns your login shell and interactive agent CLIs in PTYs it owns, and
  structurally refuses to run headless `claude -p` (see `PoolFirewall`).
- It installs hook forwarders into the agent CLIs' config so their lifecycle
  events reach the board, and reads the local event log they write.
- It reads the Claude OAuth token from your keychain to query your own usage
  endpoint for the quota gauges. Nothing is sent anywhere except to that
  endpoint.
- Remote cards run `ssh` and `tmux` with the destination you typed; the app
  never installs binaries on the remote host.
- The release bundle is ad-hoc signed and not notarized. Verify the SHA-256
  printed in the release workflow log before installing.
