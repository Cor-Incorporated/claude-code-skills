# AGENTS.md

## What this repo ships

Shell hooks, skill docs, rules, and setup for Claude Code CLI. Most changes land in `hooks/`, `rules/`, `skills/*/SKILL.md`, `scripts/`, `setup.sh`, or `settings.json`.

## Source of truth

- **`settings.json`** defines every hook registration, env var, and plugin toggle. If docs disagree with it, follow `settings.json`.
- **API provider routing** (Anthropic subscription vs z.ai) is managed by `scripts/claude-provider.sh` via `~/.claude/settings.local.json` + `~/.claude/providers/`. Never put gateway tokens in repo `settings.json`. See `docs/runbooks/provider-switching.md`.
- **Hook wiring is not done** until all four are true: script exists in `hooks/` → `setup.sh` copies it to `~/.claude/hooks/` → `settings.json` registers the matcher or event → trigger verified to fire.

## Hook matcher syntax (critical gotcha)

`settings.json` `matcher` accepts only a **tool-name regex**, not an expression language. Command-level filtering must happen inside the hook script via `stdin` JSON (`tool_input.command`, `tool_input.file_path`).

```
✓ { "matcher": "Bash" }
✓ { "matcher": "Edit|Write" }
✗ { "matcher": "tool == \"Bash\" && tool_input.command matches \"git push\"" }
```

### Exit code convention

| Code | Meaning | PreToolUse behavior |
|------|---------|-------------------|
| `0` | Allow | Tool call proceeds. JSON on stdout parsed for `hookSpecificOutput`. |
| `2` | Block | Tool call blocked. `stderr` fed back to Claude as error. |
| other | Non-blocking error | `stderr` shown in verbose mode only. Execution continues. |

Do **not** echo the input JSON back on stdout at `exit 0`. All hooks in this repo follow: filter on stdin → output to stderr → `exit 0` or `exit 2`.

## Hook architecture

- **17 active hooks** in `hooks/*.sh` (4 blocking + 13 advisory/infra). See
  [hooks/README.md](hooks/README.md) for the full per-hook table and
  [ADR-006](docs/adr/006-minimal-safety-net.md) for why the set is this
  small — merge safety, review completeness, factchecking, context
  budgeting, and Codex call cadence are no longer hook-enforced; they are
  delegated to GitHub branch protection, the PR review workflow, and
  agent judgement guided by `rules/*.md`.
- **`hooks/_unused/`** contains 56 retired hooks + the former
  `gate-modes/` dispatcher architecture (7 modules, previously sourced by
  the now-retired `pr-ci-review-gate.sh`). Do not copy or register these.
- **State files** live in `<project>/.claude/state/`. With the review
  pipeline retired, `review-status.json` / `pr-review-lock.json` /
  `pending-review-comments.json` are no longer read by any active hook.

## Verification commands (matches CI)

CI runs 4 jobs on every PR / push to main or develop. Run the same checks locally:

```bash
shellcheck hooks/*.sh                      # warnings (informational)
shellcheck -S error hooks/*.sh              # errors only (must pass)
bash -n hooks/*.sh scripts/*.sh setup.sh    # syntax check each file
python3 -m json.tool settings.json          # JSON validity
python3 -m json.tool .claude/settings.local.json
bash tests/test-*.sh                        # run all test suites (10 remain; 47+ retired to tests/_unused/)
```

Delivery quality score: `python3 scripts/delivery_score.py` (or `--json` for CI).
Note: some of this script's inputs (e.g. review-pipeline state) describe
a pipeline retired by ADR-006; treat its hook-coverage metric as
referring to the current 17-hook set.

## AI-created PR body contract (H5)

Before creating a PR, inspect the changed paths and write the H5 declarations
from evidence already collected. Do not wait for the first CI failure to learn
the input format, and do not copy claims that were not actually measured.

H5 applies when a change touches any of these structural paths:

- `hooks/**/*.sh` (including direct children such as `hooks/foo.sh`)
- `scripts/**/*.sh` (including direct children such as `scripts/foo.sh`)
- `settings.json`
- `.github/workflows/**`
- any path matched by a repository-root `.aidd-e2e-paths` declaration

For every applicable PR, add exactly one of these execution-boundary forms:

```text
H5-E2E: none
```

Use `none` only when the change has no real execution environment. Otherwise
provide both lines; `H5-E2E-OUT` must contain at least 20 characters of raw
output or a stable log path.

```text
H5-E2E: <command actually run>
H5-E2E-OUT: <raw output summary or log path, 20+ characters>
```

Changes under the four built-in structural paths are also guard/verifier PRs.
Their body must contain all of the following machine-readable declarations in
addition to substantive template sections:

```text
H5-guard: yes
H5-NEGATIVE: <known-bad input and measured red/exit result>
H5-LEDGER: <how each fire reaches aidd_ledger_append or guard-ledger.jsonl>
H5-RETIRE: <measurable retirement condition>
H5-SUBTRACTION: N/A
```

Replace the final line with `H5-RETIRE-PR: <number>` only when that retirement
PR is already merged. `H5-guard: no` can describe a non-structural PR, but it
does not exempt any built-in structural path. These declarations enforce form
and honest visibility; they do not prove that the reported command or output is
truthful.

## Skills

- **Repo-owned** (28): `skills/*/SKILL.md` — each has YAML frontmatter + markdown body, following Anthropic progressive-disclosure structure.
- **Third-party** (installed by `setup.sh`, not vendored): `ctx7@0.3.6`, `gstack` (pinned commit, telemetry off), `uipro-cli@2.2.3`. These are gitignored and live under `~/.claude/skills/` after install.
- gstack installs ~20 additional skills (browse, qa, ship, retro, etc.) listed in `.gitignore` under `skills/<name>/`.

## Key directories

| Path | Contents | Editable |
|------|----------|----------|
| `hooks/` | Shell hook scripts + gate-modes/ | Yes |
| `hooks/_unused/` | Retired hooks | No (reference only) |
| `rules/` | 6 global rule files (coding-style, git-workflow, quality, testing, delegation, hook-deployment) | Yes |
| `skills/*/` | Repo-owned skill definitions | Yes |
| `scripts/` | Utility scripts (codex orchestration, PR review, delivery scoring) | Yes |
| `docs/adr/` | Architecture decision records (001–006) | Yes |
| `.claude/state/` | Hook runtime state files | Only for state/debug tasks |
| `.opencode/` | Generated OpenCode files | No |

## Do not edit

- `.claude/state/` — runtime state, managed by hooks.
- `.opencode/` — generated files.
- `hooks/_unused/` — retired hooks, kept for reference only.
- Third-party skill directories (see `.gitignore`).
