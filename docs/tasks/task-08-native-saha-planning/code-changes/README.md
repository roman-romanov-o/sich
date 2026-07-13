# Code Changes

Interface definitions and API specifications.

## Contents

| Name | Type | Status |
|------|------|--------|
| plan-status-json-cli | CLI contract | Draft |
| planning-state-reader | Internal Swift interface | Draft |
| task-folder-binding | Internal Swift interface | Draft |
| markdown-doc-renderer | Internal Swift interface | Draft |

## Interface Map

### External CLI contract
- [plan-status-json-cli.md](plan-status-json-cli.md) — `saha plan-status --json` (sahaidachny repo)

### Internal Swift interfaces
- [planning-state-reader.md](planning-state-reader.md) — `PlanningStateReader`, `PlanningState`, step→command table
- [task-folder-binding.md](task-folder-binding.md) — `BoardCard.taskFolder`, `TaskFolderIndex`, `init_task.sh` invocation
- [markdown-doc-renderer.md](markdown-doc-renderer.md) — `MarkdownDocRenderer`, mermaid rendering seam
