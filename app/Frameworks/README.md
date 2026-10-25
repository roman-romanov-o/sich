# Vendored `ghostty-vt.xcframework`

This is **libghostty-vt** — the virtual-terminal core extracted from
[Ghostty](https://ghostty.org) — packaged as an `.xcframework` (macOS + iOS
slices) and consumed by the `GhosttyVt` binary target in `../Package.swift`.

It is the artifact proven by the Phase 00 spike (`/spike/phase00-pty-smoke/`).

## What's tracked vs. ignored

The headers, `module.modulemap`, and `Info.plist` are **committed** — they are
the ABI of record this code is compiled against, and a cheap way to detect
upstream signature drift (the C API is explicitly work-in-progress).

The compiled static archives (`*.a`, ~16M each) are **git-ignored** (see the
repo `.gitignore`). Regenerate them with the rebuild below after a fresh clone.

## Provenance (exact, non-obvious)

| Pin | Value |
|-----|-------|
| Source | `ghostty-org/ghostty`, `zig build -Demit-lib-vt` |
| ghostty rev | `ae52f97dcac558735cfa916ea3965f247e5c6e9e` |
| Zig | **0.15.2** — Homebrew ships a newer Zig, which will **not** build this rev. Get it from ziglang.org. |
| Also needs | Xcode command line tools (`xcodebuild` produces the xcframework) |

Both pins live in one place, `app/scripts/build-ghostty-vt.sh`; CI keys its
cache of the archives on that file.

## Rebuild

```bash
# with Zig 0.15.2 on PATH
app/scripts/build-ghostty-vt.sh
```

The script fetches the pinned revision, builds `lib-vt`, and copies only the
`*.a` slices into this directory next to the tracked headers.
