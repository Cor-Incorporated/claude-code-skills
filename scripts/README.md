# Codex CLI Scripts

## 経路A: レビュー
```bash
bash ~/.claude/scripts/codex-parallel.sh --review ~/Developer/<repo> --base develop
```

## 経路C: 並列実行
```bash
# 単一タスク
bash ~/.claude/scripts/codex-parallel.sh ~/Developer/<repo> <branch> "プロンプト"

# 複数タスク並列 (worktree分離)
bash ~/.claude/scripts/codex-orchestrate.sh ~/Developer/<repo> tasks.json

# CSV一括
bash ~/.claude/scripts/codex-orchestrate.sh --csv ~/Developer/<repo> tasks.csv "テンプレート"
```

## Sandbox自動選択
`codex-parallel.sh`はプロンプトからsandboxレベルを自動判定:
| パターン | sandbox |
|----------|---------|
| docker/gcloud/terraform | `danger-full-access` |
| npm install/curl/gh pr | `workspace-write` |
| デフォルト | `workspace-write` |

手動オーバーライド: `CODEX_SANDBOX=danger-full-access bash codex-parallel.sh ...`

## tasks.json例
```json
{
  "tasks": [
    {"branch": "test/user-service", "prompt": "テスト作成", "paths": ["src/services/user"]},
    {"branch": "docs/api-update", "prompt": "API docs更新", "paths": ["docs/api"]}
  ]
}
```

## API provider switch (Anthropic ↔ z.ai)

```bash
bash ~/.claude/scripts/claude-provider.sh status
bash ~/.claude/scripts/claude-provider.sh anthropic
bash ~/.claude/scripts/claude-provider.sh zai
```

## H2 / H10 measurement

These scripts append measurement records through the existing H6 ledger helper.
They do not install hooks, block commands, or create required checks.

```bash
# Review-ready PRs and local worktree pressure. Warnings still exit 0.
bash scripts/wip-inventory.sh --repo="$PWD" --github=Cor-Incorporated/claude-code-skills

# Activity and landed outcomes in the start-inclusive, end-exclusive window.
bash scripts/stage-landing.sh \
  --github=Cor-Incorporated/Grift \
  --from=2026-08-20T10:16:58Z \
  --to=2026-08-21T00:16:58Z \
  --cd-workflow=v2-alpha-cd.yml
```

`wip-inventory.sh` records `active_lanes: null`; there is no machine-readable
lane registry. `stage-landing.sh` likewise records
`issue_closeable_reached: null` because historical closeability transitions
have no repository SSOT. `Agent-Lane` attribution requires exactly one valid
commit trailer and never guesses from author names or `Co-Authored-By` lines.

See [docs/runbooks/provider-switching.md](../docs/runbooks/provider-switching.md).
