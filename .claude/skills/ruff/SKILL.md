---
name: Ruff Linting
description: |
  Guidance for running Ruff and interpreting lint results.
version: 0.1.0
---

# Ruff Linting

Use Ruff to identify lint issues in Python files.

## Commands

- `ruff check <path>` to lint.
- `ruff check --fix <path>` for safe auto-fixes when allowed.

## Guidance

- Focus on issues introduced by changed files.
- Ignore pre-existing issues outside the change scope.
- Prefer fixes that align with project style and conventions.
