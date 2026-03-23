# Harness Engineering ベストプラクティス (2026年3月)

## 原文
https://nyosegawa.com/posts/harness-engineering-best-practices-2026/

## サマリ

### 核心原則
"プロンプトではなく仕組みで品質強制"

### 8つの柱
1. **リポジトリ衛生** — ADR, テスト優先, CI/CD完備
2. **決定論的品質強制** — PostToolUse/PreToolUse hookで自動lint/format
3. **フィードバック速度階層** — ms (PostToolUse) → s (pre-commit) → min (CI) → h (review)
4. **CLAUDE.md/rules ポインタ型設計** — 50行以下, hookで強制済み内容は削除
5. **Codex大規模委任モデル** — 1リクエスト, 内部分割はCodex自律
6. **テスト反証可能性** — テストがバグを検出することを証明
7. **セキュリティ・ガードレール** — shell injection防止, npx禁止
8. **計測とスコアリング** — delivery_score.py による定量評価

## ADRとの対応

| 柱 | 対応ADR |
|----|---------|
| 決定論的品質強制 | ADR-001: PostToolUse Quality Loop |
| CLAUDE.md設計 | ADR-002: ポインタ型設計原則 |
| フィードバック速度階層 | ADR-003: フィードバック速度階層 |
| Codex委任 | ADR-004: Codex大規模委任モデル |

## 引用
> "短ければ短いほど良い。理想は50行以下"
> "150-200指示でprimacy bias顕著、性能劣化開始"
