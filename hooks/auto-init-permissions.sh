#!/bin/bash
# =============================================================================
# Auto-Initialize Project Permissions (SessionStart hook)
# =============================================================================
# プロジェクトの技術スタックを検出し、.claude/settings.local.json に
# 適切なワイルドカード permissions を自動生成する。
#
# - settings.local.json が既に存在する場合はスキップ（上書きしない）
# - 複数スタックの検出に対応（Python + Node + Go + Infra）
# - テンプレートは ~/.claude/templates/ に配置
# =============================================================================

set -euo pipefail

LOCAL_SETTINGS=".claude/settings.local.json"
TEMPLATES_DIR="$HOME/.claude/templates"

# 既に存在する場合はスキップ
if [ -f "$LOCAL_SETTINGS" ]; then
    exit 0
fi

# .claude ディレクトリがなければ作成
mkdir -p .claude

# --- スタック検出 ---
detected=()

# Python (root or subdirectory)
if find . -maxdepth 2 -name "pyproject.toml" -o -name "requirements.txt" -o -name "setup.py" -o -name "Pipfile" 2>/dev/null | grep -q .; then
    detected+=("python")
fi

# Node.js (root or subdirectory)
if find . -maxdepth 2 -name "package.json" -not -path "*/node_modules/*" 2>/dev/null | grep -q .; then
    detected+=("node")
fi

# Go (root or subdirectory)
if find . -maxdepth 2 -name "go.mod" 2>/dev/null | grep -q .; then
    detected+=("go")
fi

# Infra (Docker, Terraform, k8s)
if find . -maxdepth 2 -name "docker-compose.yml" -o -name "docker-compose.yaml" -o -name "Dockerfile" 2>/dev/null | grep -q . || \
   [ -d "terraform" ] || [ -d "k8s" ] || [ -d "kubernetes" ]; then
    detected+=("infra")
fi

# 何も検出できなかった場合
if [ ${#detected[@]} -eq 0 ]; then
    # 最小限の設定を作成
    cat > "$LOCAL_SETTINGS" <<'EOF'
{
  "permissions": {
    "allow": []
  }
}
EOF
    echo "[permissions] No stack detected. Created minimal settings." >&2
    exit 0
fi

# --- テンプレートをマージ ---
# jq で複数テンプレートの allow 配列をマージ
merged_allows="[]"

for stack in "${detected[@]}"; do
    template="$TEMPLATES_DIR/${stack}.json"
    if [ -f "$template" ]; then
        stack_allows=$(jq -r '.permissions.allow // []' "$template")
        merged_allows=$(echo "$merged_allows" "$stack_allows" | jq -s '.[0] + .[1] | unique')
    fi
done

# WebFetch ドメインも追加
merged_allows=$(echo "$merged_allows" | jq '. + [
    "WebFetch(domain:github.com)",
    "WebFetch(domain:docs.cloud.google.com)"
] | unique')

# settings.local.json を生成
jq -n --argjson allows "$merged_allows" '{
    permissions: {
        allow: $allows
    }
}' > "$LOCAL_SETTINGS"

echo "[permissions] Auto-initialized for: ${detected[*]} ($(echo "$merged_allows" | jq length) rules)" >&2
