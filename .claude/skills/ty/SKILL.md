---
name: ty Type Checking
description: |
  Guidance for running the ty type checker.
version: 0.1.0
---

# ty Type Checking

Use `ty` to catch type errors in Python code.

## Commands

- `ty check <path>` to type-check.
- Add `--strict` if strict mode is required.

## Guidance

- Focus on errors in changed files.
- Prefer precise type hints over broad `Any`.
