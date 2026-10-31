# harness plugin を Cor mirror (5.16.0-cor.1) に切り替える

**人間ゲート**: 床規則の本番配備。寺田が実行する（2026-10-31 統括の指示）。
起点: aidd-governance#230（egress 床の誤検知率 75 %）、ADR-014。設計は
Cor-Incorporated/claude-code-harness の `docs/runtime-floor-egress-allowlist.md` と `COR-PATCHES.md`。

## 何が変わるか

| 項目 | 現在値（2026-10-31 13:2x 実測） | 切り替え後 |
|---|---|---|
| marketplace の取得元 | `github` `Chachamaru127/claude-code-harness` | `github` `Cor-Incorporated/claude-code-harness`（private、既定 branch `cor`） |
| marketplace 名 | `claude-code-harness-marketplace` | 同じ（変えない） |
| plugin id | `harness@claude-code-harness-marketplace` | 同じ。settings.json の `enabledPlugins` は変わらない |
| 版 | `5.16.0`（gitCommitSha `c2304c32`、install 2026-10-16） | `5.16.0-cor.1` |
| egress の宣言 env | なし | `HARNESS_RUNTIME_FLOOR_EGRESS_ALLOW` / `HARNESS_RUNTIME_FLOOR_EGRESS_READ_ALLOW`（claude-code-skills の settings.json が配る） |

現在値は次で確かめる:

```bash
python3 -c 'import json,os;d=json.load(open(os.path.expanduser("~/.claude/plugins/installed_plugins.json")));print(d["plugins"]["harness@claude-code-harness-marketplace"])'
```

```bash
python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.claude/plugins/known_marketplaces.json")))["claude-code-harness-marketplace"]["source"])'
```

## 前提（両方そろってから始める）

1. mirror の PR が `cor` に merge 済みで、`cor` の版が `5.16.0-cor.1`。

   ```bash
   gh api 'repos/Cor-Incorporated/claude-code-harness/contents/VERSION?ref=cor' --jq .content | base64 -d
   ```

   `5.16.0-cor.1` 以外（`5.16.0`）なら merge 前。切り替えても中身は upstream と同じなので、ここで止める。
   2026-10-31 13:3x 時点の実測: `cor` は `5.16.0`（merge 前）、`fix/egress-floor-redesign` は `5.16.0-cor.1`。
   URL は引用符で囲む（zsh は `?` を glob として展開し、`no matches found` で止まる）。

2. claude-code-skills の PR（egress 宣言 + settings.json env + opt-out）が develop に merge 済みで、共有 checkout で `setup.sh` を流してある。

   ```bash
   python3 -c 'import json,os;e=json.load(open(os.path.expanduser("~/.claude/settings.json")))["env"];print(e.get("HARNESS_RUNTIME_FLOOR_EGRESS_ALLOW","<unset>"));print(e.get("HARNESS_RUNTIME_FLOOR_EGRESS_READ_ALLOW","<unset>"))'
   ```

   2 行とも `<unset>` でなければよい（2026-10-31 13:3x の実測は 2 行とも `<unset>`、PR 未 merge のため）。
   env は 5.16.0 には効かない（読まない）ので、先に配っても挙動は変わらない。

## 手順

### 1. plugin data を退避する

marketplace を外すと、その marketplace の plugin の保存データも消える
（`claude plugin marketplace remove` の出力: "The removal also deletes their saved options, secrets and data where it can."。
2026-10-31 に隔離した `CLAUDE_CONFIG_DIR` で実測）。

```bash
tar -C ~/.claude/plugins/data -czf ~/.claude/plugins/data-backup-harness-20261031.tgz harness-claude-code-harness-marketplace claude-code-harness-claude-code-harness-marketplace
```

```bash
tar -tzf ~/.claude/plugins/data-backup-harness-20261031.tgz | wc -l
```

2026-10-31 の実測では 190 + 642 = 832 ファイル（ディレクトリ行を含めると少し多い）。0 なら止める。

### 2. 取得元を mirror に替える

```bash
claude plugin marketplace remove claude-code-harness-marketplace
```

```bash
claude plugin marketplace add Cor-Incorporated/claude-code-harness
```

```bash
claude plugin install harness@claude-code-harness-marketplace
```

期待する出力: `✔ Successfully added marketplace: claude-code-harness-marketplace` と
`✔ Successfully installed plugin: harness@claude-code-harness-marketplace (scope: user)`。

### 3. plugin data を戻す（消えていたら）

```bash
ls ~/.claude/plugins/data/harness-claude-code-harness-marketplace >/dev/null 2>&1 && echo present || tar -C ~/.claude/plugins/data -xzf ~/.claude/plugins/data-backup-harness-20261031.tgz
```

### 4. 稼働中のセッションを再起動する

hook は起動時の plugin パスで動く。走っているセッションは 5.16.0 の床のまま
（5.16.0 の cache は消えない）。新しい床は再起動したセッションから効く。

### 5. 確認する

```bash
python3 -c 'import json,os;d=json.load(open(os.path.expanduser("~/.claude/plugins/installed_plugins.json")));print([e["version"] for e in d["plugins"]["harness@claude-code-harness-marketplace"]])'
```

`['5.16.0-cor.1']` であること。

```bash
cd ~/Developer/claude-code-skills && bash tests/test-runtime-floor-allowlist.sh | tail -2
```

`pass=70 fail=0 skip=0`（2026-10-31 14:16 JST に mirror の build 310a11b で実測した値。SKIP が 1 なら、まだ 5.16.0 が読まれている）。

```bash
cd ~/Developer/claude-code-skills && bash tests/test-auto-broadcast-optout.sh | tail -2
```

`pass=13 fail=0 skip=0`。

床 → 台帳の bridge（#445）が配備済みなら、わざと 1 回止めて台帳に行が増えることを確かめる
（`curl https://example.com/` を 1 回打つ → deny → 次の行に `"hook":"harness-guardrail"` と `egress:read` が出る）:

```bash
tail -1 ~/.claude/hooks/ledger/guard-ledger.jsonl
```

## 戻す

```bash
claude plugin marketplace remove claude-code-harness-marketplace
```

```bash
claude plugin marketplace add Chachamaru127/claude-code-harness
```

```bash
claude plugin install harness@claude-code-harness-marketplace
```

続けて手順 3 で data を戻し、手順 4 で再起動する。settings.json の egress env は 5.16.0 では読まれないので、外さなくてよい。
戻した後の `tests/test-runtime-floor-allowlist.sh` は `fail=0 skip=1`（after の検査が「切り替え待ち」になる）。

## 問題が起きたら

| 症状 | 原因 | 対処 |
|---|---|---|
| `marketplace add` が認証で失敗 | private repo を読めない | `gh auth status` と `ssh -T git@github.com` で Cor-Incorporated の読み取り権限を確かめる |
| install 後の版が `5.16.0` | `cor` が未 merge（前提 1） | 「戻す」は不要。前提 1 を満たしてから `claude plugin update harness@claude-code-harness-marketplace` |
| リンクテストが `L1 egress.internal: declared=... settings.json=...` で落ちる | setup.sh 未実行、または settings.json を手で編集した | 共有 checkout で `git pull --ff-only && bash setup.sh` |
| クラスタ宛てがまだ止まる | env が hook の process に届いていない（起動前の設定） | セッションを再起動する。`HARNESS_RUNTIME_FLOOR_EGRESS=off` は**置かない**（codex 子プロセスまで床が消える） |

## 実行者テスト（2026-10-31 13:26 JST）

上の 2 と「戻す」を、隔離した `CLAUDE_CONFIG_DIR`（scratch）で通しで実行した。結果:
upstream install `5.16.0 c2304c32` → remove 後に harness の install が消える → mirror を add して install すると
marketplace 名と plugin id は同じまま、取得元が `Cor-Incorporated/claude-code-harness` → 戻すと元の取得元に戻る。
このときの `cor` は merge 前（`pristine` と同じ 5.16.0）だったため、版の変化は前提 1 の後にしか確かめられない。
