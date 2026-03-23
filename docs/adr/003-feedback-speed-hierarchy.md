# ADR-003: Feedback Speed Hierarchy

## Status
Accepted

## Date
2026-03-23

## Context

Quality checks concentrate on slow layers (CI, human review).
The fastest layer (PostToolUse) has no linting.

[Best Practices](https://nyosegawa.com/posts/harness-engineering-best-practices-2026/):
> "Move as many checks as possible to faster layers."

## Decision

### Layer Responsibilities

```
PostToolUse (ms) — "Fix the moment it's written"
├─ Auto-format (biome/ruff/gofumpt)
├─ Fast linting (oxlint/ruff/golangci-lint)
├─ Notify agent via additionalContext
└─ Scope: changed file only

PreToolUse (ms) — "Block before it happens"
├─ Linter config protection (block config edits)
├─ Safety gates (block destructive commands)
└─ Scope: all tool executions

Stop (s) — "Test before declaring done"
├─ Run change-related tests (detected via git diff)
├─ On failure: notify via additionalContext
└─ Timeout: 60 seconds

Pre-commit (s) — "Gate before commit"
├─ Type check (tsc/mypy/go vet)
├─ Full linter rules
└─ Scope: all staged files

CI (min) — "Gate at PR"
├─ Full test suite + E2E
├─ Security scan
└─ Scope: entire PR diff

Review (h) — "Judgment calls"
├─ Architecture fitness
├─ Business logic correctness
└─ Scope: human/Codex CLI judgment
```

### Linter Config Protection (PreToolUse)

Protected files: `.eslintrc*`, `eslint.config.*`, `biome.json*`,
`pyproject.toml`, `tsconfig.json`, `tsconfig.*.json`, `.golangci.*`,
`Cargo.toml`, `.prettierrc*`, `prettier.config.*`, `.editorconfig`,
`lefthook.yml`, `.pre-commit-config*`, `.ruff.toml`, `ruff.toml`

pyproject.toml: protect entirely (simple approach).

### Stop Hook Test Scope

Run only change-related tests (detected via git diff).
Not full test suite (too slow for Stop hook).

## Alternatives

| Option | Rejection Reason |
|--------|-----------------|
| All checks in CI | Feedback too slow (minutes) |
| Tests in PostToolUse | Tests take seconds; violates ms requirement |
| Full test suite in Stop | Can take minutes; change-related only |

## Consequences

- Linting moves to fastest layer: **ms-level quality feedback**
- Stop hook completion gate: **prevents untested "done" claims**
- Linter config protection: **deterministically blocks config weakening**
