# ADR-001: PostToolUse Quality Loop

## Status
Accepted

## Date
2026-03-23

## Context

PostToolUse hooks currently focus on state management (review recording, factcheck,
team tracking). No linting/formatting runs after file edits.

[Best Practices](https://nyosegawa.com/posts/harness-engineering-best-practices-2026/):
> "After session 47's long debug chain, the agent writes a file and moves on.
> The linter is forgotten." — Hooks must automate this.

## Decision

### Quality Loop Architecture

On Write/Edit trigger, PostToolUse Hook (`post-lint-format.sh`) executes:

1. **Auto-fix phase** (silent): formatter → linter --fix
2. **Residual check**: re-run linter (no --fix)
3. **additionalContext return**: remaining violations as JSON → agent self-corrects

### Languages and Tools

| Language | Extensions | Linter | Formatter |
|----------|-----------|--------|-----------|
| TypeScript/JS | `.ts, .tsx, .js, .jsx` | oxlint | biome format |
| Python | `.py` | ruff check | ruff format |
| Go | `.go` | golangci-lint | gofumpt |
| JSON/CSS | `.json, .css` | biome check | biome format |

### Performance Requirements

- Timeout: **2 seconds**
- Missing tools: **silent skip** (exit 0)
- Output limit: **head -20**
- Excluded: `node_modules/`, `dist/`, `build/`, `.next/`, `vendor/`, `.claude/`

### Feedback Format

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "oxlint: src/index.ts:15 - no-explicit-any: ..."
  }
}
```

## Alternatives

| Option | Rejection Reason |
|--------|-----------------|
| Pre-commit only | Too slow (seconds vs milliseconds) |
| ESLint | Too slow for PostToolUse. oxlint/biome are 50-100x faster |
| Lint all files | Performance. Only lint the changed file |
| No additionalContext | Agent cannot reliably read stdout. JSON required |

## Consequences

- Feedback speed: **milliseconds** (fastest layer)
- Auto-fix rate: **40-50% of violations resolved automatically**
- Remaining violations: agent self-corrects via additionalContext
