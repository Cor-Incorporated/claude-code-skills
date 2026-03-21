---
name: agent-orchestrator
description: "Plan and execute multi-agent team compositions for parallel implementation tasks. Provides team patterns, wave-based execution, cross-review protocols, and TeamCreate vs parallel Agent decision matrix. Use when: planning team composition for complex multi-file features, choosing orchestration strategy for 3+ parallel tasks, setting up wave-based execution with dependencies, coordinating cross-review between agents. Do NOT use for: single-agent tasks, basic parallel execution of 2 independent tasks (rules handle that), Codex CLI delegation, or sequential single-file changes."
allowed-tools: [Read, Bash, Grep, Glob, Agent]
---

# Agent Orchestrator

Plan and execute multi-agent teams. Core rules (team mandatory, compacting resilience, mutual review) are in `agents-and-parallel.md` (always loaded). This skill provides the HOW: patterns, decisions, workflows.

<important if="planning team composition for a multi-agent task">
## Step 1: Analyze Plan and Map Teams

```
Read plan (Plans.md or stated tasks)
  -> Identify independent groups (parallelize)
  -> Identify dependencies (sequence)
  -> Select team pattern from references/team-patterns.md
  -> Map task groups to agent roles
  -> Output Team Plan
```
</important>

<important if="choosing between TeamCreate and parallel Agent spawning">
## Step 2: Choose Creation Method

| Condition | TeamCreate | Parallel Agents |
|-----------|-----------|-----------------|
| 2+ waves with dependencies | Yes | No |
| Mutual review needed between workers | Yes | No |
| Independent one-shot tasks | No | Yes |
| Long-running (compacting risk) | Yes | Risky |
| 3+ agents needing coordination | Yes | Possible |

### TeamCreate Flow

```
TeamCreate(team_name, description)
  -> TaskCreate (all tasks with descriptions)
  -> Agent (spawn teammates with team_name)
  -> TaskUpdate (assign tasks)
  -> Monitor via messages + TaskList
```

### Parallel Agent Flow

```
Agent(task-A, run_in_background) +
Agent(task-B, run_in_background) +
Agent(task-C, run_in_background)
  [all in single message]
  -> Wait for completions
  -> Agent(code-reviewer, review all changes)
```
</important>

<important if="setting up wave-based execution or monitoring agent progress">
## Step 3: Execute and Monitor

Track status at milestones:

```
| Agent | Task | Status |
|-------|------|--------|
| name  | task | status |
```

### Wave Transitions

```
Wave N complete
  -> Reviewer(s) cross-review all Wave N changes
  -> Fix CRITICAL/HIGH issues
  -> Re-review if fixes applied
  -> Wave N+1 begins
```
</important>

<important if="coordinating cross-review between agents after a wave completes">
## Step 4: Cross-Review Protocol

| Scenario | Reviewer |
|----------|---------|
| Agent A implements X | Agent B or dedicated reviewer |
| Agent B implements Y | Agent A or dedicated reviewer |
| Single implementer | Dedicated code-reviewer required |

Review checklist:
- Code quality (naming, structure, readability)
- No mutations (immutable patterns)
- Error handling present
- No security vulnerabilities (OWASP top 10)
- Consistent with existing codebase patterns
- Tests cover the implementation

Escalation: CRITICAL issues -> fix -> re-review -> CRITICAL = 0 to proceed.
</important>

<important if="handling agent failures, compacting, or wave execution problems">
## Error Handling

| Situation | Action |
|-----------|--------|
| Agent hangs / no response | Check TaskList; re-spawn if stuck |
| Compacting mid-wave | Save state to TaskList; resume from checkpoint |
| Cross-review finds CRITICAL | Block wave transition; fix first |
| Agent produces conflicting changes | Resolve via dedicated mediator agent |
| Wave dependency broken | Roll back wave; re-execute with corrected inputs |
</important>

<important if="selecting a team pattern for a new multi-agent task">
## Team Patterns

See `references/team-patterns.md` for full details:

1. **Feature Implementation** -- Wave-based multi-component features
2. **Bug Fix + Audit** -- Fix + codebase-wide pattern search
3. **Refactoring** -- Large-scale file modifications
4. **Research + Implement** -- Explore then build
5. **Lightweight Parallel** -- Independent small tasks with haiku agents
</important>
