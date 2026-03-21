# GCP Deploy — Known Traps Reference

実際のプロダクションインシデントから抽出した既知のトラップ集。
各トラップには Issue 番号、根本原因、修正方法、再発防止策を記載。

---

## 1. Platform Mismatch: arm64 → amd64 (Issue #47)

### 症状
- GKE Pod が `ImagePullBackOff` で起動不能（9時間以上復旧不能）
- `kubectl describe pod` で `Back-off pulling image` のみ表示

### 根本原因
Apple Silicon (M1/M2/M3) で `--platform linux/amd64` を付けずに
`docker build` を実行。イメージマニフェストに arm64 のみ含まれ、
amd64 GKE ノードが互換イメージを見つけられない。

### 診断方法
```bash
docker manifest inspect <image:tag>
# "architecture": "arm64" のみ → NG
# "architecture": "amd64" 含む → OK
```

### 修正
```bash
docker build --platform linux/amd64 -t <image:tag> .
```

### 再発防止
- `pre-deploy-check.sh` でビルド前に自動検査
- `cloudbuild.yaml` を使えばクラウド側で amd64 ビルドされるため安全

---

## 2. Mixed Content: http:// URL in SPA Bundle (Issue #40)

### 症状
- ブラウザコンソールに `Mixed Content` エラー
- STT / API 呼び出しが全停止
- マイクボタン不応答（二次障害）

### 根本原因
`VITE_MILAOS_STT_HTTP_URL=http://136.110.95.111:8090` が
`cloudbuild-cloudrun.yaml` にハードコードされ、Vite ビルド時にバンドルに焼き込まれた。
HTTPS ページから http:// リソースへのアクセスはブラウザが完全にブロックする。

### 診断方法
```bash
# デプロイ済みバンドル内の http:// URL を検索
curl -sL https://<spa-url>/assets/*.js | grep -oE 'http://[a-zA-Z0-9._-]+' | sort -u
# 結果が空であること
```

### 修正
- `VITE_MILAOS_STT_HTTP_URL` ビルド引数を完全削除
- STT は API プロキシ (`/v1/stt-proxy/*`) 経由に変更

### 再発防止
- `pre-deploy-check.sh` でビルド引数に `http://` がないか検査
- `audit-docker-build-args.sh` PreToolUse hook でブロック

---

## 3. VAD ONNX/WASM Assets 404 (Issue #45)

### 症状
- `ort-wasm-simd-threaded.mjs` が 404
- `silero_vad_legacy.onnx` ロード失敗
- `[MILAOS] VAD initialization failed: no available backend found`

### 根本原因（2層）
1. `@ricky0123/vad-web` のランタイムアセットが `node_modules` 内にあり、
   Vite のビルドでは自動的にバンドルされない
2. `vite-plugin-static-copy` で `dest: '.'` にコピーしたが、
   `onnxruntime-web` は dynamic import でバンドル位置 (`/assets/`) 基準でパス解決

### 修正
1. `vite.config.ts` に `vite-plugin-static-copy` を設定（4ファイルコピー）
2. `useVAD.ts` で `MicVAD.new({ onnxWASMBasePath: '/', baseAssetPath: '/' })` を指定

### 再発防止
- デプロイ後に VAD アセットの HTTP ステータスを確認:
  ```bash
  curl -s -o /dev/null -w "%{http_code}" https://<spa-url>/ort-wasm-simd-threaded.mjs
  curl -s -o /dev/null -w "%{http_code}" https://<spa-url>/silero_vad_legacy.onnx
  ```

---

## 4. nginx MIME Type Corruption

### 症状
- `.mjs` ファイルが `text/html` で返される → ES module としてロード不可
- `.wasm` ファイルが正しい Content-Type で返されない

### 根本原因
`server` レベルで `types { }` を定義すると nginx のグローバル MIME テーブルが
上書きされ、全てのファイルタイプが壊れる。

### 修正
```nginx
# CORRECT: location レベルの default_type
location ~* \.mjs$ { default_type application/javascript; }
location ~* \.wasm$ { default_type application/wasm; }
location ~* \.onnx$ { default_type application/octet-stream; }
```

### 注意
SPA の `try_files $uri /index.html` により、存在しないファイルも 200 で返る。
`Content-Type: text/html` が返ってきた場合はファイルが存在しない証拠。

---

## 5. VRM Animation Breakage (Issue #40)

### 症状
- VRM モデルが棒立ち（アニメーションが再生されない）

### 根本原因
- `VRMUtils.combineSkeletons()` がボーンノード名を `${meshName}_${boneName}` に
  リネームし、`AnimationClip` のトラック名と一致しなくなる
- `VectorKeyframeTrack` を回転に使用（`QuaternionKeyframeTrack` が正しい）
- `rotateVRM0()` を VRM 1.0 モデルに適用

### 修正
- `combineSkeletons()` は使用禁止
- 回転は `QuaternionKeyframeTrack` を使用
- `rotateVRM0()` は `metaVersion === '0'` の場合のみ適用

---

## 6. Vosk NULL Pointer SIGSEGV (Issue #43)

### 症状
- stt-webrtc Pod が `CrashLoopBackOff`
- ログに `SIGSEGV: segmentation violation` + `vosk_recognizer_new(0x0, ...)`

### 根本原因
`vosk.NewModel()` がモデルディレクトリ不在時に Go レベルでエラーを返さず、
内部 C ポインタが NULL のまま。後続の `NewRecognizer()` で SIGSEGV。

### 修正
- `WHISPER_ENDPOINT` が設定されている場合は Vosk ロードをスキップ
- `vosk.NewModel()` 後に model validity check を追加

---

## 7. gorilla/websocket Panic on Re-read (Issue #48)

### 症状
- `panic: repeated read on failed websocket connection`
- Pod 再起動ループ

### 根本原因
`ReadMessage()` がエラーを返した後、同じ broken connection で再度
`ReadMessage()` を呼び出す。gorilla/websocket v1.5.3 はこれを panic で処理。

### 修正
```go
if err != nil {
    wf.mu.Lock()
    if wf.conn == conn {
        wf.conn = nil  // broken connection をクリア
    }
    wf.mu.Unlock()
}
```

---

## 8. Artifact Registry Push 403

### 症状
- `docker push` が `403 Forbidden`

### 根本原因
プロジェクト ID の間違い。正しくは `milaos-realtime-avatar-spec`。

### 確認方法
```bash
gcloud config get-value project  # milaos-realtime-avatar-spec であること
```

---

## 9. WebRTC UDP in GKE

### 症状
- WebRTC ICE 接続が `failed` になる

### 根本原因
GKE の Pod ネットワークは NAT 経由のため、WebRTC の UDP ポートに到達できない。

### 修正
- `hostNetwork: true` を Deployment に設定
- `dnsPolicy: ClusterFirstWithHostNet`
- ファイアウォールルール: UDP 10000-65535 を許可

---

## 10. vLLM OOM on T4 (16GB)

### 症状
- vLLM Pod が起動直後に OOM Kill

### 根本原因
CUDA graphs がデフォルトで有効で、T4 の 16GB VRAM に収まらない。

### 修正
- `--enforce-eager` フラグで CUDA graphs を無効化
- `--gpu-memory-utilization 0.85` 以下に制限
- 起動プローブは 20 分以上に設定（モデルロードに時間がかかる）
- `strategy: Recreate` 必須（GPU リソースは共有不可）

---

## 11. Cloud Run → GKE VPC Routing

### 症状
- Cloud Run から GKE ClusterIP に接続不可
- `httpx.ConnectError: All connection attempts failed`

### 根本原因
Cloud Run の VPC connector は `private-ranges-only` モードで RFC1918 アドレスのみ
ルーティング。GKE の ClusterIP (34.118.x.x) は RFC1918 外。

### 修正
- GKE Service に Internal LoadBalancer を設定:
  ```yaml
  metadata:
    annotations:
      networking.gke.io/load-balancer-type: Internal
  ```
- Internal LB は 10.x.x.x のアドレスを取得 → VPC connector 経由でルーティング可能
