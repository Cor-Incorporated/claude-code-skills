---
name: changelog-generator
description: "Generates user-friendly changelogs from git commit history. Use when the user says: 'create changelog', 'generate release notes', 'write changelog', 'what changed since last release', 'summarize commits', 'prepare release notes', 'app store update description', 'product update summary'. Scans git history, categorizes changes, and converts technical commits into customer-readable language. Do NOT use for git operations themselves, code review, or generating internal technical documentation."
allowed-tools: [Read, Write, Bash, Grep, Glob]
---

# Changelog Generator

Transform git commits into polished, user-friendly changelogs.

## Workflow

<important if="determining commit range for changelog generation">
### 1. Determine Scope

Identify the commit range. Ask the user if unclear:

```bash
# Since last tag
git log $(git describe --tags --abbrev=0)..HEAD --oneline

# Date range
git log --after="2024-03-01" --before="2024-03-15" --oneline

# Between versions
git log v2.4.0..v2.5.0 --oneline
```
</important>

<important if="categorizing commits into changelog sections">
### 2. Categorize Commits

Group by type using commit prefixes and content analysis:

| Category | Commit types | Icon |
|----------|-------------|------|
| New Features | `feat:` | New |
| Improvements | `perf:`, `refactor:` (user-visible) | Improved |
| Bug Fixes | `fix:` | Fixed |
| Breaking Changes | `BREAKING CHANGE` in body | Breaking |
| Security | `fix:` with security context | Security |

### 3. Filter Out Internal Commits

Exclude from user-facing changelog:
- `test:`, `chore:`, `ci:`, `docs:` (internal)
- `refactor:` with no user-visible change
- Merge commits
- Version bump commits
</important>

<important if="rewriting technical commits into user-friendly changelog entries">
### 4. Rewrite in User Language

Transform technical commits into user-friendly descriptions:

- BAD: "fix: resolve race condition in WebSocket reconnect handler"
- GOOD: "Fixed an issue where real-time updates could stop working after a brief disconnection"

Rules:
- Write from the user's perspective, not the developer's
- Explain the benefit, not the implementation
- Use active voice ("Added", "Fixed", "Improved")
- Keep each entry to 1-2 sentences
</important>

<important if="formatting the final changelog markdown output">
### 5. Format Output

```markdown
# Updates - [Version or Date Range]

## New
- **[Feature Name]**: [User-friendly description]

## Improved
- **[Area]**: [What got better and why it matters]

## Fixed
- [What was broken, now works correctly]

## Breaking Changes
- **[What changed]**: [What users need to do]
```
</important>

<important if="saving changelog to file or presenting output">
### 6. Save or Present

- Append to `CHANGELOG.md` if it exists
- Output to console if no changelog file
- Respect `CHANGELOG_STYLE.md` if present in repo
</important>

<important if="handling errors during changelog generation">
## Error Handling

- If no commits found in range: verify date format and branch. Try `git log --all` to check
- If no tags exist: ask user for commit range or date range instead
- If commits lack conventional prefixes: categorize by analyzing diff content and commit message keywords
- If `CHANGELOG_STYLE.md` not found: use the default format above
</important>
