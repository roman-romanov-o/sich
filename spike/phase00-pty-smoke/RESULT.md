# Phase 00 — libghostty embedding spike: **GO**

**Date:** 2026-06-16 · **Run:** autonomous (with per-step human confirmation)
**Machine:** macOS 15 / arm64 · Xcode 16.2 / AppleClang 16 · CMake 4.2.1 · Ninja 1.13.2 · Zig **0.15.2** · Homebrew 6.0.1

## Verdict

Embedding **libghostty-vt** and reading a child process's PTY output **in-process**
(no AppleScript, no screen-scrape, no GUI required) works **today** on a pinned
revision. The keystone US-004 capability is proven. **GO.**

## What was proven

1. **Builds from a pinned revision.** `ghostling`'s CMake fetches ghostty at
   `ae52f97dcac558735cfa916ea3965f247e5c6e9e` and runs `zig build lib-vt`
   (Zig **0.15.2**) to produce `libghostty-vt.a`, `libghostty-vt.dylib`, **and an
   `ghostty-vt.xcframework`** (`macos-arm64_x86_64`, `ios-arm64`,
   `ios-arm64-simulator`) — i.e. a Swift/Xcode-ready embedding artifact.

2. **In-process PTY read → terminal state (headless).** `spike/phase00-pty-smoke/`
   spawns `/bin/echo hello-ghostty` via `forkpty()`, reads the master fd in-process
   (15 bytes), feeds the bytes to `ghostty_terminal_vt_write()`, then reads the
   screen back as plain text via the formatter API. The screen contains
   `hello-ghostty`. Exit 0. The static `.a` linked with **zero** extra system libs,
   confirming libghostty-vt is self-contained.

3. **Full terminal renders.** The complete `ghostling` demo (libghostty-vt render-state
   API + Raylib/OpenGL) builds to a Mach-O arm64 binary and opens a live, interactive
   terminal window (GLFW-Cocoa + OpenGL initialized).

## Correction to the prior framing

The earlier project docs claimed Phase 00 "needs a human GO/NO-GO" and that the
libghostty embedding API is "roadmap, not released." The spike falsifies the load-bearing
parts of that:

- **`swift`/`xcodebuild`/Xcode were already installed**; only Zig was missing, and the
  exact version is pinnable (`0.15.2` — note Homebrew ships `0.16.0`, which would **not**
  build this rev; use the pinned 0.15.2).
- What is genuinely "roadmap, not released" is a **pre-baked GPU renderer / drop-in Swift
  widget**. The layer we actually need — **libghostty-vt** (VT parsing + terminal state) +
  the **render-state API** (bring-your-own-renderer) — is **shipped and stable**, with a C
  header (`ghostty/vt.h`), a static lib, a dylib, and an xcframework.
- The acceptance criteria ("echo echoes; spike reads that line in-process") are
  **programmatically assertable** — no human eyeball required.

> Caveat noted, not blocking: `vt.h` says the API is "work-in-progress … breaking changes
> expected." DD-001's mitigation stands — pin the revision and keep a fail-loud integration
> smoke (this one) that breaks on signature drift.

## What this unblocks

- **Phase 01 (Terminal Foundation):** vendor `ghostty-vt.xcframework` into a Swift/AppKit
  target; host a terminal surface; the in-process PTY read shown here feeds the existing
  Python detector's PTY signal source (or a Swift equivalent).
- The pool-firewall discipline is unchanged: managed sessions run interactive `claude` in
  our owned PTY (interactive pool), never `claude -p`.

## Reproduce

```sh
# 1. Build libghostty-vt once (also builds the full ghostling demo):
cd /tmp && git clone https://github.com/ghostty-org/ghostling ghostling-recon
cd ghostling-recon
PATH=/path/to/zig-0.15.2:$PATH cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
PATH=/path/to/zig-0.15.2:$PATH cmake --build build
./build/ghostling                      # visual: opens a terminal window

# 2. Headless in-process PTY-read smoke (this spike):
GHOSTTY_OUT=/tmp/ghostling-recon/build/_deps/ghostty-src/zig-out \
  spike/phase00-pty-smoke/build.sh     # prints "GO: ... contains \"hello-ghostty\"", exit 0
```

Files: `smoke.c` (the harness), `build.sh` (build + run), this `RESULT.md` (the record).
