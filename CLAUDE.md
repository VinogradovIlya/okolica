# Okolica — instructions for Claude Code

This project follows **Spec-Driven Development**. Do not write code without
consulting the spec documents in `.specify/`.

## Required reading before any task

1. `.specify/memory/constitution.md` — non-negotiable principles
2. `.specify/specs/001-mesh-chat-mvp/spec.md` — what we're building
3. `.specify/specs/001-mesh-chat-mvp/plan.md` — technical decisions
4. `.specify/specs/001-mesh-chat-mvp/tasks.md` — ordered tasks

## Workflow

- Work on **one task at a time** from `tasks.md`. Do not combine tasks.
- For each task: read its FR/A/D references, write tests first when applicable,
  implement, run `make lint && make test`, then stop and wait for review.
- If you find a contradiction between spec and what seems sensible — **stop
  and ask**. Do not silently deviate. Spec is source of truth.
- Commit messages in English. Format: `T-00X: <short description>`.

## Conventions

- All commands via `uv run <cmd>`. Never bare `python`.
- Line length 120 (black, pylint).
- No emoji in code or commits.
