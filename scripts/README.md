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

See [docs/runbooks/provider-switching.md](../docs/runbooks/provider-switching.md).

