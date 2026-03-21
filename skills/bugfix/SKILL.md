---
name: bugfix
description: "Investigate, fix, and regression-proof bugs across the codebase. Invoke with: /bugfix [bug description]. Performs root cause analysis with full codebase grep, applies fixes to ALL instances (not just the first match), adds regression tests, and generates a structured report. Uses web search for unknown error patterns and library-specific issues. Use when: user reports a bug, error log needs investigation, fixing a GitHub Issue labeled 'bug'. Do NOT use for: new feature implementation, refactoring without a bug, performance optimization, or UI styling changes."
user-invocable: true
argument-hint: "[bug description]"
allowed-tools: [Read, Edit, Write, Bash, Grep, Glob, WebSearch, AskUserQuestion]
---

# Bugfix Specialist

Fix bugs with full codebase coverage: investigate -> root cause -> fix ALL instances -> verify -> test -> report.

## Workflow

<important if="investigating a bug report or diagnosing an error from logs">

### Phase 1: Investigation

1. Parse the bug description from `$ARGUMENTS`.
2. Search related code and logs with Grep/Read.
3. Web search for the error message: `"exact error message" framework_name`.
4. Web search for library bugs: `"package@version known issues"`.

</important>

<important if="performing root cause analysis or grepping for all instances of a bug pattern">

### Phase 2: Root Cause Analysis

1. Grep the entire codebase for the causal pattern.
2. List ALL instances (file:line).
3. Confirm root cause with code evidence.

</important>

<important if="applying bug fixes across the codebase">

### Phase 3: Fix

1. Apply the fix to EVERY instance found in Phase 2.
2. Keep changes minimal -- no over-engineering.
3. Follow immutable patterns: `return { ...obj, field }`.

</important>

<important if="verifying a bugfix or generating regression tests">

### Phase 4: Verification

1. Re-grep the pattern -- confirm zero remaining instances.
2. Run lint and type-check -- zero errors.
3. Add a regression test that fails WITHOUT the fix.
4. Run tests -- all pass.

</important>

### Phase 5: Report

Generate the report below and present to user.

<important if="writing a bugfix report or documenting a completed fix">

## Report Format

```markdown
# Bugfix Report: [Title]

## Bug
- **Symptom**: [What happens]
- **Impact**: [Scope of affected users/features]

## Root Cause
- **Cause**: [Technical explanation]
- **Location**: [file:line]
- **All instances**: [grep results]
- **External research**: [Web search findings, if any]

## Changes
| File | Change | Lines |
|------|--------|-------|
| path/to/file | description | +/-N |

## Verification
- [ ] Grep: zero remaining instances
- [ ] Lint: zero errors
- [ ] Types: zero errors
- [ ] Regression test added
- [ ] All tests pass

## Regression Prevention
- Test: [description of added test]
```

</important>

## Error Handling

| Situation | Action |
|-----------|--------|
| Cannot reproduce | Ask user for exact steps, env, and logs |
| Root cause unclear after grep | Widen search to dependencies and config files |
| Web search returns no results | Try alternative error message fragments |
| Fix breaks other tests | Revert, re-analyze, apply narrower fix |
| Multiple root causes found | Fix each separately, report all |

<important if="linking a bugfix to a GitHub Issue or creating a new bug issue">

## GitHub Issue Integration

```bash
gh issue list --state open --label bug
gh issue create --title "fix: [title]" --label bug --body "[details]"  # if none exists
git commit -m "fix: [description] #ISSUE_NUMBER"
```

</important>

## Prohibited

- Fixing only the first match without grepping for all instances.
- Skipping web search and assuming "not a known issue".
- Completing without adding a regression test.
- Completing without a GitHub Issue reference.
- Guessing "no other instances exist" without grep proof.
