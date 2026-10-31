# harness plugin を Cor mirror (5.16.0-cor.1) に切り替える

**人間ゲート**: 床規則の本番配備。寺田が実行する（2026-10-31 統括の指示）。
起点: aidd-governance#230（egress 床の誤検知率 75 %）、ADR-014。設計は
Cor-Incorporated/claude-code-harness の `docs/runtime-floor-egress-allowlist.md` と `COR-PATCHES.md`。

## 何が変わるか

| 項目 | 現在値（2026-10-31 実測） | 切り替え後 |
|---|---|---|
| marketplace の取得元 | `github` `Chachamaru127/claude-code-harness` | `github` `Cor-Incorporated/claude-code-harness`（private、既定 branch `cor`） |
| marketplace 名 | `claude-code-harness-marketplace` | 同じ（変えない） |
| plugin id | `harness@claude-code-harness-marketplace` | 同じ。settings.json の `enabledPlugins` は変わらない |
| 版 / gitCommitSha | `5.16.0` / `c2304c325d4432f51d632e0586d886767b0f41ea` | `5.16.0-cor.1` / `e74049c061dc63b7160c161a410ece7ff93ed175`（mirror #3 の merge。#2・#3 は docs だけで、binary は #1 の merge a2e2a31b と同じ） |
| egress の宣言 env | なし | `HARNESS_RUNTIME_FLOOR_EGRESS_ALLOW` / `HARNESS_RUNTIME_FLOOR_EGRESS_READ_ALLOW`（claude-code-skills の settings.json が配る） |

現在値は次で確かめる:

```bash
python3 -c 'import json,os;d=json.load(open(os.path.expanduser("~/.claude/plugins/installed_plugins.json")));print([(e["version"],e["gitCommitSha"]) for e in d["plugins"]["harness@claude-code-harness-marketplace"]])'
```

```bash
python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.claude/plugins/known_marketplaces.json")))["claude-code-harness-marketplace"]["source"])'
```

## 前提（両方そろってから始める）

1. mirror の `cor` の版が `5.16.0-cor.1` で、先頭が `e74049c0…`（2026-10-31T07:10:08Z に merge 済み。claude-code-skills の `config/runtime-floor-allowlist.json` の `egress.requires_commit`）。

   ```bash
   gh api 'repos/Cor-Incorporated/claude-code-harness/contents/VERSION?ref=cor' --jq .content | base64 -d
   ```

   ```bash
   gh api repos/Cor-Incorporated/claude-code-harness/branches/cor --jq .commit.sha
   ```

   版が `5.16.0-cor.1` でなければ止める。先頭の sha が `e74049c0…` と違えば、mirror に後から入った変更がある（`COR-PATCHES.md` を見てから進む）。
   URL は引用符で囲む（zsh は `?` を glob として展開し、`no matches found` で止まる）。

2. claude-code-skills の Cor-Incorporated/claude-code-skills#456（egress の宣言と settings.json env）と #457（F8 opt-out）が develop に merge 済みで、共有 checkout で `setup.sh` を流してある。merge と `setup.sh` はエージェントが済ませてから、この手順書を渡す（統括の指示）。済んでいなければ、共有 checkout で次の 3 つを実行する:

   ```bash
   git -C ~/Developer/claude-code-skills switch develop
   ```

   ```bash
   git -C ~/Developer/claude-code-skills pull --ff-only
   ```

   ```bash
   cd ~/Developer/claude-code-skills && bash setup.sh
   ```

   live の env が宣言と一字一句一致することを確かめる:

   ```bash
   python3 -c 'import json,os;e=json.load(open(os.path.expanduser("~/.claude/settings.json"))).get("env",{});d=json.load(open(os.path.expanduser("~/Developer/claude-code-skills/config/runtime-floor-allowlist.json")))["egress"];print([bool(d.get(p,{}).get("env")) and e.get(d[p]["env"])==",".join(d[p]["entries"]) for p in ("internal","read")])'
   ```

   `[True, True]` であること。`[False, False]` なら、共有 checkout が #456 より前か、`setup.sh` をまだ流していない（上の 3 つ）。env は 5.16.0 には効かない（読まない）ので、先に配っても挙動は変わらない。

   `~/.claude/settings.local.json` の env は `settings.json` より優先する。床の変数が置かれていないことを確かめる:

   ```bash
   python3 -c 'import json,os;p=os.path.expanduser("~/.claude/settings.local.json");print(sorted(k for k in (json.load(open(p)).get("env",{}) if os.path.exists(p) else {}) if k.startswith("HARNESS_RUNTIME_FLOOR")))'
   ```

   `[]` であること（2026-10-31 の実測も `[]`）。何か出たら、その行を消すかどうかを決めてから進む。`HARNESS_RUNTIME_FLOOR_EGRESS=off` があると、切り替えても egress 床は動かない。

## 手順

### 1. plugin data を退避する

marketplace を外すと、その marketplace の plugin の保存データも消える
（`claude plugin marketplace remove` の出力: "The removal also deletes their saved options, secrets and data where it can."。
2026-10-31 に隔離した `CLAUDE_CONFIG_DIR` で実測）。

```bash
tar -C ~/.claude/plugins/data -czf ~/.claude/plugins/data-backup-harness-before-cor.tgz harness-claude-code-harness-marketplace claude-code-harness-claude-code-harness-marketplace
```

```bash
tar -tzf ~/.claude/plugins/data-backup-harness-before-cor.tgz | wc -l
```

2026-10-31 15:1x の実測では 193 + 642 ファイル（ディレクトリ行を含めると少し多い）。0 なら止める。中身は秘密を含みうるので、開いて読まない。

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
**`add` か `install` が失敗したら、その場で同じコマンドをもう一度実行する**（下の失敗表）。plugin が無いままのセッションには床も R01〜R13 も無い。

### 3. plugin data を戻す（無くなったファイルだけ）

```bash
tar -C ~/.claude/plugins/data -xzkf ~/.claude/plugins/data-backup-harness-before-cor.tgz
```

`-k` は既にあるファイルを上書きしない。消えたファイルだけが戻る（2 つのディレクトリとも）。

### 4. 稼働中のセッションを再起動する

hook は起動時の plugin パスで動く。走っているセッションは 5.16.0 の床のまま
（5.16.0 の cache は消えない）。新しい床は再起動したセッションから効く。

### 5. 確認する

```bash
python3 -c 'import json,os;d=json.load(open(os.path.expanduser("~/.claude/plugins/installed_plugins.json")));print([(e["version"],e["gitCommitSha"][:8]) for e in d["plugins"]["harness@claude-code-harness-marketplace"]])'
```

`[('5.16.0-cor.1', 'e74049c0')]` であること（2026-10-31 16:17 の隔離リハーサルの値）。

```bash
cd ~/Developer/claude-code-skills && bash tests/test-runtime-floor-allowlist.sh | tail -2
```

`pass=71 fail=0 skip=0`（2026-10-31 16:08 JST に mirror の build で実測。binary は e74049c0 と同じ）。テストは `installed_plugins.json` の installPath の enforcer を使い、その `gitCommitSha` が宣言の `egress.requires_commit` と同じことも確かめる。`skip=1` なら、installed はまだ 5.16.0。

```bash
cd ~/Developer/claude-code-skills && bash tests/test-auto-broadcast-optout.sh | tail -2
```

`pass=24 fail=0 skip=0`（2026-10-31 16:15 JST に mirror の build で実測。#457 の 4424a75）。

#### わざと 1 回止めて、記録に行が増えることを確かめる

床は Claude Code の PreToolUse hook なので、**自分の端末で curl を打たない**（判定されずに本当に通信する）。再起動した Claude Code のセッションに打たせる。

1. 監査ファイルの行数を数える:

   ```bash
   wc -l < ~/Developer/claude-code-skills/.claude/state/audit/guardrail-fires.jsonl
   ```

2. cwd が `~/Developer/claude-code-skills` の、再起動した Claude Code のセッション（worktree の中ではないもの。worktree のセッションは、その worktree の `.claude/state/` に書く）に、こう頼む: 「Bash tool で `curl -sS https://example.com/` を 1 回だけ実行して」。
   返ってくる deny の理由（2026-10-31 に mirror の build で実測）:

   ```text
   RUNTIME_FLOOR:egress: runtime action hard floor: a read from a host that is not a declared public registry or cluster host requires human approval (egress:read) (read example.com)
   ```

3. もう一度 1 と同じコマンドを実行し、行数が 1 増えたことを確かめる。最後の行を見る:

   ```bash
   tail -1 ~/Developer/claude-code-skills/.claude/state/audit/guardrail-fires.jsonl
   ```

   `"rule_id":"RUNTIME_FLOOR:egress","category":"egress","decision":"deny"` を含むこと。`command_len` はセッションが実際に打ったコマンドの長さで、頼んだとおりなら 29。行に deny の種類と宛先は無い（理由はエージェントにだけ返る）。

4. 台帳。bridge（Cor-Incorporated/claude-code-skills#445、30 本目の登録）が配備されていれば、同じセッションの次の Bash 呼び出しの後に、台帳へ 1 行入る。たとえば `true` を 1 回実行させてから:

   ```bash
   tail -1 ~/.claude/hooks/ledger/guard-ledger.jsonl
   ```

   `"hook":"harness-guardrail"`、`"rule":"RUNTIME_FLOOR:egress"`、`"decision":"deny"` を含むこと。ADR-014 の退役・再設計の条件はこの台帳で測る。

## 戻す

```bash
tar -C ~/.claude/plugins/data -czf ~/.claude/plugins/data-backup-harness-before-rollback.tgz harness-claude-code-harness-marketplace claude-code-harness-claude-code-harness-marketplace
```

```bash
claude plugin marketplace remove claude-code-harness-marketplace
```

```bash
claude plugin marketplace add Chachamaru127/claude-code-harness
```

```bash
claude plugin install harness@claude-code-harness-marketplace
```

```bash
tar -C ~/.claude/plugins/data -xzkf ~/.claude/plugins/data-backup-harness-before-rollback.tgz
```

そのあと手順 4 で再起動する。install の結果は手順 5 の 1 本目で確かめ、`[('5.16.0', 'c2304c32')]` であること（upstream の main が先に進んでいれば別の版になる。そのときは `COR-PATCHES.md` の手順で mirror に取り込むまで、その版を使う）。
settings.json の egress env は 5.16.0 では読まれないので、外さなくてよい。戻した後の `tests/test-runtime-floor-allowlist.sh` は `fail=0 skip=1`（after の検査が「切り替え待ち」になる）。

## 問題が起きたら

| 症状 | 原因 | 対処 |
|---|---|---|
| `marketplace add` が `Original error: Cloning into …` で失敗し、続く install が `Plugin "harness" not found in marketplace` | clone の一時的な失敗（2026-10-31 15:24 の隔離リハーサルで、戻す側の add に 1 回起きた。再実行で成功） | 同じ `add` を再実行してから `install`。remove の後なので、成功するまで新しいセッションを始めない |
| `marketplace add` が認証で失敗 | private repo を読めない | `gh auth status` と `ssh -T git@github.com` で Cor-Incorporated の読み取り権限を確かめる。直らなければ「戻す」の add / install を実行する |
| install 後の版が `5.16.0` | `cor` が `5.16.0-cor.1` でない（前提 1） | 前提 1 を確かめてから `claude plugin update harness@claude-code-harness-marketplace` |
| 前提 2 の確認が `[False, False]` | 共有 checkout が #456 より前（宣言に `internal.env` が無い）か、`setup.sh` をまだ流していない | 前提 2 の 3 つのコマンドを実行してから、もう一度確かめる |
| リンクテストが `L3 requires_commit: declared=... installed gitCommitSha=...` で落ちる | `cor` に、宣言の pin より後の commit が入った（VERSION が同じでも中身が違いうる） | 進めない。`COR-PATCHES.md` と `git log <pin>..origin/cor` で何が入ったかを見て、claude-code-skills の `egress.requires_commit` を PR で更新するか、戻す |
| リンクテストが `L1 egress.internal: declared=... settings.json=...` で落ちる | **repo の** settings.json の値が宣言と違う（L1 は repo 側を比べる） | 両方の値が出ているので、repo の settings.json を宣言の値に直す（PR で）。live 側の確認は前提 2 のコマンド |
| クラスタ宛てがまだ止まる | env が hook の process に届いていない（起動前の設定） | セッションを再起動する。`HARNESS_RUNTIME_FLOOR_EGRESS=off` は**置かない**（codex 子プロセスまで床が消える） |

## 実行者テスト

- 2026-10-31 13:26 JST: 隔離した `CLAUDE_CONFIG_DIR` で、手順 2 と「戻す」を通した（`cor` が merge 前だったので、版は 5.16.0 のまま）。
- 2026-10-31 15:24 JST: `cor` の merge 後に、同じことをやり直した。
  - upstream `5.16.0 c2304c32` → remove → mirror を add して install すると `5.16.0-cor.1 a2e2a31b`。marketplace 名と plugin id は同じまま。
  - 戻す側の add が clone の一時的な失敗で 1 回落ち、install も落ちた。再実行で `5.16.0 c2304c32` に戻った（上の失敗表の 1 行目）。
- 2026-10-31 15:47 JST: mirror #2（docs だけ）の merge で `cor` が `b48c78b7` に進んだので、もう一度通した。
  - upstream `5.16.0 c2304c32` → remove → mirror を add して install すると `5.16.0-cor.1 b48c78b7`。戻すと `5.16.0 c2304c32`。add と install は全部 1 回で通った。
- 2026-10-31 16:17 JST: mirror #3（docs だけ）の merge で `cor` が `e74049c0` に進んだので、もう一度通した。
  - upstream `5.16.0 c2304c32` → remove → mirror を add して install すると `5.16.0-cor.1 e74049c0`。戻すと `5.16.0 c2304c32`。add と install は全部 1 回で通った。
