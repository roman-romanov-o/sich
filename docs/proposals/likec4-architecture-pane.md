# LikeC4 Architecture Pane — Spec

Status: **approved direction, not yet implemented**.
Companion spec: `sahaidachny/docs/proposals/likec4-architecture-model.md`.

Division of labor (fixed): saha owns the model (plain-text LikeC4 DSL under
the bound project's `docs/architecture/*.c4`); **this app owns all rendering.**

## What

Planning Mode gains an optional **Architecture** pane: the project's LikeC4
model rendered with full interactivity (drill-down between abstraction
levels, zoom, view navigation). Task docs that reference `task-NN-*` view ids
deep-link the pane to that view.

## Design rules

1. **Lazy everything.** The pane costs 0 RAM until opened and 0 RAM again
   after close. No persistent helper processes, ever.
2. **Never `likec4 start`.** The persistent node dev server (~200–400 MB
   resident) is banned; content is always a static `likec4 build` output.
3. Missing CLI degrades exactly like mermaid does today: show the `.c4`
   source plus an install hint, never crash, never block Planning Mode.
4. One shared pane/webview instance app-wide — never one per card.

## How

### Rendering surface

- `WKWebView` (native AppKit), created on first open of the pane, torn down
  on close — the WebContent process exits and its memory returns.
- Content: `likec4 build -o <cache-dir>` static SPA, served on
  `127.0.0.1:<ephemeral>` by a minimal embedded HTTP server (SPAs are
  unreliable from `file://`). The server lives only while the pane is open.
- Deep-link to a view via the built site's view route (e.g.
  `#/task-03-quota-flow` per the saha naming contract).

### Build & cache

Mirror `MermaidRenderer` (`app/Sources/GhostlingApp/MermaidRenderer.swift`):

- CLI detection: probe `/opt/homebrew/bin/likec4`, `/usr/local/bin/likec4`
  (same fixed-path pattern as `mmdcPath`).
- Cache: `~/Library/Caches/Ghostling/likec4/<model-hash>/` where the hash is
  SHA256 over the concatenated `*.c4` sources — unchanged model, zero
  rebuilds across launches.
- Rebuild: file-watch `docs/architecture/*.c4` in the bound project,
  debounced; `likec4 build` runs transiently off the main thread (node spikes
  ~300–500 MB for a few seconds, then exits), webview reloads when it lands.
  First open with a cold cache shows a "building…" state, not a blank pane.
- Build failure (DSL error mid-edit): keep showing the last good build with a
  non-blocking error strip; fall back to source + error if there is no good
  build yet.

## Fixed budget

| State | Cost |
|-------|------|
| Pane closed | 0 (no webview, no server, no watcher-triggered builds needed eagerly — a stale cache rebuilds on next open) |
| Pane open | one WebContent process, ~150–300 MB for a typical model; app-side a few MB |
| Model edit | transient node process for seconds |

No quota interaction: `likec4` is local tooling, not an agent — the
watcher-not-spawner invariant is untouched.

## Deferred (explicitly later)

- `WKScriptMessageHandler` bridge: click an element in the diagram → native
  callback (focus a card, open a file). Add once the read-only pane proves
  itself.
- Bundling a likec4 renderer to drop the CLI dependency — only if the CLI
  requirement becomes a real support burden (same upgrade path already noted
  in `MermaidRenderer`).

## Not doing

- `likec4 start` / any resident node process.
- A webview per card.
- Native re-implementation of the renderer (xyflow) from `likec4 export
  json` — a multi-month yak shave.
- User-story dependency graphs in this pane — those render natively (Grape)
  from structured plan data; LikeC4 is for authored architecture only.
