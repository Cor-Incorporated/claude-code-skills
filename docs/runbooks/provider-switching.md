# Provider switching (Anthropic subscription ↔ z.ai)

## Why this exists

Claude Code uses **one** API base URL and auth path per process. If `ANTHROPIC_BASE_URL` points at z.ai and that gateway is down (or model IDs like `glm-5.2[1m]` are rejected), these fail together:

1. Subagents (Explore / Plan / code-reviewer, …)
2. WebSearch / WebFetch (summarizer sub-model)
3. Bash / Agent safety classifier (auto mode)

The main chat model can still look healthy (e.g. OAuth + Fable), which is why the outage feels “subagent-only.”

This repo cannot dual-route subagents to Anthropic while the main session stays on z.ai. Dual support means **clean profiles + one-command switch**.

## Profiles

| Profile | When to use | Routing |
|---------|-------------|---------|
| **anthropic** (default) | Reliability, PR merge work, subagents, WebSearch | Official Claude subscription / OAuth. No `ANTHROPIC_BASE_URL` / gateway token. |
| **zai** | Cost / GLM experiments when z.ai is healthy | `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic` + GLM default model aliases |

## Commands

Installed by `setup.sh` to `~/.claude/scripts/claude-provider.sh`:

```bash
bash ~/.claude/scripts/claude-provider.sh status
bash ~/.claude/scripts/claude-provider.sh anthropic   # recommended default
bash ~/.claude/scripts/claude-provider.sh zai
bash ~/.claude/scripts/claude-provider.sh doctor
bash ~/.claude/scripts/claude-provider.sh migrate-secrets
```

**Always restart Claude Code** (new session) after switching. Running sessions keep the old env.

## Where config lives

| Path | Role |
|------|------|
| Repo / `~/.claude/settings.json` | Shared hooks + non-secret defaults. **No** gateway tokens. `setup.sh` overwrites this from the repo. |
| `~/.claude/settings.local.json` | Active provider env (local wins on merge). Permissions/hooks must **not** live here. |
| `~/.claude/providers/zai.secrets.json` | z.ai token + optional GLM model IDs (mode `600`). Never commit. |
| `~/.claude/providers/active-profile` | Marker: `anthropic` or `zai` |

First switch to `anthropic` migrates any token still sitting in settings into `zai.secrets.json`.

## SessionStart warnings

`hooks/validate-provider-env.sh` runs on SessionStart (non-blocking). It warns on:

- gateway + `CLAUDE_CODE_USE_VERTEX` both set
- GLM model pins without a base URL
- z.ai active / health probe failure

It does **not** auto-switch providers.

## brave-search MCP

Broken Brave subscription tokens (`SUBSCRIPTION_TOKEN_INVALID`) are noisy and redundant when native **WebSearch** works on the Anthropic profile. The switcher removes `brave-search` from `enabledMcpjsonServers` in local settings.

To re-enable later:

1. Obtain a valid `BRAVE_API_KEY` from Brave Search API.
2. `claude mcp add brave-search -e BRAVE_API_KEY=... -- npx -y @modelcontextprotocol/server-brave-search`
3. Prefer keeping **anthropic** profile so WebSearch remains a fallback.

## Recovery when z.ai dies mid-day

```bash
bash ~/.claude/scripts/claude-provider.sh anthropic
# restart Claude Code
bash ~/.claude/scripts/claude-provider.sh status   # expect no ANTHROPIC_BASE_URL
bash ~/.claude/scripts/claude-provider.sh doctor   # expect clean
```

Then retry subagents / `verify-pr-review.sh` / WebSearch.

## Shell env gotcha

If you `source ~/.claude/load-env.sh` or export `ANTHROPIC_*` in `~/.zshrc`, the shell can override settings until you open a new terminal. `doctor` warns when shell `ANTHROPIC_BASE_URL` differs from settings.
