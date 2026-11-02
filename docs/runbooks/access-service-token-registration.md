# Access Service Tokenの検証と登録

cor-os Routerが使用する既存Service Tokenを、旧secretの寿命を短縮せず更新し、
3 originで検証してからGitHubのrepository-level secretsへ登録する。新しいtoken、
Accessアプリ、ポリシー、ユーザーの許可は追加しない。本番Worker配備は別工程。

## 対象と実行条件

- company@の会社アカウント `9973f2d2304b58a1f90d4d9409e9f8cc`。
- 既存 `cor-os-llm-router`、token ID `00e4af01-4b7b-4f77-a6c7-2038d2c26050`。
- `Cor OS Ollama Origins`、app ID `07144d8d-0512-4ce1-943a-a72def65aac0`。
- `LLMルーターのみ`、policy ID `c0fcff31-7e27-441c-bdc2-a454fb7ab062`。
  reusable Service Auth、includeは対象tokenだけ、require/excludeなし。
- 公開宛先は `llm-origin-a.cor-jp.com`、`llm-origin-b.cor-jp.com`、
  `llm-origin-c.cor-jp.com` の3つに固定する。
- Mac Studioは返却済み。`llm-origin-f.cor-jp.com` は退役対象で、DNSとAccess宛先から
  除去してから実行する。preflightと最終検査は、全Access appにfの直接host・wildcard・
  path shadowが残る場合も拒否する。fには資格情報を送らない。Routerのactive経路は
  a/bのみで、cは今回維持する補助origin。MacへのSSH、tunnel再作成、再Rotateは行わない。
- recipe/runner/helperをPRでレビューし、developへ取り込んだ後のsetup.shで配備する。
  未配備の間はRotateしない。設定の差分があれば自動修正せず停止する。
- 本人の本番変更GOを得る。2026-11-01の読み取りでは既存tokenは有効、元の期限は
  `2027-08-15T00:11:26Z`。APIを実行するたびに元の期限を読み直す。

## 一時的な管理token

対象アカウントの `Access: Service Tokens Write` と `Access: Apps and Policies Read`
を持ち、短い期限を設定した管理API tokenを本人が発行する。復旧だけなら
`Service Tokens Read` と `Apps and Policies Read` でよく、Writeは不要。Workers、DNS、
ユーザー情報、API token自体の管理権限は付与しない。これは登録対象のService Token
2値とは別の資格情報で、GitHubへ保存しない。処理後に本人が取り消す。

管理tokenはhidden promptへ入れるか、UID所有0700 directory内の0600 fileからstdinへ
直接渡す。値をチャット、argv、shell変数、環境変数、ログへ出さない。公開出力を残す
前に発行値の画面を閉じる。再認証や新しい資格情報の発行確定は本人が操作する。

## 実行

2026-11-02の停止済み試行は既に1回Rotateしているため、下の更新コマンドを再実行しない。
f退役の反映後に「保存した同じ組を使う復旧」だけを使う。

まずread-only preflight。dry-runは設定のGET照合だけであり、pairの検証成功ではない。

```bash
bash ~/.claude/scripts/register-secret-verified.sh --recipe access-service-token CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET Cor-Incorporated/cor-os --param rotate-confirmed=yes --dry-run
```

同じ配備版で本番実行する。管理tokenの値を入れるだけで、Service Tokenの2値は人が
コピーしない。実値の成否はこの手順の初回実行まで未検証。

```bash
bash ~/.claude/scripts/register-secret-verified.sh --recipe access-service-token CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET Cor-Incorporated/cor-os --param rotate-confirmed=yes
```

1. 対象token、app、全global policy・全app・各appに付いた全policyをGETで照合する。
   各appのpolicy一覧はlegacy/exclusiveとreusableの両方を含め、ページを最後まで読む。
   別appの重複host、wildcard、path shadow、同じtokenを許可する別policy、
   ページ欠落、未知schemaは停止する。現在の構成に合わせ、`allow`は直接の
   `email` / `email_domain` / `login_method`、`non_identity`は直接の`service_token`
   だけを受け付ける。group、any-valid、token-tag、linked token、未知の形式は拒否する。
   無関係なpolicyに新形式が加わった場合も、設定差分として人のレビューへ戻す。
2. 対象tokenを1回だけRotateする。`previous_client_secret_expires_at`へ元の
   `expires_at`を明示し、旧secretの既存寿命を維持する。省略は即時失効になるため禁止。
3. 応答をowner-only fileへ直接保存し、token metadataを読み戻して期限・IDを検査する。
4. 3 originすべての`GET /v1/models`へ、誤secretの陰性対照を先に送る。
   3本ともHTTP403でなければ実pairを送らない。実pairは3本ともHTTP200で
   OpenAI models形式のJSONを返す必要がある。redirect、HTML、timeout、429、5xx、
   判断不能は拒否する。モデル名・応答本文は報告しない。推論APIは呼ばない。
5. probe後にも同じ全設定を再照合し、検証中のtoken・許可先の差分があれば停止する。
6. 成功した2値だけを既存storeからGitHubへ登録し、name/updatedAtを読み戻す。
   store/readbackまで成功したらprivate directoryを削除する。台帳は固定判定のみで、
   管理token、Service Token、任意provider本文は残さない。

## 停止・復旧

Rotate前の失敗はGitHubを変更しない。POST送信以降の失敗・中断・応答不明では
owner-only recovery directoryを保持し、パスだけを案内する。管理bearerの入力/headerは
後始末で除去する。ネットワークの再試行や自動再Rotateはしない。

GitHubは2本の登録をatomicに行えない。片方だけ保存された場合やupdatedAtが不明な
場合も、同じrecoveryを保持する。まず既存tokenとGitHubの名前・更新日時を確認し、
次節のレビュー済み復旧手順で同じpairを再検証する。単独のsecret-setコマンドや、
未検証のrecovery fileの手渡しで迂回しない。値を報告書やartifactに添付しない。

### 保存した同じ組を使う復旧

停止原因を解消し、recovery recipeをレビュー・develop配備してから行う。管理tokenは
再取得してよいが、Service Tokenは再Rotateしない。原本directoryは絶対pathで指定し、
owner-onlyの`rotation-state.json`と`rotation-result.json`をそのまま使う。

```bash
bash ~/.claude/scripts/register-secret-verified.sh --recipe access-service-token-recovery CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET Cor-Incorporated/cor-os --param recovery-dir=/absolute/owner-only/register-secret.attempt --dry-run
```

dry-runは設定・原本と現在metadataの対応・未認証拒否だけの確認で、pair検証ではない。

```bash
bash ~/.claude/scripts/register-secret-verified.sh --recipe access-service-token-recovery CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET Cor-Incorporated/cor-os --param recovery-dir=/absolute/owner-only/register-secret.attempt
```

復旧ではPOSTを禁止し、原本の対象ID・更新日時・開始日時・旧期限を現在metadataと
照合する。同じ3接続先で毎回3陰性対照→3実probe→最終設定確認を通した組だけを
既存storeへ渡す。失敗・中断・部分保存時は原本と新しいprivate workを保持する。
成功時は新しいworkだけを削除し、原本は変更しない。2本のGitHub更新日時と成功台帳を
読み戻した後、作業者が原本の対象2ファイルと空directoryを削除する。

旧secretはRouter配備後のsmokeが成功するまで失効させない。検証が失敗しても
既存secretを残せるので、既存Routerを新しい資格情報へ直接切り替えてはならない。
一時管理tokenの取消しは本人に案内し、private入力fileと表示タブも片付ける。

## 一次資料

- [Rotate API](https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/service_tokens/methods/rotate/)
- [Service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/)

宣言の強制点: `secret-verify-recipes.json`の固定ID/names/repo/3host・退役fを
`secret_recipes.py`と`access_service_token.py`が読み、検証関数が成功して返したpairだけを
既存storeが保存する。setup.shはscripts/lib全体を配備する。offline testとlink testで
宣言・強制・配備経路を照合する。
