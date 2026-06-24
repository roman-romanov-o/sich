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
| Source | `ghostty-org/ghostling` (CMake superbuild) which fetches `ghostty` |
| ghostty rev | `ae52f97dcac558735cfa916ea3965f247e5c6e9e` |
| Zig | **0.15.2** — Homebrew ships 0.16.0, which will **not** build this rev. Get it from ziglang.org (`zig-aarch64-macos-0.15.2`). |
| Also needs | CMake ≥ 3.19, Ninja, Xcode CLT |

## Rebuild

```bash
git clone https://github.com/ghostty-org/ghostling /tmp/ghostling
cd /tmp/ghostling
# ensure the pinned Zig 0.15.2 is on PATH (not Homebrew's 0.16.0)
cmake -B build -G Ninja
cmake --build build
# the xcframework lands at:
#   build/_deps/ghostty-src/zig-out/lib/ghostty-vt.xcframework
cp -R build/_deps/ghostty-src/zig-out/lib/ghostty-vt.xcframework \
      "$REPO/app/Frameworks/ghostty-vt.xcframework"
```
