# TASK-05: Per-Turn Diff Review in Drill-In

**Status:** Planning
**Mode:** Full
**Created:** 2026-07-04

## Overview

Add a native-AppKit "Changes" tab to the drill-in that shows what the agent
changed **per turn** (git-sourced unified diffs, word-level highlighted via
stdlib `CollectionDifference`), working identically for local and remote
tmux/tailscale sessions because the diff travels as data over the existing hook
channel. No webview — preserves the Swift/libghostty stack and DD-001.

## Planning Progress

| Step | Status | Artifacts |
|------|--------|-----------|
| Research | Pending | research/*.md |
| Task Description | Draft | task-description.md |
| User Stories | Pending | user-stories/US-*.md |
| Design Decisions | Pending | design-decisions/DD-*.md |
| Code Changes | Pending | code-changes/*.md |
| Test Specs | Pending | test-specs/**/*.md |
| Implementation Plan | Pending | implementation-plan/phase-*.md |

## Next Steps

- [ ] Run `/saha:stories` to generate user stories from the task description
- [ ] Run `/saha:decide` to record DD-001 (git-checkpoint diff pipeline) and
      DD-002 (native NSTextView rendering, no webview)
- [ ] Run `/saha:plan` to phase the implementation
