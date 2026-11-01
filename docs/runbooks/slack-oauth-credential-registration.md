# Slackアプリ資格情報の登録専用検証

cor-osの実ログインやコネクタ認証とは別の、Client ID/Secretの検証・登録手順。
既存の `slack-oauth` は無効codeに対する比較probeであり、両側invalid_codeでは保存しない。
新しい `slack-oauth-code` は有効codeの交換成功を使う。**実値では未検証、実行GO前。**

## 実行前に本人と確認する事項

- Cor OSアプリ `A0CDE0UUC79`、workspace `T062U0CS2RJ`、company@またはcloudiaの承認済み利用者IDに限定する。社員全員への開放ではない。
- 対象利用者のこのアプリへの既存認可・既存トークンがないことを管理画面で確認する。
  Slackは再認可で既存トークンを返す可能性があり、この確認なしでは失効処理を実行しない。
- 一時的にUser Scope `users:read`（ワークスペースの利用者情報の閲覧）を設定し、本人が同意する。
  メッセージ・ファイル・投稿・メールアドレスの権限は要求しない。実際のデータ閲覧APIは呼ばない。
- 一時Redirect URL `https://127.0.0.1:8765/slack-register` を追加する。既存の本番callbackは変更しない。
  runnerはこのTCPポートをlistenせず予約し、他のサービスが使用中なら値入力前に拒否する。
  サーバーは起動しない。callbackは接続失敗または待ち状態になる。
  **URLを取得 → callbackのロードを停止またはタブを閉じる → hidden promptへURLを渡す**順を守る。
  予約解放後のブラウザ再試行を残さない。中断時も先にcallbackタブを閉じる。
  Slackがこのcallbackを受理するか・失敗画面のURLを取得できるかは実値フローで未検証。不可なら止める。
- token rotationは無効の状態を確認する。refresh tokenやbot tokenが返れば保存を拒否して後始末へ進む。
- 以上の権限・本人同意・後始末を示して実行GOを得る。設計・実装の承認だけで実行しない。

## 実行経路

レビュー済みの同じtreeからwrapper/runner/recipe/補助moduleを一緒に使う。配備はdevelop反映後に限定。
GO後のコマンドは次の形（利用者IDは公開IDの確認済み値に置き換える。資格情報ではない）。

```bash
bash ~/.claude/scripts/register-secret-verified.sh --recipe slack-oauth-code SLACK_OAUTH_CLIENT_ID SLACK_OAUTH_CLIENT_SECRET Cor-Incorporated/cor-os --param user-id=U_CONFIRMED_USER --param fresh-grant=yes
```

1. TTYのhidden promptへClient ID/Secretを入れる。値をチャット・argv・履歴・ログへ渡さない。
2. scriptが示すowner-only HTMLをローカルで開き、一時認可に本人が同意する。
   HTMLはClient IDとstateを含むため共有・添付しない。自動でブラウザを開く処理やURLの標準出力はない。
3. callback URL全体を取得し、ロードを停止またはcallbackタブを閉じてからhidden promptへ直接渡す。
   origin/path、state、code、10分上限を検査する。URL取得後にタブのロードを残してはいけない。
4. 同一code＋誤secretを先に送る。HTTP200 / ok:false / bad_client_secret以外は実pairを送らず停止する。
5. 同一code＋実pairの交換がHTTP200 / ok:trueで成功し、app/team/user/scopeが一致することを確認する。
   誤secretの試行でcodeが消費される場合も保存しない。自動の取り直し・再試行はない。
6. 返ったすべてのaccess/refresh tokenにauth.revokeを行い、HTTP200 / ok:true / revoked:trueを要求する。
7. 後始末が通った後にだけ既存storeがGitHubへ2本を登録し、name/updatedAtを読み戻す。
   `--dry-run`も認可・交換・失効を行うため、実値では同じGOが必要。GitHubには保存しない。

## 停止・復旧・撤収

- providerの任意のerror/bodyをログへ出さない。台帳は段階・固定判定のみ。
- 失効が確定しない場合は保存しない。owner-only `cleanup-pending.json` のパスだけを表示して保持する。
  ファイルを開示・添付せず、本人がSlack管理画面でこの新規認可を取り消した後、private directoryを削除する。
  保持ファイルには一時tokenがある。runnerが終了しても認可の取消しまで作業は終わらない。
- 交換中のtimeout、強制終了、ネットワーク断で発行結果が不明な場合も、GitHub登録は禁止。
  受信前に発行されたtokenはscriptから回収できないため、本人がSlack管理画面で新規認可を取り消す。
- 成否にかかわらず、一時Redirect URLとUser Scopeを元の設定へ戻し、検証用ブラウザタブを閉じる。
  値を報告せず、登録成功ならsecret名/updated_at、失敗なら段階と固定判定だけを記録する。
- Access(C)、run7(G)、本番Worker配備、cor-osログインUIには進まない。

一次資料: [OAuthフロー](https://docs.slack.dev/authentication/installing-with-oauth/)、
[交換API](https://docs.slack.dev/reference/methods/oauth.v2.access/)、
[users:read](https://docs.slack.dev/reference/scopes/users.read/)、
[失効API](https://docs.slack.dev/reference/methods/auth.revoke/)。
