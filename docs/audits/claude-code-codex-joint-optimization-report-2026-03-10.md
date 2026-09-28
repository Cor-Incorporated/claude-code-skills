# Claude Code + Codex Joint Optimization Report

Date: 2026-03-10

## Purpose

This report is for Claude Code to inspect the concrete changes made for collaboration hardening between Claude Code and Codex.

## Updated files

- `/Users/teradakousuke/.codex/skills/claude-code-delegation/SKILL.md`
- `/Users/teradakousuke/.codex/skills/claude-code-delegation/agents/openai.yaml`
- `/Users/teradakousuke/.codex/skills/codex-delivery-governance/SKILL.md`
- `/Users/teradakousuke/.codex/skills/codex-delivery-governance/references/delegation-matrix.md`
- `/Users/teradakousuke/.codex/skills/codex-delivery-governance/references/claude-code-alignment.md`
- `/Users/teradakousuke/.claude/scripts/codex-parallel.sh`
- `/Users/teradakousuke/.claude/scripts/codex-orchestrate.sh`
- `/Users/teradakousuke/Developer/codex-claude-collaboration-optimization-2026-03-10.md`

## What was optimized

### 1. Skill parity

- `claude-code-delegation` is now a valid Codex skill with frontmatter and explicit shared delivery gates.
- `codex-delivery-governance` now matches Claude Code route `A / B / C`.
- A new alignment reference explains when work must stay in Claude Code and when it should move to Codex.

### 2. Shared quality gates

Both sides now explicitly align on:

- `1 PR = 1 intent`
- branch prefix and PR type alignment
- `feat` requires tests
- follow-up fixes record origin PR or commit
- second consecutive follow-up fix triggers escalation / freeze
- Operationally Ready checks cover env vars, CORS, MIME, permissions, schedulers, migrations, Terraform, and Docker

### 3. Delegation boundary

Codex is now positioned for:

- bounded serial implementation
- operational or mechanical tasks
- GitHub and Supabase operations
- long-running independent work

Claude Code remains primary for:

- interactive planning
- architecture and security decisions
- shared-context agent-team implementation
- user-facing tradeoff loops

### 4. Automatic orchestration safety

`/Users/teradakousuke/.claude/scripts/codex-orchestrate.sh` now runs an independence preflight before launching parallel Codex tasks.

Each task must now declare:

```json
{
  "branch": "docs/api-update",
  "prompt": "Update API docs",
  "paths": ["docs/api", "docs/openapi.md"]
}
```

The preflight rejects:

- duplicate branches
- missing `paths`
- overlapping or nested path scopes
- high-risk shared paths such as workflows, Terraform, migrations, lockfiles, runtime manifests, or Docker entrypoints
- prompts that look like deploy, release, auth, payment, schema, Terraform, or migration work
- Japanese high-risk prompts such as `デプロイ`, `リリース`, `認証`, `決済`, and `マイグレーション`

### 5. Final alignment adjustments

- fixed the Japanese prompt-risk bug in `codex-orchestrate.sh` by switching from `\b`-based regex assumptions to direct high-risk term matching
- added a soak-time reference to `/Users/teradakousuke/.claude/rules/delegation.md`
- added explicit feature-freeze escalation parity to `/Users/teradakousuke/.codex/skills/codex-delivery-governance/references/claude-code-alignment.md`

## Validation performed

### Skill validation

- `python /Users/teradakousuke/.codex/skills/.system/skill-creator/scripts/quick_validate.py /Users/teradakousuke/.codex/skills/claude-code-delegation`
- `python /Users/teradakousuke/.codex/skills/.system/skill-creator/scripts/quick_validate.py /Users/teradakousuke/.codex/skills/codex-delivery-governance`

Result: both passed.

### Script validation

- `bash -n /Users/teradakousuke/.claude/scripts/codex-parallel.sh`
- `bash -n /Users/teradakousuke/.claude/scripts/codex-orchestrate.sh`

Result: both passed.

### Orchestrator behavior checks

1. Valid independent task batch:
   - preflight passed
   - downstream execution was attempted
2. Invalid overlapping high-risk batch:
   - preflight failed before task launch
   - workflow path overlap was detected correctly

## What Claude Code should verify

### File-level inspection

- confirm `codex-parallel.sh` now invokes both `$claude-code-delegation` and `$codex-delivery-governance`
- confirm `codex-orchestrate.sh` now requires `paths[]` and blocks unsafe parallel batches
- confirm the Codex skills still reflect Claude Code rules in:
  - `/Users/teradakousuke/.claude/rules/delegation.md`
  - `/Users/teradakousuke/.claude/rules/git-workflow.md`
  - `/Users/teradakousuke/.claude/rules/quality.md`

### Remaining gap

`codex-orchestrate.sh` now proves file-scope independence, but it still cannot fully prove semantic independence. Claude Code should still avoid parallel orchestration when tasks share one evolving design decision even if file paths differ.

## Overall status

- skill alignment: complete
- route alignment: complete
- quality-gate alignment: complete
- worktree orchestration safety: improved and now preflight-enforced
- semantic independence checking: partially manual by necessity
