# Access Service Token の次の操作 — 準備（実行待ち）

状態: **準備のみ。どの操作もまだ実行していない。**

- R1 は前提が揃っていて、本人が実行できる。
- R2 と R3 は、§3・§4 に書いた前提の PR が先に要る。今は実行できない。

Access の Rotate は、実行の前に本人の確認が要る操作である。旧 secret の失効も、同じ扱いにする（本書の判断）。
根拠は `~/Documents/Codex/2026-11-05/desktop-handoffs/pending/handover-20261105-claude-lanes/README.md`
の「準備まで（実行は寺田確認後）: Access token Rotate …」。
登録の手順そのものは [access-service-token-registration.md](access-service-token-registration.md) にある。
本書は、その手順が 2026-11-02 に通った後に残っている操作だけを扱う。

## 0. 現在の状態

時刻の付いた値は、実行の直前に、同じ行のコマンドでもう一度読む。

| 項目 | 値 | 出典 / 取得コマンド |
|---|---|---|
| GitHub `CF_ACCESS_CLIENT_ID` | updatedAt `2026-11-02T05:44:26Z` | `gh secret list --repo Cor-Incorporated/cor-os --json name,updatedAt`（2026-11-05T06:42Z に実測。名前と時刻だけ） |
| GitHub `CF_ACCESS_CLIENT_SECRET` | updatedAt `2026-11-02T05:44:27Z` | 同上 |
| 2026-11-02 の Rotate | 1 回。probe で停止した後、復旧 recipe で同じ組を再検証して登録した | 11-02 の台帳行 `recipe-access-service-token-recovery-registered`（05:44:27Z、detail「three origins: unauthenticated=3/3 denied; control=3/3 denied; real=3/3 HTTP200 models JSON; retired-origin-absent; old-expiry-preserved」） |
| 旧 secret の期限 | `2027-08-15T00:11:26Z`（token 自身の `expires_at` と同じ）。**失効していない** | 11-02 の記録 `~/Documents/Codex/2026-11-01/6-access-canary-release-secret-required/outputs/access-recovery-cleanup-20261102.json`（`providerOldSecretRevoked: false`）。現在の値は管理 token が無いと読めないので、11-05 には未測定 |
| 11-02 の pair での Router 配備 | 05:44:27Z より後に作られた deploy-workbench の run が success: 41431507091（11-02T10:46:41Z）、41780322171（11-04）、41984950843（11-05T07:06:55Z）。どれも「Deploy all twelve Workers」step が success | §3 の「配備の証跡」のコマンド。workflow は Router に `secrets.CF_ACCESS_CLIENT_*` を渡す |
| Access app `Cor OS Ollama Origins`（07144d8d-…） | destinations / self_hosted_domains は a / b / c / **fn-b**。fn-b は 2026-11-04 に、同じ app、同じ policy で追加された | `~/Documents/ai-cluster-ops/report_20261104_go1-access-fn-b.md`（統括の報告。API で読み直してはいない） |
| Router の primary | `llm-origin-a` / `llm-origin-b` / `llm-origin-fn-b`（c は primary ではない） | cor-os main `packages/llm-router/src/index.ts` の `expectedPrimaryPolicy`（cor-os 8e0803f 以降） |
| recipe の検証先 | `llm-origin-a` / `llm-origin-b` / `llm-origin-c` | `scripts/lib/secret-verify-recipes.json` の `origins` と、`scripts/lib/access_service_token.py:22` の `ORIGINS` |
| 退役した `llm-origin-f.cor-jp.com` | DNS の A レコードなし | `dig +short llm-origin-f.cor-jp.com A`（2026-11-05 に実測、空） |
| 配備済みの helper | `access_service_token.py` と `register-secret-verified.sh` は develop と一致。`secret_recipes.py` と `secret-verify-recipes.json` は一致しない。`slack_oauth_code.py` は配備されていない（#481 以降が未配備） | §4 の「配備の確認」のコマンド（2026-11-05 に実測） |
| 一時管理 token の残り | 11-02T05:58Z の時点で `cor-os-access-registration-20261102`（record id `9cbca5821c242056d76fa319e094e929`）と `cor-os-access-registration-20261101`（`34fb517fddc8e73a4be6d615b8ed9e14`）が残っていた | 11-02 の記録 `access-recovery-manager-deleted-20261102.json`。現在の有無は未確認 |

## 1. 残っている操作

| # | 操作 | 誰が | 前提 | 今の状態 |
|---|---|---|---|---|
| R1 | 一時管理 token 2 本の取り消し | 本人（Cloudflare の画面） | なし | **実行できる** |
| R2 | 旧 secret の失効（`previous_client_secret_expires_at` を前倒しする） | 本人が同席し、レビュー済みの経路で | §3 の P1〜P5 | **実行できない**。経路が未実装で、recipe の origin も合っていない |
| R3 | 次の再 Rotate（定期や漏洩時） | 本人が同席し、`--recipe access-service-token` で | R2 の目標時刻を過ぎている、recipe の origin を Access app に合わせる、develop の配備 | **実行できない**（§4） |

## 2. R1 一時管理 token の取り消し

- 対象は Cloudflare の **account API tokens** の一覧にある次の 2 本:
  - `cor-os-access-registration-20261102`（record id `9cbca5821c242056d76fa319e094e929`）
  - `cor-os-access-registration-20261101`（record id `34fb517fddc8e73a4be6d615b8ed9e14`）
- `cor-os-access-read` と `square-limit-6932` は対象外。用途が別なので消さない。
- 画面の場所: account（`9973f2d2304b58a1f90d4d9409e9f8cc`）の API tokens の一覧。メニュー名とボタンの文言は未確認。
  - 11-02 に `cor-os-access-recovery-read-20261102` を削除したときと同じ一覧である。
- 確認: 削除した後に一覧を再読み込みし、2 本が無いことを目で確かめる。
- ロールバック: 不要。管理 token は R2 や R3 の直前に、短い期限で新しく発行する。

## 3. R2 旧 secret の失効

### 前提（現在値 → 必要な値）

| # | 前提 | 現在値 | 必要な値 / 確かめ方 |
|---|---|---|---|
| P1 | 配備中の Router が、GitHub にある今の pair（新しい secret）を持っている | 満たす（§0 の配備の行） | 実行の直前に、下の「配備の証跡」で 3 点を確かめる。(a) 最新の deploy-workbench の run が `completed` / `success` で、その `createdAt` が `CF_ACCESS_CLIENT_SECRET` の今の updatedAt より後。(b) その run の「Deploy all twelve Workers」step が success。(c) 実行中・待機中の run が無い。workflow の外で行った `wrangler rollback` は、この方法では見えない。**bearer probe ではこれを確かめられない。** probe は fn-b のモデルしか通らず、猶予の間は旧 secret も新 secret も受け付けられる |
| P2 | 旧 secret の利用者が他にいない | **未確認** | 確かめる手段が無い（Access の記録は secret ごとに分かれていない）。そこで猶予つきで失効させる（下の手順 2） |
| P3 | 管理 token に `Access: Service Tokens Write` と `Access: Apps and Policies Read` がある | 発行していない | 本人が短い期限で発行する。update API が受け付ける権限は `Access: Service Tokens Write`（一次資料 2） |
| P4 | 実行経路がレビュー済みで、develop から配備されている | **無い** | 下の「実行経路」 |
| P5 | recipe の origin が Access app と一致する | 一致しない（a / b / c と a / b / c / fn-b） | §4 の 2 と同じ PR。`retire-previous` が `preflight()` を使い回すなら、そこで止まる |

### 配備の証跡（P1）

```bash
gh secret list --repo Cor-Incorporated/cor-os --json name,updatedAt -q '.[] | select(.name == "CF_ACCESS_CLIENT_SECRET") | .updatedAt'
```

```bash
gh run list --repo Cor-Incorporated/cor-os --workflow deploy-workbench.yml --limit 5 --json databaseId,status,conclusion,createdAt
```

```bash
gh run view <最新の completed run の databaseId> --repo Cor-Incorporated/cor-os --json jobs -q '[.jobs[].steps[] | select(.name | test("Deploy all")) | .conclusion]'
```

- 1 本目の時刻より後に作られた、最新の `completed` の run が `success` であること。
- 3 本目が `["success"]` であること（失敗した run では `skipped` になる）。
- 2 本目の一覧に、`in_progress` / `queued` / `waiting` の run が無いこと。

### 実行経路（未実装。提案して停止）

- `access_service_token.py` が受け付ける operation は `rotate` と `recover` の 2 つだけである。
  - 許可の判定は 2 か所にある: `config()`（`access_service_token.py:112-121`）と `secret_recipes.py` の `Run.parse`。
- `CurlTransport` は GET と POST しか送れない（`access_service_token.py:69`）。
- 手で API を叩く手順は書かない。管理 token を argv・shell 変数・環境変数に出さない決まりがある
  （登録 runbook の「一時的な管理token」）。
- 経路を作るなら、recipe に `operation: retire-previous` を足す PR にする。その PR で変える場所と固定する形:
  - 許可の判定 2 か所と、PUT を送れる transport。
  - 要求: `PUT /accounts/9973f2d2304b58a1f90d4d9409e9f8cc/access/service_tokens/00e4af01-4b7b-4f77-a6c7-2038d2c26050`、
    body は `{"previous_client_secret_expires_at": "<目標時刻>"}` の 1 項目だけ。
  - 一次資料 2 によれば、この値は Rotate の後いつでも変えられる。未来へ延ばすことも、過去へ動かして即時に失効させることもできる。
  - 前後の GET で `id` / `name` / `client_id` / `expires_at` / `duration` / `enabled` が変わらないことを照合する。
  - 前倒しだけを許す（現在値より後の時刻は拒否する）。ただし下のロールバックだけは延長を許す。
  - この経路は pair を持たない（GitHub secret は読めない）。新しい secret が Router に届いていることは、P1 の配備の証跡で確かめる。

### 手順（経路が配備された後）

1. P1 の (a)〜(c) を確かめる。
2. 目標時刻を **今から 24 時間後**にする。取得は `date -u -v+24H +%Y-%m-%dT%H:%M:%SZ`（macOS）。
   即時失効にはしない。P2 が未確認のため。
3. `retire-previous` を dry-run で走らせ、設定の照合だけを通す。続けて本番で走らせる。
4. 目標時刻を過ぎたら、Router の疎通を下の「probe の起動と読み戻し」で確かめる。

### probe の起動と読み戻し

この probe は、Router が生きていることの smoke に使う。どちらの secret を使っているかは区別できない。

```bash
( set -eu; id=""; t="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; gh workflow run product-fn-bearer-probe.yml --repo Cor-Incorporated/cor-os --ref main; for i in 1 2 3 4 5 6 7 8 9; do id="$(gh run list --repo Cor-Incorporated/cor-os --workflow product-fn-bearer-probe.yml --event workflow_dispatch --limit 5 --json databaseId,createdAt -q "[.[] | select(.createdAt >= \"$t\")][0].databaseId // empty")"; [ -n "$id" ] && break; sleep 10; done; [ -n "$id" ] || { echo "NG: no new probe run found" >&2; exit 1; }; echo "run=$id"; gh run watch "$id" --repo Cor-Incorporated/cor-os --exit-status )
```

- subshell の中で動かす。起動が失敗したとき、または新しい run が見つからないときは、前の run を見ずに非 0 で終わる。
- 起動した時刻以後に作られた run だけを拾う。この workflow は schedule（00:47 と 09:17 UTC）でも走るので、`--limit 1` だけでは前の run を拾う。
- `gh run watch --exit-status` は、run が失敗すると非 0 で終わる。
- a / b を通る alias（例: `cor-qwen3.6-35b`）の疎通を確かめる手段は、この probe には無い。cor-os 側で同じ形の probe を足すかどうかは未決である。

### ロールバック

- 目標時刻の前なら、同じ経路で `previous_client_secret_expires_at` を `2027-08-15T00:11:26Z` へ戻す。
  延ばせることは一次資料 2 に書いてある。
- 目標時刻を過ぎた後に、失効した secret を戻せるかどうかは未確認である。戻せないものとして扱う。
  その場合は R3（再 Rotate → 登録 → Router の再配備）になる。このため手順 2 で猶予を置く。
- **旧 secret が失効すると、それを持つ古い Worker の版はすべて origin に届かなくなる。**
  失効の後に、11-02 より前の release へ戻してはならない。
  - 11-05 の cor-os-router-release 報告 §5-3 の 5 は、secret の違う release に戻すと Cloudflare の error 10220 になりうると書いている。
- 「Disable token」はロールバックではない。現在の secret も止まり、Router が止まる（一次資料 3）。

## 4. R3 次の再 Rotate

### 今は実行できない理由（どれも、実行すると preflight か事後の照合で止まる）

1. **旧 secret がまだ生きている。**
   - preflight は `previous_client_secret_expires_at` が今より後なら `overlap`（「Access token already has a live previous secret; do not rotate again」）で拒否する（`access_service_token.py:297-300`）。
   - R2 の目標時刻を過ぎるまで、R3 はできない。
2. **recipe の origin と Access app が合っていない。**
   - `app_contract`（`access_service_token.py:162-172`）は、対象 app の `self_hosted_domains` と `destinations` が、recipe の origin と完全に一致することを求める。
   - Access app は a / b / c / fn-b、recipe は a / b / c である。preflight はここで止まる。止まったときの文言は「Access application differs from the reviewed three-origin application」。
   - 直す PR では、recipe の `origins` を **a / b / c / fn-b**（Access app と同じ）にする。あわせて次も変える。
     - `access_service_token.py:22` の `ORIGINS` と、`config()` の照合（`:127`）。
     - 順序。app の `domain` は origin の先頭と一致しなければならない（`:165`）。
     - `len(ORIGINS)` の照合（`:170`）と、`:130` / `:172` の文言の「three」。
   - Router に合わせて a / b / fn-b にすると、c が app に残っているので、やはり止まる。
3. **配備が develop より古い。** develop で `setup.sh` を走らせてから実行する（develop 以外では走らせない）。

### 配備の確認と setup.sh

```bash
cd ~/Developer/claude-code-skills && git fetch origin && git status -sb | head -1
```

- 出力が `## develop...origin/develop` で、behind が無いことを確かめる。behind があれば `git pull --ff-only` を先に打つ。
- `git status --porcelain -- scripts` の出力が空であることも確かめる。`setup.sh` は `scripts/lib/` を丸ごと複写するので、未追跡や変更中のファイルも配備されてしまう。

```bash
cd ~/Developer/claude-code-skills && bash setup.sh
```

```bash
cd ~/Developer/claude-code-skills && for f in register-secret-verified.sh lib/secret_recipes.py lib/secret-verify-recipes.json lib/access_service_token.py lib/slack_oauth_code.py; do a=$(git show origin/develop:scripts/$f | shasum -a 256 | cut -c1-12); b=$(shasum -a 256 ~/.claude/scripts/$f 2>/dev/null | cut -c1-12); echo "$f develop=$a deployed=${b:-missing}"; done
```

5 行とも `develop=` と `deployed=` が同じ値であることを確かめる。

### 上の 3 点が済んだ後の手順

最初は read-only の preflight である。管理 token は `Access: Service Tokens Read` と
`Access: Apps and Policies Read` で足りるはずである（dry-run は GET だけを送る。権限での実測は未確認）。

```bash
bash ~/.claude/scripts/register-secret-verified.sh --recipe access-service-token CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET Cor-Incorporated/cor-os --param rotate-confirmed=yes --dry-run
```

本人の GO を得たら本番を実行する。管理 token には `Access: Service Tokens Write` と
`Access: Apps and Policies Read` が要る。

```bash
bash ~/.claude/scripts/register-secret-verified.sh --recipe access-service-token CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET Cor-Incorporated/cor-os --param rotate-confirmed=yes
```

- 登録が終わっても、Router は再配備するまで古い組を使い続ける。
- 旧 secret の期限は、元の `expires_at` のまま残る（helper が `previous_client_secret_expires_at` に元の値を渡す、`access_service_token.py:474`）。
  したがって再配備までの間も止まらない。
- 再配備は cor-os の release の操作であり、cor-os 側のゲートに従う（2026-11-05 の handover README の §S-1〜3: 対象 sha・ホスト・ロールバック手順を先に書く → 事前 health → 実行 → 事後 health → 失敗なら即ロールバック）。
  - workflow には必須の入力 `confirm_containers`（既定 `"no"`）がある。job は `yes` かつ main のときだけ走る。
  - 起動の形は `gh workflow run deploy-workbench.yml --repo Cor-Incorporated/cor-os --ref main -f confirm_containers=yes`。
  - 起動する前に、実行中の run が無いことを P1 の (c) で確かめる。
- 再配備の後、P1 の (a)〜(c) をその run で確かめてから、その回の旧 secret について R2 を行う。

### ロールバック

- Rotate の前の失敗: GitHub も Cloudflare も変わらない。
- Rotate の後の失敗: 登録 runbook の「停止・復旧」に従う。recovery directory を保持し、
  `--recipe access-service-token-recovery` で同じ組を再検証する。自動の再 Rotate はしない。
- 登録の後、再配備した Router が動かない場合: 旧 secret はまだ生きている。
  - 直前の release に戻したとき、Worker の secret も旧 pair に戻るかどうかは未確認である。
  - release の rollback は cor-os 側の手順に従う（本書の範囲外）。

## 5. 失敗したら

| 出る文言 / 状態 | 原因 | 処置 |
|---|---|---|
| `Access token already has a live previous secret; do not rotate again` | R2 の目標時刻を過ぎていない | R2 を先に行い、目標時刻を過ぎるのを待つ |
| `Access application differs from the reviewed three-origin application` | recipe の origin と Access app の構成が違う（fn-b）。旧 secret が失効した後なら、preflight で最初に止まるのはここである（生きている間は `overlap` が先に出る） | 自動修正しない。recipe の PR で origin を a / b / c / fn-b に合わせる |
| `Access origins have missing or overlapping applications`、`Access target app inventory differs from the reviewed origins` | 別の app が同じ origin を持つ、または app の構成がさらに変わった | 自動修正しない。人がレビューする |
| `Access credential field did not match the contract`（Rotate の要求を送る前） | 管理 token の入力が無い。11-02 の Codex 報告 `~/Documents/Codex/2026-11-02/desktop-handoffs/completed/Codex報告_20261102_ccs-481-access-rotate-run7-merge.md` に、非対話の stdin での dry-run がこれで止まった記録がある | 対話端末の hidden prompt に入れる。値をチャットや argv に出さない |
| 同じ文言が Rotate の要求（POST）の後に出た | 応答の形が契約と違う | 再入力も再実行もしない。表示された recovery directory を保持し、登録 runbook の「停止・復旧」に進む |
| `The retired origin is still covered by an Access application` | f が Access app に戻った | 実行しない。f の除去を確かめる |
| 配備済み helper の sha256 が develop と違う | `setup.sh` を走らせていない | §4 の「配備の確認と setup.sh」 |
| bearer probe が failure | Router か origin の障害 | R2 / R3 に進まない。cor-os 側の issue「Product FN bearer probe failed」を見る |

## 6. 一次資料

1. [Rotate API](https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/service_tokens/methods/rotate/)
   - `previous_client_secret_expires_at` を省くと、旧 secret は即時に失効する。
   - 応答には `client_secret` が入る。
2. [Update a service token](https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/service_tokens/methods/update/)
   - `previous_client_secret_expires_at` は Rotate の後いつでも変えられる（延長も、過去への移動による即時失効も）。
   - 受け付ける権限は `Access: Service Tokens Write`。
3. [Service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/)
   - Rotate 時の猶予（Keep the current secret valid for）は 1 時間〜30 日。
   - token を disable すると、猶予中の旧 secret も止まる。
   - 文書にある画面の文言を挙げたが、実際の画面では確かめていない。

3 点とも 2026-11-05 に読んだ。
