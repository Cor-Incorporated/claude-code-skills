# Core Drive UAT の資格登録

Google Cloud の承認済みプロジェクトで、対象が「内部」の専用 Web クライアント1件を扱う。
実運用のHTTPS戻り先はCore Workbenchの専用UAT構成から取得して照合する。

資格を作成する前に、`Cor-Incorporated/cor-os` の `drive-uat` Environment が
ブランチ `main` だけを許可し、タグ許可がないことを確認する。専用WorkerのD1、
R2、Access、稼働版の照合と登録器の配布を済ませる。秘密の転記先は検証器の
非表示入力だけとする。

Google管理者は対象プロジェクトに既存のOAuth付与がない専用の社内検証主体を確認する。
プロジェクト内の既存認可にも取り消しが及ぶため、既存のgws CLIを利用する主体と
製品受入で同意する本人のアカウントは検証主体に使わない。検証時だけ必要な
`http://localhost:8926/google-drive-register` を承認済みクライアントに追加できることを
事前に確認する。

承認済みの検証主体と隔離ブラウザを用意した管理者が、正式配布された登録器を
対話式ターミナルで実行する。クライアントIDと秘密はそれぞれ非表示で受け取る。

```bash
bash ~/.claude/scripts/register-secret-verified.sh --recipe google-drive-oauth-code \
  DRIVE_UAT_OAUTH_PAIR Cor-Incorporated/cor-os --env drive-uat \
  --param test-subject-confirmed=yes
```

同意画面は2回開く。各回の待ち時間は5分。どちらかで「キャンセル」を選ぶか、
同意を返さずに期限を過ぎると、登録器が終了し、GitHubへの保存前で処理が止まる。
再開する場合は端末から登録器を起動し直し、新しく表示されたURLで1回目から進める。

登録器は独立した2つの同意で作ったコードを使い、誤った秘密が拒否されることと正しい組の
`openid` 交換を検査する。検証に使ったトークンの失効が確認できてから、1つの
Environment秘密に保存し、名前と更新時刻を読み戻す。交換結果不明、割り込み、
失効失敗があれば内部検証主体のGoogle付与を管理者が調べる。復旧が確認できるまで
再試行しない。検証用の戻り先は登録から削除し、固定HTTPSの1件を読み戻す。

Coreの資格配送は別操作。本人の事前承認を記録してから `main` の専用Workflowで
`confirm_drive_uat` と配信中の版IDを明示する。両bindingが同じ未配信版に入り、
現配信版100%が維持されたことを読み戻す。承認済みの配信切替後、製品受入の本人が
通常入口で同意し、合成DOCX・XLSX・PPTX各1件のDrive変換と編集再開を確認する。

[Google WebアプリのOAuthと失効](https://developers.google.com/identity/protocols/oauth2/web-server#tokenrevoke)
