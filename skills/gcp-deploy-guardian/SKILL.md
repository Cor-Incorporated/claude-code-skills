---
name: gcp-deploy-guardian
description: "Prevent GCP deployment failures by validating Docker builds, Cloud Run deploys, and GKE rollouts. Triggers on: docker build, docker push, gcloud run deploy, kubectl apply, Dockerfile/cloudbuild.yaml/nginx.conf edits. Catches arm64-amd64 platform mismatch, Mixed Content from http:// build args, VAD/WASM asset 404s, nginx MIME breakage. Use for all Apple Silicon to GCP deploy workflows. Do NOT use for local-only Docker builds, non-GCP deployments, or application logic changes."
allowed-tools: [Read, Bash, Grep, Glob, WebFetch]
---

# GCP Deploy Guardian

Auto-activate on GCP deploy operations. Prevent known production incidents (Issue #40, #43, #45, #47, #48).

## Trigger Conditions

Activate when detecting:
- `docker build` / `docker push` commands
- `gcloud run deploy` commands
- `kubectl apply` / `kubectl set image` commands
- `cloudbuild.yaml` / `Dockerfile` / `nginx.conf` / `vite.config.ts` edits

## Pre-Deploy Checks (Run ALL Before Build)

<important if="building Docker images for GCP deployment or running docker build on Apple Silicon">
### 1. Platform Verification (CRITICAL)

Verify `--platform linux/amd64` on every Docker build from Apple Silicon.

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/pre-deploy-check.sh "docker build ... -t image:tag context/"
```

After push, inspect the manifest:
```bash
docker manifest inspect <image:tag> | grep architecture
# Must contain "amd64"
```

**Failure mode**: arm64 image -> GKE `ImagePullBackOff` (9h outage, Issue #47), Cloud Run deploy rejection.
</important>

<important if="auditing Docker build args or cloudbuild.yaml for http:// URLs">
### 2. Build Arg Audit

Reject any `http://` URL in `--build-arg` or `cloudbuild.yaml`.

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/pre-deploy-check.sh "docker build --build-arg URL=..."
```

**Failure mode**: `http://` baked into SPA bundle -> browser blocks as Mixed Content -> feature fully broken (Issue #40).
</important>

<important if="building Vite SPA for GCP deployment with VAD/ONNX/WASM assets">
### 3. SPA Build Checks (Vite Only)

| Check | Why |
|-------|-----|
| `vite-plugin-static-copy` enabled | VAD/ONNX assets missing -> 404 (Issue #45) |
| `onnxWASMBasePath: '/'` set | WASM lookup fails at `/assets/` |
| `VITE_MILAOS_SESSION_WS_URL` provided | Falls back to `localhost:8080` |
| `VITE_MILAOS_STT_HTTP_URL` NOT provided | Mixed Content source |
</important>

<important if="configuring nginx.conf MIME types or fixing .mjs/.wasm/.onnx 404 errors">
### 4. nginx MIME Types

```nginx
# CORRECT: location-level default_type
location ~* \.mjs$ { default_type application/javascript; }
location ~* \.wasm$ { default_type application/wasm; }
location ~* \.onnx$ { default_type application/octet-stream; }

# WRONG: server-level types {} destroys entire MIME table
server { types { } }  # NEVER
```
</important>

<important if="verifying a Cloud Run SPA deployment for Mixed Content or missing assets">
## Post-Deploy Verification

### Cloud Run (SPA)
```bash
./scripts/verify-spa-deploy.sh --service <service-name>
```
- HTTP 200 response
- No `http://` in bundle: `curl -sL <url>/assets/*.js | grep -oE 'http://[a-zA-Z0-9._-]+' | sort -u`
- VAD assets return 200: `/ort-wasm-simd-threaded.mjs`, `/silero_vad_legacy.onnx`, `/vad.worklet.bundle.min.js`
- WebSocket/API connection succeeds
</important>

<important if="verifying a Cloud Run API deployment or checking healthz endpoint">
### Cloud Run (API)
```bash
curl -s -o /dev/null -w "%{http_code}" https://<api-url>/v1/healthz  # Must be 200
gcloud run services logs read <service> --region <region> --limit 20  # No errors
```
</important>

<important if="verifying a GKE pod deployment or checking pod status">
### GKE (Pod/Service)
```bash
kubectl get pods -n <ns> -l app=<app> -o wide          # Must be Running
kubectl logs -n <ns> -l app=<app> --tail=20             # No panic/SIGSEGV
curl -s -w "%{http_code}" http://<lb-ip>:<port>/healthz # Reachable
```
</important>

<important if="diagnosing GCP deploy errors like ImagePullBackOff, Mixed Content, WASM 404, or push 403">
## Error Handling

| Error | Cause | Fix |
|-------|-------|-----|
| `ImagePullBackOff` | arm64 image on amd64 node | Rebuild with `--platform linux/amd64` |
| Mixed Content block | `http://` in build args | Remove `http://` args, use HTTPS only |
| WASM/ONNX 404 | Missing static copy plugin | Enable `vite-plugin-static-copy` |
| `.mjs` not loading | Wrong MIME type | Use location-level `default_type` |
| Push 403 | Wrong project | Use `milaos-realtime-avatar-spec` |
</important>

## Prohibited Patterns

```
NEVER  docker build without --platform linux/amd64 (Apple Silicon)
NEVER  http:// in VITE_* build args
NEVER  server-level types {} in nginx.conf
NEVER  VRMUtils.combineSkeletons()
NEVER  deploy without docker manifest inspect
NEVER  report deploy complete without running verification
NEVER  guess project ID (confirm: milaos-realtime-avatar-spec)
```

## Known Traps

Full details in `references/known-traps.md`.

## Skill Integration

| Skill | When |
|-------|------|
| **webapp-testing** | Post-deploy browser smoke test |
| **security-review** | Dockerfile/K8s manifest/nginx.conf changes |
| **code-reviewer** | cloudbuild.yaml/Dockerfile changes |
| **build-fix** | Post-deploy build errors |
