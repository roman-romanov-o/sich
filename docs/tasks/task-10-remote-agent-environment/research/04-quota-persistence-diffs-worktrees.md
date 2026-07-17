# Research: Quota, Persistence/Identity, Diffs, and Git Tooling for Remote Cards

**Date:** 2026-07-16
**Status:** Complete

## Summary

Three of the four subsystems are less broken than feared and one is worse.
**Quota is mostly a non-problem** (Claude's interactive quota is account-level and
read from a server endpoint, so remote consumption already shows up locally).
**Diffs are genuinely remote-ready** in shape. **Worktrees are hard-local** and
should be cut from scope. **Persistence/restore is actively broken for remote
cards** — a remote card silently comes back as a bogus local shell.

---

## 1. Quota for remote sessions

### Key Findings

1. **The measured interactive reading is a SERVER-side, ACCOUNT-level number**
   - Evidence: `app/Sources/GhostlingCore/UsageEndpointReader.swift:16` —
     `GET https://api.anthropic.com/api/oauth/usage`, decoding `five_hour` /
     `seven_day` utilization (`:33-48`).
   - Implication: **if the remote box logs into the same Claude account, the local
     gauge is already correct for the whole account, including remote usage.**
     Anthropic counts it server-side; we just read the total. This is the single
     most reassuring finding in this document, and it means **quota is largely NOT
     part of this task.** Do not build remote quota plumbing.

2. **The `/usage` PTY probe is local, and does not need to be remote**
   - Evidence: `app/Sources/GhostlingCore/ClaudeUsageProbe.swift:86` spawns
     `["/bin/zsh", "-lc", "cd <local ~/.ghostling/usage-probe> && exec claude"]`.
   - It's a *local* claude reading its *own* keychain to display an *account-level*
     number (`:8-12` explains the keychain-ACL reason for the screen-scrape).
   - Implication: this local probe reports the same account total regardless of
     where the work happened. Running a second probe on the remote box would return
     the same number — **redundant**.
   - ⚠️ Caveat: **only true if it's the same Anthropic account.** If the remote box
     is logged into a *different* account/org, the local gauge is silently wrong
     about the remote card's pool. Cannot verify which the user has — **must ask.**

3. **Codex quota IS local-file-based and would be blind to a remote Codex**
   - Evidence: `app/Sources/GhostlingCore/CodexUsageReader.swift:21-24` reads
     `~/.codex/sessions` from `homeDirectoryForCurrentUser`.
   - `QuotaUsageReader.defaultProjectsDir` (`:108-111`) likewise reads
     `~/.claude/projects` locally — but that's only the *fallback estimate*, which
     the measured endpoint supersedes.
   - Implication: a remote **Codex** card's usage is invisible. Given the endpoint
     covers Claude (the primary harness), this is an acceptable, honest gap —
     provided it degrades to "unknown", not a fake zero. The codebase's stated
     discipline (`UsageEndpointReader.swift:12-14`, "honest degradation, never a
     fake zero") supports this.

### Recommendation
**Cut quota from this task.** State the same-account assumption explicitly as a
constraint. Only revisit if the user confirms a different account on the remote box.

---

## 2. Board persistence & card identity for remote cards

### Key Findings — this is broken today

1. **A remote card persists a fake cwd**
   - Evidence: `BoardShell.swift:1025-1026` → `launch(seed)` → `:544-549`
     `registry.launch(projectDir: seed.projectDir)`; for remote, `seed.projectDir`
     is `spec.target` = `"roman@host"` (`BoardSeed.swift:117`).
   - `SessionRegistry.snapshotWindows` (`SessionRegistry.swift:89-102`) persists
     `cwd: session.projectDir` → `"roman@host"` lands in `PaneSnapshot.cwd`.

2. **On restart, that card comes back as a bogus LOCAL shell at `$HOME`**
   - Evidence: `SessionRestorer.resolveCwd` (`SessionRegistry.swift:275-277`) —
     `directoryExists(cwd) ? (cwd, false) : (homeDirectory, true)`. `"roman@host"`
     is not a directory → falls back to `$HOME`.
   - `reopenShell` (`:250-256`) then builds `shellCommand(shell:cwd:cardID:)` — a
     **local `$SHELL -il`** — and `BoardShell.openRestoredCard` (`:391-420`) drops
     a card with `projectDir: pane.cwd`.
   - **Result: the remote tmux card silently becomes a local shell sitting in your
     home directory, still wearing its `roman@host · agent` title.** The user
     reconnects to nothing. Worse, if `claudeSessionID` were set it would try to
     `claude --resume` *locally* (`:401-404`).
   - Confidence: **high** from code reading; **not empirically verified** (no test
     covers restore of a remote card — `RemoteTmuxCardTests.swift` has 2 tests,
     neither touches persistence). Worth a red test to prove it before fixing.

3. **The irony: tmux makes reconnect trivial, and we throw it away**
   - `tmux new-session -A` (`RemoteTmuxCommand.swift:124`) is *designed* for exactly
     this: re-running the identical argv reattaches the still-running remote session.
     The docstring at `:74-77` says so.
   - Implication: correct restore for a remote card is **"persist the spec, re-run
     the same ssh argv"** — genuinely simpler than the local case, which needs cwd
     resolution and `--resume` gymnastics. The blocker is only that `PaneSnapshot`
     has nowhere to put a host/spec, and `SessionRestorer` is hard-wired to build a
     local `$SHELL` command (`:251-255`).

4. **`SessionSnapshot` versioning gives us a clean path**
   - Evidence: `SessionSnapshot.currentVersion = 1` (`SessionSnapshot.swift:13`);
     a version mismatch is ignored, not crashed on (`:11-13`). Optional new fields
     decode to nil without a bump — the precedent is documented at `:49-52` and
     `:56-58` (`claudeSessionID`, `title`).
   - Implication: adding an optional `remote: RemoteTmuxSpec?` to `PaneSnapshot`
     follows an established, blessed pattern. Low risk.

5. **Identity binding (`GHOSTLING_CARD_ID`) does not reach the remote session**
   - Evidence: `BoardSeed.liveTerminal:89` injects `GHOSTLING_CARD_ID=...` into the
     local shell command. `BoardSeed.remoteTmux:106-121` **does not** — the argv is
     just ssh+tmux.
   - Even if injected: `ssh` doesn't forward env without `SendEnv`/`AcceptEnv`, and
     **`tmux new-session -A` on *attach* inherits the original session's env, not
     the new client's** — so an env var is the wrong mechanism by construction.
   - Implication: the card↔hook binding (`HookInstaller.swift:135-139` stamps
     `ghostling_card_id`) cannot work remotely as designed. Needs a design decision:
     bind by `(host, remote-cwd)`, or by tmux session name, or pass the id at
     session-*create* time via `tmux new-session -e` (tmux ≥3.2; **create-only**).
   - **Flag for `/saha:decide`.** This is a genuine architectural fork, not a tweak.

---

## 3. Diffs for a remote repo

### Key Findings

1. **The app never runs git to produce a diff — confirmed**
   - Evidence: `grep -rn "/usr/bin/git" app/Sources` → **only**
     `WorktreeProvisioner.swift:38`. `DiffModel.swift:143-155` decodes
     `diff_base64` / `session_diff_base64` / `cwd_base64` straight from the event line.
   - The diff is computed **where the repo lives**, by the hook
     (`HookInstaller.swift:167-214`, `git -C "$cwd" diff --no-ext-diff --binary`).
   - Implication: **the task-05 "diff as data" design genuinely pays off here.**
     Remote diffs need no new diff code — only transport (doc 02).

2. **…but the diff-producing half of the hook is macOS-only**
   - The whole diff block is gated at `HookInstaller.swift:145` on `$session` and
     `$cwd`, both extracted via `/usr/bin/plutil` (`:142-144`) — **absent on Linux**.
   - Implication: on a Linux remote, state events would flow but **diffs would
     silently be absent**. Fix the extractor (doc 02, risk 1).

3. **A caveat nobody has flagged: `cwd` collision**
   - `TurnDiff.cwd` (`DiffModel.swift:151`) is a bare path string. A remote
     `/home/roman/proj` and a local `/home/roman/proj` are indistinguishable.
     Unlikely on macOS-local (`/Users/...`) but real if the remote is macOS too.
   - Mitigation: namespace by host at ingest (same fix as doc 02, risk 4).

---

## 4. Git worktree tooling for a remote repo

### Key Findings

1. **`GitWorktree` is hard-local: pure `FileManager` + local path math**
   - Evidence: `app/Sources/GhostlingApp/GitWorktree.swift:14-16`
     (`FileManager.default.fileExists`), `:19` (`String(contentsOfFile:)`), `:36`,
     `:57` — every resolution reads local files.

2. **`GitWorktreeProvisioner` shells out to the LOCAL git binary**
   - Evidence: `WorktreeProvisioner.swift:38` `URL(fileURLWithPath: "/usr/bin/git")`;
     worktrees land under a local `~/.ghostling/worktrees/<repo>/<slug>` (`:33-35`).

3. **Remote cards already skip worktrees — by design**
   - Evidence: `BoardShell.swift:1017-1019` — `createRemoteTmuxSession` "skips the
     local-only steps (worktree, cwd reporting, auto-`claude`)".

### Recommendation
**Cut remote worktrees from this task.** Making them work means an `ssh git worktree add`
provisioner + remote path math — a whole second task, and the user didn't ask for it.
The existing skip is honest. Just make sure the create palette **disables** the
"Own git worktree" toggle (`CreateCardPalette.swift:356`) for a remote target rather
than showing an on-switch that silently does nothing.

---

## Validated Assumptions (consolidated)

| Assumption | Status | Evidence |
|---|---|---|
| Quota is read from local keychain + hidden-PTY probe | ✅ Confirmed | `ClaudeUsageProbe.swift:86`, `UsageEndpointReader.swift:16` |
| …therefore remote quota is unmeasured | ❌ **Incorrect** | The endpoint is account-level & server-side (`UsageEndpointReader.swift:16-48`) — remote usage on the same account already shows |
| Card↔session join is by pty identity, not sessionID | ✅ Confirmed | `BoardShell.swift:353-363` |
| Remote cards survive restart / reconnect to running tmux | ❌ **Incorrect — actively broken** | `SessionRegistry.swift:275-277` + `BoardSeed.swift:117` → restores a local `$SHELL` at `$HOME` |
| Diffs are git-sourced, shipped as data, remote-free | ✅ Shape confirmed / ❌ transport & Linux | `DiffModel.swift:143`; no git in app (`grep`); `plutil` at `HookInstaller.swift:142` |
| Worktree/diff code assumes local paths | ✅ Confirmed (worktree) / ❌ (diff — it's data) | `GitWorktree.swift:14`, `WorktreeProvisioner.swift:38` |
