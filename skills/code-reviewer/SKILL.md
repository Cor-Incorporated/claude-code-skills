---
name: code-reviewer
description: "Review code for quality, security, and best practices across TypeScript, JavaScript, Python, Go, Swift, and Kotlin. Analyzes PRs with automated scripts (pr_analyzer, code_quality_checker, review_report_generator), checks for OWASP vulnerabilities, validates naming/structure/error handling, and generates actionable review reports. Use when: reviewing a pull request, providing code feedback, checking code quality before merge, auditing security of changes. Do NOT use for: writing new code, fixing bugs (use /bugfix), generating tests, or architectural design (use /modern-architecture)."
allowed-tools: [Read, Bash, Grep, Glob, WebSearch]
---

# Code Reviewer

Review code for quality, security, and correctness. Generate actionable reports with severity-ranked findings.

<important if="reviewing a pull request or checking code quality before merge">
## Review Workflow

### 1. Analyze Changes

Identify the scope: PR diff, staged changes, or specified files.

```bash
# PR analysis
python ${CLAUDE_SKILL_DIR}/scripts/pr_analyzer.py <project-path> [options]

# Code quality scan
python ${CLAUDE_SKILL_DIR}/scripts/code_quality_checker.py <target-path> [--verbose]
```
</important>

<important if="reviewing code for correctness, security, or quality issues">
### 2. Check Against Standards

Review each changed file for:

**Correctness**
- Logic errors, off-by-one, null/undefined handling
- Race conditions in async code
- Edge cases not covered
</important>

<important if="auditing security of code changes or checking for OWASP vulnerabilities">
**Security (OWASP)**
- Input validation (Zod schemas for all user input)
- SQL injection (parameterized queries only)
- XSS prevention (no `dangerouslySetInnerHTML` without sanitization)
- Authentication/authorization checks on every route
- No hardcoded secrets, API keys, or tokens
</important>

<important if="checking code quality, structure, or naming conventions">
**Quality**
- Functions under 50 lines, files under 800 lines
- Nesting under 4 levels
- Immutable patterns (`return { ...obj, field }`, no mutations)
- Consistent naming with existing codebase
- No `console.log` in production code

**Testing**
- New code has corresponding tests
- Tests are falsifiable (see `/test-falsify`)
- Edge cases covered
</important>

<important if="generating a code review report or producing review output">
### 3. Generate Report

```bash
python ${CLAUDE_SKILL_DIR}/scripts/review_report_generator.py [arguments] [options]
```

### Report Format

```markdown
## Code Review: [PR/Change Title]

### Summary
[1-2 sentence overview of changes and overall assessment]

### Findings

#### CRITICAL (block merge)
| # | File | Line | Issue | Fix |
|---|------|------|-------|-----|

#### HIGH (fix before merge)
| # | File | Line | Issue | Fix |
|---|------|------|-------|-----|

#### MEDIUM (fix recommended)
| # | File | Line | Issue | Fix |
|---|------|------|-------|-----|

#### LOW (suggestion)
| # | File | Line | Issue | Fix |
|---|------|------|-------|-----|

### Verdict
- [ ] CRITICAL: 0
- [ ] HIGH: 0
- [ ] Approve / Request Changes
```
</important>

<important if="encountering issues running review scripts or handling large PRs">
## Error Handling

| Situation | Action |
|-----------|--------|
| Script fails to run | Fall back to manual review using Grep/Read |
| PR too large (100+ files) | Split review by directory; prioritize security-sensitive files |
| Cannot determine intent of change | Ask the author for context before reviewing |
| Conflicting patterns in codebase | Flag inconsistency; recommend which pattern to follow |
</important>

<important if="classifying review findings by severity or deciding merge readiness">
## Severity Definitions

| Level | Criteria | Action |
|-------|----------|--------|
| CRITICAL | Security vulnerability, data loss risk, production breakage | Block merge |
| HIGH | Bug, missing validation, missing error handling | Fix before merge |
| MEDIUM | Code smell, missing test, inconsistent pattern | Fix recommended |
| LOW | Style, naming, minor improvement | Optional |
</important>

## References

- `references/code_review_checklist.md` -- Detailed checklist by category
- `references/coding_standards.md` -- Language-specific standards
- `references/common_antipatterns.md` -- Anti-patterns with examples
- Global coding style: `~/.claude/rules/coding-style.md`
