# Contributing to Sich

Thanks for looking under the hood. Sich is a single Swift package in `app/`
plus a bash hook forwarder in `.claude/scripts/`; there is no backend.

## Build from source

1. Install Xcode 16 or later (Swift 6).
2. Rebuild the vendored libghostty-vt archives once. They are too large for
   git, so a fresh clone cannot link until you run, with Zig 0.15.2 on PATH:

   ```bash
   app/scripts/build-ghostty-vt.sh
   ```

   See [`app/Frameworks/README.md`](app/Frameworks/README.md) for the pins.
3. Then:

   ```bash
   cd app
   swift build
   swift test
   swift run sich
   ```

## Before opening a pull request

CI runs the same gates on every PR. Running them locally saves a round trip:

```bash
cd app
swift build -Xswiftc -warnings-as-errors   # warnings fail the build
swift test                                  # the full suite
periphery scan --baseline .periphery-baseline.json --strict   # dead code, vs. baseline
cd .. && uv run --with pytest pytest tests  # the forwarder's rotation test
```

A few conventions that keep the codebase honest:

- **Interaction tests dispatch real events.** A test for a click or a key
  press sends an `NSEvent` at the mounted view; it does not call the handler.
- **The pool firewall is not negotiable.** Nothing may spawn headless
  `claude -p`, and the two Anthropic quota pools are never summed. See
  [`docs/PRODUCT.md`](docs/PRODUCT.md) for the invariants.
- **Shrink the dead-code baseline, never widen it.** If Periphery flags new
  dead code, remove the code. Re-baseline only after a cleanup:
  `periphery scan --write-baseline .periphery-baseline.json`.
- **Keep PRs focused.** One change per PR, with a title that says what the
  user sees differently.

## Releasing

Push a tag `vX.Y.Z` on `main`. The release workflow builds the universal
`Sich.app`, stamps the version, and attaches the zip to a GitHub Release.
