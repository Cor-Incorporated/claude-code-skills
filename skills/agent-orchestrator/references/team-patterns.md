# Team Composition Patterns

## Pattern 1: Feature Implementation (Wave-based)

Suitable for multi-component features with a plan/wave structure.

### Roles
| Role | Agent Type | Model | Responsibility |
|------|-----------|-------|----------------|
| leader | (main session) | - | Orchestrate, assign, review |
| implementer-A | general-purpose | sonnet | Component A implementation |
| implementer-B | general-purpose | sonnet | Component B implementation |
| reviewer | code-reviewer | opus | Cross-review all implementations |
| tester | tdd-guide | opus | Write/run tests for completed work |

### Task Flow
```
Plan Wave N
  ├── Task A (implementer-A) ─┐
  ├── Task B (implementer-B) ─┤── All complete → reviewer cross-reviews
  └── Task C (implementer-A) ─┘         ↓
                                    tester writes tests
                                         ↓
                                    Next wave
```

## Pattern 2: Bug Fix + Full Audit

Suitable for bug fixes requiring codebase-wide pattern search.

### Roles
| Role | Agent Type | Model | Responsibility |
|------|-----------|-------|----------------|
| leader | (main session) | - | Orchestrate |
| fixer | general-purpose | sonnet | Fix the reported bug |
| auditor | Explore | default | grep entire codebase for same pattern |
| reviewer | code-reviewer | opus | Review fix + audit completeness |

### Task Flow
```
Bug Report
  ├── fixer: Fix primary instance
  └── auditor: grep all instances of same pattern
        ↓
  reviewer: Verify all instances fixed, no regressions
```

## Pattern 3: Refactoring / Migration

Suitable for large-scale code changes across many files.

### Roles
| Role | Agent Type | Model | Responsibility |
|------|-----------|-------|----------------|
| leader | (main session) | - | Orchestrate, assign files |
| worker-1..N | general-purpose | sonnet | Modify assigned files |
| reviewer | code-reviewer | opus | Review each worker's changes |
| build-checker | build-error-resolver | opus | Fix any build errors |

### Task Flow
```
File list from plan
  ├── worker-1: files [A, B, C]  ─┐
  ├── worker-2: files [D, E, F]  ─┤── reviewer cross-reviews
  └── worker-3: files [G, H, I]  ─┘         ↓
                                    build-checker: verify build
```

## Pattern 4: Research + Implement

Suitable for tasks requiring exploration before implementation.

### Roles
| Role | Agent Type | Model | Responsibility |
|------|-----------|-------|----------------|
| leader | (main session) | - | Orchestrate |
| researcher-1 | Explore | default | Investigate area A |
| researcher-2 | Explore | default | Investigate area B |
| implementer | general-purpose | sonnet | Implement based on findings |
| reviewer | code-reviewer | opus | Review implementation |

### Task Flow
```
Research Phase (parallel)
  ├── researcher-1: area A  ─┐
  └── researcher-2: area B  ─┘── findings consolidated
                                    ↓
Implementation Phase
  └── implementer: build based on findings
                                    ↓
  └── reviewer: review
```

## Pattern 5: Lightweight Parallel Tasks

Suitable for independent, small tasks (lint fixes, import cleanup, etc.).

### Roles
Use `general-purpose` agents with `model: haiku` for each independent task.
No formal team needed — use parallel Agent tool calls directly.

### When to Use
- 3+ independent lint/type fixes across different files
- Import cleanup across modules
- Renaming across files (when not using LSP rename)

## Anti-Pattern: Sequential Single Agent

```
❌ Main session does Task A → Task B → Task C sequentially
❌ Main session spawns one agent at a time, waits, spawns next
❌ Plan says "parallel" but execution is sequential
```

## Choosing the Right Pattern

```
Is the task trivial (< 3 steps, 1-2 files)?
  YES → Do it directly, no team needed
  NO ↓

Does the task have a plan with waves/phases?
  YES → Pattern 1 (Feature Implementation)
  NO ↓

Is it a bug fix?
  YES → Pattern 2 (Bug Fix + Audit)
  NO ↓

Is it a large-scale refactoring across many files?
  YES → Pattern 3 (Refactoring)
  NO ↓

Does it need research before implementation?
  YES → Pattern 4 (Research + Implement)
  NO ↓

Are there 3+ independent small tasks?
  YES → Pattern 5 (Lightweight Parallel)
  NO → Do it directly
```
