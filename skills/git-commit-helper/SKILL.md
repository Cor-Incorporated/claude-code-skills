---
name: git-commit-helper
description: "Analyze git diff and generate descriptive conventional commit messages. Use when staging changes, writing commit messages, or reviewing staged changes before committing. Triggers: 'commit this', 'write commit message', 'what should the commit say', 'review staged changes', 'help me commit'. Do NOT use for git branching strategy, merge conflict resolution, or PR creation."
allowed-tools: [Read, Bash, Grep]
---

# Git Commit Helper

Analyze staged changes and generate conventional commit messages.

## Workflow

<important if="reviewing staged git changes before writing a commit message">
1. **Review staged changes:**
   ```bash
   git diff --staged --stat
   git diff --staged
   ```
</important>

<important if="classifying the commit type from staged diff content">
2. **Identify commit type** from changes:
   - `feat`: New feature
   - `fix`: Bug fix
   - `refactor`: Code restructuring (no behavior change)
   - `docs`: Documentation only
   - `test`: Adding/updating tests
   - `style`: Formatting (no logic change)
   - `chore`: Maintenance, dependencies
   - `perf`: Performance improvement
   - `ci`: CI/CD changes

3. **Determine scope** from affected area (e.g., `auth`, `api`, `ui`, `db`, `ci`).
</important>

<important if="composing the conventional commit message text">
4. **Generate message** following this format:
   ```
   <type>(<scope>): <summary under 50 chars>

   [Body: explain WHY, not WHAT]

   [Footer: breaking changes, issue refs]
   ```

## Rules

- Use imperative mood: "add feature" not "added feature".
- Keep summary under 50 characters.
- Capitalize first letter of summary.
- No period at end of summary.
- Body explains WHY the change was made.
- Mark breaking changes with `!` after scope and `BREAKING CHANGE:` in footer.
- One logical change per commit -- do not mix unrelated changes.
</important>

<important if="looking up commit message examples for reference">
## Examples

```
feat(auth): add JWT refresh token support

Implement automatic token refresh to prevent session
expiration during active use. Users were being logged
out mid-workflow.

Closes #142
```

```
fix(api): handle null values in user profile

Prevent crashes when optional profile fields are null.
Add null checks before accessing nested properties.
```

```
feat(api)!: restructure response format to JSON:API

BREAKING CHANGE: All API responses now use JSON:API spec.
Migration guide: docs/migration-v2.md
```
</important>

<important if="no changes are staged or staged changes span unrelated areas">
## Error Handling

- If no changes are staged, run `git status` and suggest which files to stage.
- If staged changes span unrelated areas, recommend splitting into separate commits.
- If commit type is ambiguous (e.g., feat + fix mixed), flag it and suggest separation.
</important>
