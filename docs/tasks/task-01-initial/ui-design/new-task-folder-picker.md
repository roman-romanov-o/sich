# UI Design: New-Task Project-Folder Picker

**Status:** Review
**Phase:** Pre-Implementation (refines the existing `promptForNewTask()` in `BoardShell.swift`)
**Surface:** the "+ new task" creation modal — specifically the *project-folder* control.

## Overview

**What we're designing:** the folder-selection UX inside the "+ new task" modal. The
operator picks (1) a **task title** and (2) the **project folder** the new live-terminal
card `cd`s into. The current stock `NSComboBox` of long absolute paths is the disliked
part; this redesign replaces it.

**Target users:** a technical, keyboard-first operator who lives in terminals and runs
several parallel sessions. The common case is *reuse a recent project*; the rarer case is
*point at a brand-new folder*.

**Key interaction:** glance → recognise the project by its leaf name → one click → Create.

## Design Context

### Existing Patterns (reused, not invented)

| Pattern | Location | Reuse? |
|---------|----------|--------|
| Leaf name bold + faint `◇ ~/dir` subtitle in mono | `SessionCard.projectSubtitle()` | **Yes** — the row/tile is a card subtitle |
| `BoardTheme.shortPath()` (collapse abs path → leaf) | `BoardTheme.swift:83` | **Yes** — exactly the "leaf prominent, parent faint" rule |
| Flow-B teal accent for human-launched work | `BoardTheme.flowColor(.b)` = `#2DD4BF` | **Yes** — the modal's accent + selected ring |
| Tinted rounded chip = `ChipLabel` (the label *is* its own fill) | `SessionCard.swift:271` | **Yes** — git-branch / segmented chips |
| Selected = `cardFillRaised` + 1px flow ring | `SessionCard.configureLayer()` | **Yes** — selected folder tile/row |
| MRU persisted in UserDefaults, repo-root always present | `BoardShell.recentProjectDirs()` | **Yes** — the data source, unchanged |

### Brand/Style Constraints (Deep Slate / Aurora)

- **Colors:** canvas `#0D1117`, surface `#161C26`, raised `#1E2733`, stroke `#2A3340`;
  text `#E6EDF3` / muted `#9DA9B8` / faint `#7E8A9C`; **Flow-B teal `#2DD4BF`** (this is a
  human-launched task), Flow-A violet `#A06BFF` (used only for the git-branch chip), error
  `#F0533F`.
- **Typography:** title `SF Pro Text` 13–15; **all paths, leaf names, branches, ages in
  mono** (`SF Mono` 10–13) — mono signals "machine state", matching the cards.
- **Spacing:** 8px grid, card padding 8–12, modal body gap 14.
- **Components:** custom-drawn layer-backed `NSView` + `NSStackView` of labels — never
  stock bezels. (The chip/pill must paint via the label's own layer, per the iter-4
  invisible-pill defect note.)

## Design Requirements

### Must Have
- [x] The common case (reuse a recent project) is **one obvious click**, not a dropdown.
- [x] Each recent entry shows the **leaf name prominently** + the parent path faint
      (`◇ ~/MyProjects`), the card idiom — never a bare long absolute path.
- [x] A brand-new folder is reachable via the **native macOS chooser** (`NSOpenPanel`),
      present but **not dominating**.
- [x] Keyboard-first: arrow/Tab to move selection, Enter = Create, Esc = cancel.
- [x] Matches Deep Slate; the modal carries the **Flow-B teal** cue (new human task).

### Should Have
- [x] Light context per folder — **git branch** + **last-used time** — only because both
      are cheap (branch = read `.git/HEAD`; time = the MRU already stores order).
- [x] Empty (first-run) and error (bad path) states designed.

### Could Have
- [ ] Per-project colour the operator can pin (deferred — MRU has no colour field yet).
- [ ] Fuzzy/subscring match scoring (approach B shows the shape; v1 can be prefix-only).

## Aesthetic Direction

**Direction:** `minimalist-functional` — an operator panel, calm and dense, that reuses
the board's own card language so the picker feels like "a tiny board of your projects",
not a generic file dialog.

### Visual Characteristics
- **Color palette:** Deep Slate; Flow-B teal is the only saturated accent (selection +
  primary button); red reserved for the bad-path error.
- **Shape language:** 8–12px rounded, 1px hairlines, elevation by border + bg-lift (no
  heavy shadows except the modal's own drop shadow over the scrim).
- **Motion:** selection ring fades in ~120ms; honour `prefers-reduced-motion` (instant).
- **Density:** compact — 4–6 recents visible without scrolling inside a ~420–470px modal.

## The three approaches (mocked + screenshot-verified)

All three keep the **title field on top** and the **folder control below**, both inside a
custom sheet (not a stock `NSAlert`). Screenshots: `mockups/screenshots/`.

### Approach A — recent-folders **list** + "Choose…"
A vertical list of full-width rows: colour-seeded folder glyph, `leaf` (bold mono) +
`branch` chip + `◇ ~/parent` (faint) + `last-used`, with a teal selected ring + check. A
quiet dashed **"Choose a different folder… ⌘O"** row at the bottom opens `NSOpenPanel`.
- **Pros:** highest density, simplest to build, the path never truncates (full row width),
  reads instantly. **Cons:** less "designed" than tiles; long parent paths can still get
  wide (mitigated by `shortPath`/ellipsis).

### Approach B — **filter-as-you-type** combobox over recents
A search row (mono caret) that filters the recents live, **highlighting the matched
substring** in teal (in both the leaf and the path). Unrecognised text offers a
*"Use '…' as a literal path"* row, so a raw path still works. `NSOpenPanel` lives below as
a ghost button.
- **Pros:** fastest for a power user who knows the name; scales past ~6 recents; keeps the
  "type a path" escape hatch. **Cons:** the resting state shows a search box, not the
  projects — the one-click-recognition case is one keystroke slower; more logic to build.

### Approach C — **recent grid + Browse tile** (RECOMMENDED)
A 2-up grid of **project tiles** in the exact card idiom (glyph, leaf, faint parent, branch
chip, last-used), a `recent | browse` segmented control, and a dashed **Browse…** tile
(→ `NSOpenPanel`). Typing still filters (inherits B's behaviour); the segmented control
makes "I want the native chooser" a single, discoverable target.
- **Pros:** the projects ARE the resting state (zero keystrokes to recognise + click);
  visually it reads as a mini-board so it's instantly on-brand; Browse is a first-class but
  non-dominating tile; degrades to A's behaviour if you'd rather type. **Cons:** widest
  (~468px) and the most layout to build; leaf names truncate sooner in a half-width tile
  (mitigated — tiles show ~20 chars before the ellipsis, enough for real project names).

**Recommendation: Approach C**, with **A as the low-risk fallback.** C wins because it
turns "where" into a *recognition* task (see the project, click it) instead of a *recall*
task (remember/retype a path), and it does so in the product's own card language so it
feels native to the board. If implementation time is tight, ship **A** first — it delivers
~90% of the value (one-click recents, leaf+faint-path, native Choose) with a fraction of
the layout work, and B/C can layer the grid + type-filter on later. B's filter behaviour
should be *folded into* whichever of A/C ships (type-to-filter the visible rows/tiles), not
shipped as its own resting UI.

## Component Breakdown

### Component 1: Folder tile / row (the shared unit)
**Purpose:** present one recent project so it's recognisable at a glance and one click to pick.

**States** (see `mockups/screenshots/20-states-recommended.png`):
- **Default:** `cardFill` bg, `cardStroke` border; leaf bold mono `textPrimary`; parent
  `◇ ~/dir` faint mono `textFaint`; `⎇ branch` chip in Flow-A violet tint; `last-used`
  faint right.
- **Hover:** `cardFillRaised` bg + `cardStrokeStrong` border (no commitment yet).
- **Selected:** `cardFillRaised` + 1px **Flow-B teal** ring + 3px teal left rail (tile) /
  trailing teal ✓ (row) + soft lift. This is the dir `Create` will use.
- **Disabled:** n/a (a recent dir is always selectable; a *missing* one → Error, below).
- **Error (bad path):** if the typed/chosen path doesn't exist or isn't a directory, the
  control gets a red `alert` border + a mono `⊘ <path> is not a folder.` line; **Create is
  disabled** until resolved.
- **Empty (first run):** no MRU yet → a centred faint `◇ No recent folders yet. Pick one
  with Browse… ⌘O` (the repo root is still implicitly selectable).

### Component 2: Browse affordance
**Purpose:** reach a brand-new folder via the native macOS chooser.
**States:** Default (dashed `cardStroke`, brand-blue `⊕`); Hover (brand-blue border +
faint blue wash). Activating opens `NSOpenPanel` (`canChooseDirectories = true`,
`canChooseFiles = false`); on return the chosen dir becomes a new selected tile/row and is
pushed to the MRU.

### Component 3: Title field
**Purpose:** the human task name → the card headline. Plain sunken `NSTextField`, teal
focus ring. First responder on open. Empty title is allowed (card falls back to leaf), but
the modal nudges it as the required `*` field.

### Component 4: Segmented `recent | browse` (Approach C only)
**Purpose:** make "native chooser" a discoverable target without a second dialog.
Custom 2-segment toggle in the mono chip idiom; `recent` shows a count badge.

## User Flows

### Primary Flow: reuse a recent project
```
[+ new task]  →  modal opens, title field focused, most-recent folder pre-selected
    ↓ (operator types a title, e.g. "Fix the login redirect")
    ↓ (folder already correct → just hit Enter,  OR  click/arrow to another recent tile)
[Enter / Create task]
    ↓
[BoardShell.createSession(title:, projectDir:) → live Flow-B terminal card on the board]
    ↓
[rememberProjectDir(dir) bumps it to the front of the MRU]
```

### Secondary Flow: brand-new folder
```
[click Browse… tile  /  ⌘O]
    ↓
[NSOpenPanel — directories only]
    ↓ (choose a dir)  /  (cancel → back to modal, no change)
[chosen dir becomes the selected tile, pushed onto the MRU]
    ↓
[Create task]
```

### Error Flow: typed path is not a folder (only when free-text entry is used)
```
[operator types a literal path that doesn't resolve]
    ↓
[control turns red: "⊘ ~/MyProjects/typo is not a folder." — Create disabled]
    ↓
[fix the path or pick a recent → error clears, Create re-enabled]
```

## Accessibility Requirements
- [x] Contrast: leaf `#E6EDF3` and muted `#9DA9B8` clear ≥4.5:1 on `cardFill`; faint
      `#7E8A9C` is metadata-only (last-used/parent), still ≥4.5:1 on canvas per the lifted
      token; the red error text on `bg-sunken` clears AA.
- [x] **State never color-only:** selected = ring **+** ✓/rail (shape), error = `⊘` glyph
      **+** text, branch = `⎇` glyph + label. A colour-blind operator reads every state.
- [x] Keyboard navigable: Tab into the grid/list, ↑↓/←→ move selection, Enter = Create,
      Esc = cancel, ⌘O = Browse. First responder = title field.
- [x] Visible focus ring = the Flow-B teal ring (never focus-by-colour-alone — it's a ring).
- [x] `prefers-reduced-motion`: selection/hover transitions become instant.
- [x] VoiceOver: each tile/row exposes `accessibilityLabel = "<leaf>, branch <x>, in
      <parent>, used <when>"`; Browse exposes "Choose a different folder".

## Technical Constraints
- **Framework:** AppKit, custom-drawn layer-backed views (no SwiftUI, no stock bezels).
- **CSS approach:** the HTML mockup is a *visual spec only* — tokens map 1:1 to
  `BoardTheme` NSColors (see translation table). Not shipping code.
- **Animation:** Core Animation implicit transitions / `NSAnimationContext`, gated on
  `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.

## Design Artifacts

| Artifact | Status | Location |
|----------|--------|----------|
| Three-approach deck | Done | `mockups/screenshots/00-deck-all-three.png` |
| Approach A close-up | Done | `mockups/screenshots/10-A-recent-list.png` |
| Approach B close-up | Done | `mockups/screenshots/10-B-filter-type.png` |
| Approach C close-up (recommended) | Done | `mockups/screenshots/10-C-grid-recommended.png` |
| Recommended component states | Done | `mockups/screenshots/20-states-recommended.png` |
| Interactive HTML mockup | Done | `mockups/new-task-folder-picker.html` |
| States HTML mockup | Done | `mockups/new-task-folder-picker-states.html` |

## AppKit Translation Table

The mockup is HTML; the app is custom-drawn AppKit in the Deep Slate idiom. Slot it into
the existing `promptForNewTask()` flow, which today returns `(title: String, dir: String)?`.

| Mockup element | AppKit / app target | Notes |
|----------------|---------------------|-------|
| The whole modal | **Replace `NSAlert` with a custom sheet** — an `NSPanel`/`NSWindow` run via `window.beginSheet(_:completionHandler:)`, or an `NSViewController` presented as a sheet. The stock alert can't host this layout in-idiom. | Keep the *signature* `promptForNewTask() -> (title, dir)?`; only the body changes (return via the sheet's completion). |
| Modal head + Flow-B tag | `NSStackView` of layer-backed labels; teal `flowdot` = a 9px `NSView` with `layer.cornerRadius=4.5`; `FLOW B · interactive` = a `ChipLabel` in `flowColor(.b)` tint | reuse `ChipLabel` (the label paints its own fill — required on this hand-painted UI). |
| Title field | the existing `NSTextField` (sunken: `bg-sunken` bg via layer, `cardStroke` border, teal focus ring) | `window.initialFirstResponder = titleField`, unchanged. |
| **Recents list (A)** | `NSStackView` (vertical) of custom row `NSView`s, OR an `NSTableView`/`NSCollectionView` with a custom cell | for ≤6 MRU entries a plain `NSStackView` of clickable rows is simplest and matches the board's hand-built style; go to `NSCollectionView` only if the MRU grows. |
| **Recents grid (C)** | `NSCollectionView` with a `flowLayout` (2 columns) **or** an `NSGridView` of tile `NSView`s | tiles are `SessionCard`-shaped: layer-backed `NSView`, teal ring on select. The dashed **Browse** tile is one more cell. |
| Folder tile/row content | reuse the `SessionCard` label idiom: `BoardTheme.shortPath(dir)` → leaf (`monoBold`/`title`), parent → `◇ <dir>` (`monoSmall`, `textFaint`), branch → `ChipLabel` in `flowColor(.a)` tint, last-used → `monoSmall` `textFaint` | **leaf+faint-path is literally `projectSubtitle()` split in two** — pull it into a shared helper so card and picker stay identical. |
| Folder glyph (colour-seeded `ac`/`sa`) | a 24–28px layer-backed `NSView`, `cornerRadius` 6–7, fill = a stable hash of the dir → one of the agent/flow accent colours; 2-letter leaf initials in mono | cheap + gives instant recognition; colour is decorative-but-stable, not state. |
| Selected tile/row | `layer.borderColor = flowColor(.b)`, `backgroundColor = cardFillRaised`, + a 3px teal rail subview (tile) or trailing ✓ label (row) | exact `SessionCard.configureLayer()` selected treatment. |
| **git branch chip** | read `<dir>/.git/HEAD` once when building the row (cheap, no `git` subprocess): if it starts `ref: refs/heads/<x>` show `⎇ <x>`; detached → short SHA; no `.git` → omit the chip | do it lazily/async if the MRU is large; never block the modal open on git. |
| last-used time | the MRU is already most-recent-first; store a parallel `[dir: Date]` (or a small Codable struct) in UserDefaults to render "2m ago" | tiny extension to `rememberProjectDir`; relative-format with `RelativeDateTimeFormatter`. |
| **Browse… tile / row + ⌘O** | `NSOpenPanel`: `canChooseDirectories = true`, `canChooseFiles = false`, `allowsMultipleSelection = false`, `directoryURL =` current selection's parent | on `.OK`, take `panel.url`, make it the selection, and `rememberProjectDir(url.path)`. |
| `recent \| browse` segmented (C) | a custom 2-button toggle (two `ChipLabel`-style buttons in an `NSStackView`), NOT `NSSegmentedControl` (stock control won't match the dark idiom) | `recent` button carries a small count badge. |
| Footer keyboard hints | `NSStackView` of `ChipLabel` kbd glyphs + faint labels | decorative discoverability; the real key handling is below. |
| Create / Cancel buttons | custom layer-backed buttons (the `.btn`/`.btn.primary` idiom): Create = teal fill `#2DD4BF` / `#06231F` text; Cancel = `surface` / `textDim` | **don't use a stock `NSButton` for the primary** — same lone-outlier render risk as the back-pill defect; build it the custom-drawn way like `SessionCard`. |
| Keyboard model | `keyDown` on the sheet's content view: ↑↓/←→ move selection index, ↩ = Create (if Create enabled), ⎋ = cancel, ⌘O = Browse | **test by dispatching a real `NSEvent` keyDown** (the interaction-AC binding rule), not by calling the handler. |
| Error (bad path) | validate the selected/typed dir with `FileManager.fileExists(atPath:isDirectory:)`; on fail set the control's red border + the `⊘ … is not a folder.` label and disable Create | Create's enabled state is bound to "selection is an existing directory". |
| Data source | **unchanged** — `recentProjectDirs()` (MRU + repo root) feeds the list; `rememberProjectDir(_:)` on create bumps the chosen dir | only add the optional `lastUsed` timestamps + lazy branch read. |

### Where it slots in `BoardShell.swift`
- `promptForNewTask()` (line ~289) keeps its return type; replace its `NSAlert` body with
  the custom sheet. `makeTaskAccessory(recentDirs:)` (line ~309) is retired in favour of a
  `NewTaskSheet` view controller that owns the title field + folder collection.
- `promptAndCreateSession()` (line ~279), `createSession(...)`, `recentProjectDirs()`,
  `rememberProjectDir(_:)` are all **unchanged** — this is a view swap, not a logic change.

## Review Checklist
- [x] All must-have requirements addressed (one-click recents, leaf+faint-path, native
      chooser present-not-dominating, keyboard-first, Deep Slate + Flow-B).
- [x] Aesthetic direction defined (`minimalist-functional`, reuse the card idiom).
- [x] All component states documented (default/hover/selected/disabled-n.a./error/empty).
- [x] Accessibility listed (contrast, non-colour-only state, keyboard, focus, reduced-motion, VO).
- [ ] Technical constraints verified with the implementer (custom sheet vs alert is the one
      decision to confirm — see Open Decisions).

## Related
- **User Stories:** US-003 (a card is a *task*, named + placed), US-001/US-002 (the live
  terminal that opens in the chosen dir).
- **Code touched:** `app/Sources/GhostlingApp/BoardShell.swift` (`promptForNewTask`,
  `makeTaskAccessory`), `BoardTheme.swift` (`shortPath`), `SessionCard.swift` (the shared
  leaf+faint-path / ChipLabel idiom).
- **Design Decisions:** DD-001 (the app owns the terminal that opens in this dir).

## Open Decisions
1. **Custom sheet vs `NSAlert`+accessory.** This redesign needs a custom sheet — an
   `NSAlert` accessory can host A's list at a push but not C's grid/segmented cleanly.
   Recommend the custom sheet; flagged because it's the one structural change from today's
   stdlib approach.
2. **Ship C or A first.** Recommend C; A is the documented low-risk fallback that still
   resolves the complaint. Either way, fold B's type-to-filter into the chosen one.
