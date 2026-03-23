# ADR-004: Codex Large-Scale Delegation Model

## Status
Accepted

## Date
2026-03-23

## Context

### Platform Architecture Difference

- **Codex** ("box model"): Works in isolated sandbox. Returns diffs. Internal sub-agents (max_threads=6) can autonomously split tasks.
- **Claude Code** ("workshop model"): Works in local environment. PostToolUse/PreToolUse hooks enforce quality deterministically.

### Codex Quality Loop Gap

Codex has no PostToolUse/PreToolUse hooks (as of March 2026).
ADR-001's Quality Loop does not run inside Codex.

## Decision

### 3-Phase Model

```
Claude Code (plan & design)
  ├─ Requirements summary (no split instructions)
  └─ Send as ONE large request to Codex
        ↓
Codex (large-scale implementation)
  ├─ Autonomously splits tasks
  ├─ Internal sub-agent parallel execution
  └─ Integrates and returns diff
        ↓
Claude Code (quality gate) ← MANDATORY
  ├─ PostToolUse Quality Loop (lint the diff)
  ├─ code-reviewer + Codex CLI review
  ├─ Run change-related tests
  └─ Quality OK → create PR
```

### Redefinition of "1 Task Limit"

- **Old**: Only small single tasks. Large work uses Agent Team.
- **New**: Send as "one request" regardless of size. Internal splitting is Codex's autonomous decision. Max 1 concurrent Codex request from Claude Code.

### Codex Prompt Design

Include: goal, constraints, test requirements, coding standards, scope, prohibitions
Exclude: specific split instructions (let Codex decide)

### Agent Team vs Codex

| Condition | Owner | Reason |
|-----------|-------|--------|
| Real-time interaction needed | Claude Code | Codex is async |
| Interdependent implementation | Agent Team | Needs immediate cross-reference |
| Large-scale, autonomous | **Codex (1 request)** | Internal splitting efficient |
| 2+ independent but small | Agent Team | Not worth Codex startup |
| Quality-critical path | Claude Code + Agent Team | Quality Loop runs real-time |

## Alternatives

| Option | Rejection Reason |
|--------|-----------------|
| CC splits then sends multiple to Codex | Wastes CC context window |
| Agent Team only, no Codex | CC context exhaustion on large tasks |
| No Quality Loop post-processing | Codex has no hooks; quality unverified |

## Consequences

- CC context consumption: **greatly reduced** (prompt only)
- Codex capability utilization: **internal sub-agents maximized**
- Quality assurance: **compensated by post-receive Quality Loop**
