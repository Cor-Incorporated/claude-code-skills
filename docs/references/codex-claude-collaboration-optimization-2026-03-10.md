# Codex + Claude Code Collaboration Optimization

Date: 2026-03-10

## What changed

- `claude-code-delegation` was converted into a valid Codex skill with frontmatter and shared delivery gates.
- `codex-delivery-governance` was aligned with Claude Code's route model and now explicitly supports route `A`, `B`, and `C`.
- A new alignment reference was added to explain the boundary between Claude Code agent-team work and Codex worktree execution.
- `~/.claude/scripts/codex-parallel.sh` now tells Codex to use both `$claude-code-delegation` and `$codex-delivery-governance`.

## New operating boundary

### Keep in Claude Code

- interactive planning and user tradeoff handling
- architecture and security decisions
- multi-agent work where subtasks need shared evolving context
- tightly coupled parallel implementation

### Send to Codex

- bounded serial implementation
- mechanical or operational tasks
- GitHub and Supabase operations
- test expansion, docs updates, review follow-up fixes, CI repairs
- long-running independent work that would otherwise consume Claude context

## Route guide

- Route `A`: Codex review or second opinion only
- Route `B`: user-mediated full handoff for large implementation
- Route `C`: bounded implementation through `codex exec` and worktree isolation

Use Route `C` only when the task is independent at both the file level and the decision level.

## Long-running serial threshold

Default to Codex when one or more are true:

- estimated uninterrupted work is over 45 minutes
- the task will likely need 2 or more full validation loops
- many files are changed through one repeated pattern
- the work is operational or mechanical rather than design-led

Return the task to Claude Code when it becomes design-heavy, ambiguous, or user-judgment heavy.

## Shared quality gates

- `1 PR = 1 intent`
- branch prefix, commit type, and PR type stay aligned
- `feat` requires tests or an explicit blocker note
- follow-up fixes must record the origin PR or commit
- second consecutive follow-up fix in one area triggers feature-freeze escalation
- Operationally Ready checks cover env vars, CORS, MIME, permissions, schedulers, migrations, Terraform, and Docker

## Recommended usage

### Review path

```bash
bash ~/.claude/scripts/codex-parallel.sh --review ~/Developer/<repo> --base develop
```

### Single delegated task

```bash
bash ~/.claude/scripts/codex-parallel.sh ~/Developer/<repo> fix/<name> "bounded task prompt"
```

### Multi-task orchestration

Use `codex-orchestrate.sh` only for tasks that do not depend on shared edits or rolling design choices.

## Orchestrator preflight

`codex-orchestrate.sh` now rejects unsafe parallel batches unless independence can be proven from the task file.

Each task should declare:

```json
{
  "branch": "docs/api-update",
  "prompt": "Update API docs",
  "paths": ["docs/api", "docs/openapi.md"]
}
```

The preflight blocks:

- duplicate branches
- missing `paths`
- overlapping or nested path scopes between tasks
- shared high-risk files such as workflows, Terraform, migrations, lockfiles, runtime manifests, or Docker entrypoints
- prompts that look like deploy, migration, release, auth, payment, or Terraform work

If the batch fails preflight, it should be split, serialized, or returned to Claude Code route `B`.
