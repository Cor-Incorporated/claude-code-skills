#!/bin/bash
# test-cleanup-prunes-pending.sh
# gate-modes/cleanup.sh must delete pending-review-comments.json whose PR is
# merged/closed (previously it cleaned only lock + review-status).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLEANUP="$REPO_ROOT/hooks/gate-modes/cleanup.sh"
PASS=0; FAIL=0
ok(){ echo "  ok: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
WORK="$(mktemp -d)"; GHBIN="$(mktemp -d)"
trap 'rm -rf "$WORK" "$GHBIN"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
git -C "$WORK" init -q
git -C "$WORK" remote add origin https://github.com/owner/repo.git
STATE_DIR="$WORK/.claude/state"; mkdir -p "$STATE_DIR"
PENDING="$STATE_DIR/pending-review-comments.json"
cat > "$PENDING" <<'JSON'
{"pr":"999","repo":"owner/repo","head_sha":"abc","total":1,"critical":1,"high":0}
JSON
cat > "$GHBIN/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"pulls/"*) echo "closed" ;;
  *) echo "" ;;
esac
EOF
chmod +x "$GHBIN/gh"

(cd "$WORK" && CLAUDE_PROJECT_DIR="$WORK" PATH="$GHBIN:$PATH" bash "$CLEANUP") >/dev/null 2>&1 || true
[ ! -f "$PENDING" ] && ok "merged-PR pending purged by cleanup" || bad "pending still present"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
