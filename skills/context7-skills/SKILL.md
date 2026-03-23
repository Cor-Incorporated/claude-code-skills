---
name: context7-skills
description: "Manage Context7 CLI skills: search, install, list, remove, info via ctx7. Use when the user wants to find, install, list, remove, or inspect Context7 skills. Triggers: 'search skills', 'install skill', 'list my skills', 'remove skill', 'ctx7', 'context7'. Do NOT use for general package management (npm, pip), non-Context7 CLI commands, or skill authoring."
allowed-tools: [Bash, WebFetch]
---

# Context7 Skills

Execute Context7 CLI commands directly. Printing commands without execution is forbidden.

## Permitted Commands (Exhaustive)

| Intent | Command |
|--------|---------|
| Search | `ctx7 skills search <keywords...>` |
| Install | `ctx7 skills install <repository> [skill] [--all] [target]` |
| List | `ctx7 skills list [target]` |
| Remove | `ctx7 skills remove <name> [target]` |
| Info | `ctx7 skills info <repository>` |

No other commands may be executed.

## Target Flags (exactly one allowed)

- `--global` -- global
- `--claude` -- `.claude/skills/`
- `--cursor` -- `.cursor/skills/`
- `--codex` -- `.codex/skills/`
- `--opencode` -- `.opencode/skills/`
- `--amp` -- `.agents/skills/`
- `--antigravity` -- `.agent/skills/`

If multiple targets are requested, stop and ask the user to pick one.

## Execution Rules

1. Always execute via `ctx7`. The `skills` namespace is mandatory.
2. Only commands listed above may be executed.
3. At most one target flag per command.
4. `--all` is only valid with `install`.
5. Fix invalid, ambiguous, or incomplete input before execution.

## Network Permission Gate

Commands requiring network access (`search`, `info`, remote `install`):
1. Request outbound network permission from the execution environment.
2. If granted, execute immediately (no redundant user confirmation).
3. If denied, stop and tell the user to run locally or provide output.
4. If execution fails with a network error (`fetch failed`, DNS, timeout), treat as environment limitation. Do not retry without explicit permission.

## Search Output Rules

1. Display results as a numbered list starting at 1. Preserve entry text as-is.
2. If the first run contains visible entries, do not rerun.
3. Rerun once only if: no visible entries appeared, or output is truncated with only summary lines.

## Install Flow (from search)

1. User replies with a number `k` to select a skill.
2. Extract `skill_name` and `repository` from the selected entry.
3. If invalid selection, ask for a valid number.
4. If no target was specified, prompt with numbered target list:
   1. `--claude`  2. `--cursor`  3. `--codex`  4. `--opencode`  5. `--amp`  6. `--antigravity`  7. `--global`
5. Do NOT use `--all` for single skill install.
6. Request network permission if remote, then execute:
   `ctx7 skills install <repository> <skill_name> <target_flag>`
7. Display raw CLI output as-is.

## Error Handling

- Missing `skills` namespace: add it automatically and proceed.
- Command outside permitted scope: reject and list permitted commands.
- More than one target flag: stop and ask user to pick one.
- Network failure: report as environment limitation, do not retry.
- Empty search results: suggest broadening keywords.
