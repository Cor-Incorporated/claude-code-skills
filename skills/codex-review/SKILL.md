---
name: codex-review
description: "Codexにセカンドオピニオンを求める。AI同士の忖度なしガチレビュー。Use when user mentions 'Codex レビュー', 'セカンドオピニオン', 'Codex の意見', 'Codex でレビュー'. Do NOT load for: 'Codex に実装させて', 'Codex Worker', 'Codex に作らせて', '実装を依頼'."
allowed-tools: ["Bash", "Read"]
argument-hint: "[code|plan|scope]"
---

# Codex Review Integration Skill

OpenAI Codex CLI を使用してコードレビュー時にセカンドオピニオンを提供するスキル。

> **重要**: Codex MCP (`mcp__codex__*`) は使用禁止（delegation.md / Issue #72）。
> 全ての Codex 呼び出しは `codex exec --sandbox read-only` で行う。
> Ref: ADR-004。旧 `hooks/block-codex-mcp.sh` は hook削減により `hooks/_unused/` へ退避済みで現在は発火しない — この禁止事項は現在 hook 強制ではなく運用ルール（自己規律）として遵守すること。

## Do NOT Load For

以下は `codex-worker` スキル（ハーネスプラグイン提供）が担当:

- "Codex に実装させて" / "Codex Worker" / "Codex に作らせて" / "実装を依頼"

## 実行方法（統一: `codex exec --sandbox read-only`）

全てのレビューは `codex exec --sandbox read-only` で実行する。
`codex-parallel.sh --review`（Route A）も内部的に同じ CLI を呼ぶため、
直接 `codex exec` を使用することでシンプルに統一。

### 単発レビュー

```bash
codex exec -C "$(pwd)" --sandbox read-only \
  "以下の変更をレビューしてください: $(git diff HEAD~1)"
```

> **Note**: 出力をファイルに保存する場合は stdout をキャプチャする。
> `-o` (`--output-last-message`) はエージェントの最後のメッセージのみ出力するため、
> 完全な出力には `| tee /tmp/review.md` を推奨。

### 並列エキスパートレビュー

```bash
# 各エキスパートを個別に並列実行（read-only = worktree不使用 = 安全）
codex exec -C "$(pwd)" --sandbox read-only \
  "$(cat experts/security-expert.md)" > /tmp/review-security.md 2>/dev/null &
codex exec -C "$(pwd)" --sandbox read-only \
  "$(cat experts/performance-expert.md)" > /tmp/review-perf.md 2>/dev/null &
codex exec -C "$(pwd)" --sandbox read-only \
  "$(cat experts/quality-expert.md)" > /tmp/review-quality.md 2>/dev/null &
wait
```

> `experts/*.md` はハーネスプラグインが提供。未設定時はプロジェクト固有のプロンプトを作成すること。

**詳細**: [references/codex-parallel-review.md](references/codex-parallel-review.md)

---

## 機能詳細

| 機能 | 詳細 |
|------|------|
| **並列レビュー** | See [references/codex-parallel-review.md](references/codex-parallel-review.md) |
| **レビュー統合** | See [references/codex-review-integration.md](references/codex-review-integration.md) |

## 設定

`.claude-code-harness.config.yaml` で設定（ハーネスプラグインの設定ファイル）:

```yaml
review:
  codex:
    enabled: true
    auto: false
    prompt: "Review the code and output issues and improvement suggestions"
```

> `execution_mode: mcp` はレガシー。以前は `block-codex-mcp.sh` hook でブロックされていたが、当該 hook は `hooks/_unused/` へ退避済みで現在は発火しない。それでも `codex exec --sandbox read-only` を使うことが推奨（hook強制ではなく運用ルール）。

## 注意事項

### 並列実行と ADR-004 の整合

ADR-004「Max 1 concurrent Codex request」は Route C（実装・workspace-write）に対するルール。
`--sandbox read-only` レビューは worktree 不使用・ファイル書き込みなしのため並列安全。
詳細は [references/codex-parallel-review.md](references/codex-parallel-review.md) を参照。

> **TODO**: この解釈は ADR-004 の amendment で正式に明文化すべき。

### 発火検証結果（2026-03-29、履歴）

以下はhook削減前の検証記録。`block-codex-mcp.sh` は現在 `hooks/_unused/` へ退避済みで settings.json にも未登録のため発火しない（履歴として残置）。

| 検証項目 | 結果（当時） |
|---------|------|
| `block-codex-mcp.sh` exit code | 2 (ブロック成功) |
| stderr メッセージ | "[BLOCKED] Codex MCP..." 出力確認 |
| MD5 (`~/.claude/hooks/` vs `hooks/`) | 一致 |
| `settings.json` matcher | `mcp__codex__.*` 登録済み |
| `codex` CLI | v0.117.0 (`/opt/homebrew/bin/codex`) |
| `--sandbox read-only` フラグ | 利用可能 |

---

## 参考資料

- ADR-004: Codex大規模委任モデル (`docs/adr/004-codex-delegation-model.md`)
- delegation.md: Codex CLI 経路 (`rules/delegation.md`)
- block-codex-mcp.sh: 旧 MCP ブロック hook（`hooks/_unused/block-codex-mcp.sh` へ退避済み、現在は未登録・不発火）
