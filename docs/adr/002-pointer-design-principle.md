# ADR-002: CLAUDE.md/rules Pointer Design Principle

## Status
Accepted

## Date
2026-03-23

## Context

Current rules/ totals 476 lines (delegation.md alone: 327 lines).
IFScale research shows primacy bias becomes significant at 150-200 instructions.

Claude Code system prompt (~50 instructions) + rules 476 lines + MEMORY.md + hooks =
400+ instructions total. High primacy bias risk.

[Best Practices](https://nyosegawa.com/posts/harness-engineering-best-practices-2026/):
> "The shorter the better. Ideal is under 50 lines."
> "Ask of each line: if I delete this, will the agent make mistakes? If No, delete."

## Decision

### What to write in Rules

- **Routing instructions**: commands, ADR locations, verification methods
- **Prohibitions**: each pointing to an ADR or hook
- **Numeric definitions**: parallelism limits, coverage thresholds

### What NOT to write in Rules

- **Content enforced by hooks** — the hook is the source of truth
- **Detailed decision tables/flowcharts** — move to ADR
- **Examples/templates** — move to docs/templates/
- **Command examples** — move to scripts/README.md

### Judgment Criteria

"If I delete this line, will the agent make mistakes?"
- **Yes** → keep (as a pointer)
- **No, a hook enforces it** → delete
- **No, an ADR covers it** → delete (keep ADR pointer only)

### Compression Targets

| File | Current | Target | Reduction |
|------|---------|--------|-----------|
| delegation.md | 327 | 50 | -85% |
| quality.md | 58 | 40 | -31% |
| git-workflow.md | 49 | 40 | -18% |
| testing.md | 23 | 20 | -13% |
| coding-style.md | 19 | 15 | -21% |
| **Total** | **476** | **165** | **-65%** |

### Relocation Targets

- Decision flows/tables → `docs/adr/`
- Templates → `docs/templates/`
- Command examples → `scripts/README.md`
- Background explanations → ADR "Context" sections

## Alternatives

| Option | Rejection Reason |
|--------|-----------------|
| Keep rules as-is | IFScale primacy bias risk |
| Abolish rules entirely | Hook error messages lack context |
| Move to skills | Rules' always-loaded is more reliable |

## Consequences

- Instruction count: 400+ → **~200** (50% reduction)
- Primacy bias risk: **significantly reduced**
- Duplicate descriptions of hook-enforced content: **eliminated**
