# Research: Remote File / Folder Picker

**Date:** 2026-07-16
**Status:** Complete

## Summary

The production folder picker is **not** `FolderPicker.swift` — that file's
`FolderPickerView` is only referenced by tests. The real picker is
`CreateCardPalette`'s project stage plus a bare `NSOpenPanel`
(`BoardShell.swift:920-928`), which is local-only by construction. A remote picker
cannot reuse `NSOpenPanel` at all; it needs a new list-directory data source. The
cheapest correct source is an `ssh + ls` RPC over the same ssh path the ⌘⇧R card
already uses.

## Key Findings

1. **`FolderPicker.swift` is effectively dead production code**
   - Evidence: `grep -rn "FolderPickerView\|FolderRow\|RecentFolder"` across
     `app/Sources` returns hits **only inside `FolderPicker.swift` itself** plus
     `app/Tests/GhostlingAppTests/FolderPickerTests.swift:9-45`.
   - The one thing in that file production *does* use is `SahaTaskChooserView`
     (`BoardShell.swift:28`, `:1085`) — a different class that happens to live there.
   - Implication: **the task brief's premise ("the folder picker is FolderPicker.swift")
     is wrong.** Building a "remote FolderPicker" would ship a second dead view.
     The work belongs in `CreateCardPalette`.

2. **The real picker: `CreateCardPalette` stage `.project` + `NSOpenPanel`**
   - Evidence: `CreateCardPalette.swift:347` `private(set) var stage: Stage = .project`;
     `:349-350` `recents: [PaletteProject]` / `projectDir: String`; `:527` a
     "Browse folder…" row; `:335` `var browse: (() -> String?)?` — the injected seam.
   - The shell wires `browse` to `BoardShell.chooseFolder` (`:920-928`):
     `NSOpenPanel` with `canChooseDirectories = true`, returning `panel.url?.path`.
   - Recents come from `UserDefaults` (`BoardShell.swift:932-950`, key
     `ghostling.recentProjectDirs`, capped at 6).
   - Implication: there is **one clean injection point** (`browse`) and one string
     (`projectDir`) that would need to become host-aware. That's the good news.

3. **`NSOpenPanel` is structurally incapable of browsing a remote box**
   - It is a local-filesystem chooser. There is no supported way to point it at an
     ssh host. (Ruled out on first principles — no code evidence needed.)
   - Implication: a remote picker is a **new custom view**, not a configuration of
     the existing one. This is real UI work, not a flag.

4. **`projectDir` is a bare `String` everywhere, and already abused for remote**
   - Evidence: `BoardCard.projectDir`, `BoardSeed.projectDir`,
     `SessionRegistry.launch(projectDir:)`, `PaneSnapshot.cwd` — all `String`.
     `BoardSeed.swift:117` already stuffs `"roman@host"` into it for remote cards.
   - Implication: the honest fix is a `(host: String?, path: String)` location type
     threaded through card creation/persistence. That is a **wide, invasive
     refactor** touching card model, seed, registry, snapshot, and restore. It is
     also the only way to stop `projectDir` meaning two different things.
     **Flag for `/saha:decide`** — this is the biggest hidden cost in the task.

5. **Recents (`UserDefaults` string array) cannot represent a remote folder**
   - Evidence: `BoardShell.swift:934` `UserDefaults.standard.stringArray(forKey:)`.
   - `RecentFolder` derives its branch chip by reading `<gitdir>/HEAD` **off the
     local disk** (`FolderPicker.swift:358-365`, via `GitWorktree.gitDir`), and its
     parent display via `abbreviatingWithTildeInPath` (`:347`).
   - Implication: even the *decoration* of a recents row assumes a local FS. A
     remote recents row must either drop the branch chip or fetch it remotely.

## Options for the remote directory source

### Option A — `ssh <host> ls` RPC (recommended)
One short-lived `ssh host 'ls -1Ap --...'`-style call per directory expansion,
parsed into rows.
- **Pros:** zero remote install; reuses the user's ssh identity/known_hosts —
  **no new auth surface**; symmetric with doc 02's Option A and with ⌘⇧R; passes
  `PoolFirewall` trivially (`argv[0] == ssh`).
- **Cons:** ~100-300ms latency per directory (over Tailscale, plausibly more) —
  the picker must be async and show a pending state, or it will feel broken.
  ssh connection setup dominates; **mitigate with `ControlMaster`/`ControlPersist`**
  so the second listing reuses the first's connection. This is the single highest-
  leverage detail for making it feel native.
- **Portability trap:** `ls -p`/`-1` are POSIX; `--group-directories-first` is
  GNU-only. Use `find . -maxdepth 1` or plain `ls -1Ap` and classify by trailing `/`.

### Option B — `sftp` / `scp` subsystem
- **Pros:** structured listing; no `ls` output parsing; connection reuse built in.
- **Cons:** no Swift sftp client in this repo's dependency set (the project is
  aggressively dependency-averse — see `StaticFileServer.swift:9` "ponytail:
  NWListener over a dependency"). Driving `/usr/bin/sftp` in batch mode means
  parsing its output anyway, i.e. Option A with extra steps. Adding libssh2 is a
  new C dependency in a project that already vendors an xcframework — **poor
  cost/benefit**. Reject.

### Option C — a small remote helper binary
- **Pros:** fast, structured JSON, could also carry hook forwarding + quota.
- **Cons:** **you must now build, ship, version, and update a binary on every
  remote box**, cross-compiled for the remote's arch/OS. This is a distribution
  problem the project has zero infrastructure for. Massive scope inflation for a
  directory listing. **Reject for the picker.** (Reconsider only if doc 02's
  transport *also* wants an agent — it doesn't; `tail` suffices.)

### Option D — reuse the Python sidecar
- **Not possible.** The sidecar was **retired** — `pyproject.toml:1-8`: "no Python
  runtime, no localhost sidecar, no HTTP wire." There is nothing to deploy.
  ⚠️ This corrects the stale memory note.

## Recommendation

**Option A**, with `ControlMaster` connection reuse, async listing, and a visible
pending/error state. Build it as a new stage in `CreateCardPalette` (the reachable
surface), **not** as a new view in `FolderPicker.swift`.

## Risks Identified

1. **`projectDir: String` → host-aware location is a wide refactor** (Severity: High)
   - Touches `BoardCard`, `BoardSeed`, `SessionRegistry.launch`, `PaneSnapshot.cwd`,
     `SessionRestorer.resolveCwd`, recents. Underestimating this is the main way
     this task blows up.
2. **Latency makes an ssh-backed picker feel broken** (Severity: Medium)
   - Mitigation: `ControlPersist`, prefetch the parent listing, show a spinner.
   - This project's own rule: never fake a value — an unlisted dir must read
     "couldn't reach host", not "empty folder".
3. **Building the picker in the dead `FolderPicker.swift`** (Severity: Medium)
   - Would be green-but-unreachable — the exact trap logged in
     `saha-creation-had-no-ui-entry-point`. The AC must dispatch a **real** event
     against the `CreateCardPalette` surface (per the interaction-AC-binding rule).

## Open Questions

- Should the remote picker browse arbitrary paths, or just pick from a
  remote-recents list the user seeds by typing a path once? **The latter is ~10%
  of the work and may be 90% of the value** — the user likely has 1-3 repos on
  that box. Worth asking before building a tree browser.
