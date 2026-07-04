#!/bin/bash
# setup.sh — Install claude-code-skills + third-party dependencies
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SKILLS_DIR="$HOME/.claude/skills"
RULES_DIR="$HOME/.claude/rules"
HOOKS_DIR="$HOME/.claude/hooks"
SCRIPTS_DIR="$HOME/.claude/scripts"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.jsonc"

echo "=== Claude Code Skills Setup ==="
echo ""

# 1. Copy settings
# NOTE: settings.json is overwritten from master on every setup. Store env vars
# (API tokens, model config, base URL) in settings.local.json — Claude Code merges
# settings.json + settings.local.json (local takes precedence), and the sanitize
# step below preserves settings.local.json's env (only strips permissions).
echo "[1/8] Installing settings..."
mkdir -p "$CLAUDE_DIR"
cp "$REPO_DIR/settings.json" "$CLAUDE_DIR/settings.json"
echo "  Copied settings.json to $CLAUDE_DIR/settings.json"

# 2. Sanitize local settings overrides
echo "[2/8] Sanitizing local settings overrides..."
bash "$REPO_DIR/scripts/sanitize-local-permissions.sh" \
  "$CLAUDE_DIR/settings.local.json" \
  "$REPO_DIR/.claude/settings.local.json"

# 3. Copy skills
echo "[3/8] Installing skills..."
for d in "$REPO_DIR"/skills/*/; do
  skill_name=$(basename "$d")
  if [ -d "$SKILLS_DIR/$skill_name" ]; then
    echo "  ↻ $skill_name (updating)"
  else
    echo "  + $skill_name (new)"
  fi
  cp -r "$d" "$SKILLS_DIR/$skill_name"
done

# 4. Copy rules
echo "[4/8] Installing rules..."
mkdir -p "$RULES_DIR"
cp "$REPO_DIR"/rules/*.md "$RULES_DIR/"
echo "  Copied $(ls "$REPO_DIR"/rules/*.md | wc -l | tr -d ' ') rule files"

# 5. Copy hooks
echo "[5/8] Installing hooks..."
mkdir -p "$HOOKS_DIR"
cp "$REPO_DIR"/hooks/*.sh "$HOOKS_DIR/"
cp "$REPO_DIR"/hooks/*.py "$HOOKS_DIR/" 2>/dev/null || true
chmod +x "$HOOKS_DIR"/*.sh
if [ -d "$REPO_DIR/hooks/gate-modes" ]; then
  mkdir -p "$HOOKS_DIR/gate-modes"
  cp "$REPO_DIR"/hooks/gate-modes/*.sh "$HOOKS_DIR/gate-modes/"
  chmod +x "$HOOKS_DIR"/gate-modes/*.sh
fi
SH_COUNT=$(ls "$REPO_DIR"/hooks/*.sh 2>/dev/null | wc -l | tr -d ' ')
PY_COUNT=$(ls "$REPO_DIR"/hooks/*.py 2>/dev/null | wc -l | tr -d ' ')
GATE_COUNT=$(ls "$REPO_DIR"/hooks/gate-modes/*.sh 2>/dev/null | wc -l | tr -d ' ')
echo "  Copied ${SH_COUNT} shell + ${PY_COUNT} python hook scripts + ${GATE_COUNT} gate-mode modules"

# 6. Copy scripts
echo "[6/8] Installing scripts..."
mkdir -p "$SCRIPTS_DIR"
for f in "$REPO_DIR"/scripts/*; do
  [ -f "$f" ] && cp "$f" "$SCRIPTS_DIR/"
done
chmod +x "$SCRIPTS_DIR"/*.sh 2>/dev/null || true
echo "  Copied $(ls "$REPO_DIR"/scripts/* 2>/dev/null | wc -l | tr -d ' ') script files"

# 7. Sync OpenCode permissions
echo "[7/8] Syncing OpenCode background-safe permissions..."
if [ -f "$OPENCODE_CONFIG" ]; then
  bash "$REPO_DIR/scripts/sync-opencode-background-permissions.sh" "$OPENCODE_CONFIG"
else
  echo "  ↻ OpenCode config not found, skipping sync"
fi

# 8. Install third-party skills
echo "[8/8] Installing third-party dependencies..."

# gstack
# --- ctx7 (Context7 CLI) ---
if ! command -v ctx7 &>/dev/null; then
  echo "  + ctx7 (installing globally)..."
  npm install -g ctx7@0.3.6
  echo "  ✅ ctx7 installed"
else
  echo "  ↻ ctx7 (already installed: $(ctx7 --version 2>/dev/null || echo 'unknown'))"
fi

if [ ! -d "$SKILLS_DIR/gstack" ]; then
  echo "  + gstack (cloning from garrytan/gstack)..."
  git clone https://github.com/garrytan/gstack.git "$SKILLS_DIR/gstack"
  cd "$SKILLS_DIR/gstack" && git checkout f4bbfaa5bdfd2d6ce59541c2145432febde57fed && ./setup  # v0.11.10.0
  ~/.claude/skills/gstack/bin/gstack-config set telemetry off
  cd "$REPO_DIR"
  echo "  ✅ gstack installed (telemetry disabled)"
else
  echo "  ↻ gstack (already installed, run /gstack-upgrade to update)"
fi

# ui-ux-pro-max
if ! command -v uipro &>/dev/null; then
  echo "  + ui-ux-pro-max (installing via npm)..."
  npm install -g uipro-cli@2.2.3
  cd "$HOME/.claude" && uipro init --ai claude
  # Fix nested directory if created
  if [ -d "$HOME/.claude/.claude/skills/ui-ux-pro-max" ]; then
    cp -r "$HOME/.claude/.claude/skills/ui-ux-pro-max" "$SKILLS_DIR/ui-ux-pro-max"
    rm -rf "$HOME/.claude/.claude"
  fi
  cd "$REPO_DIR"
  echo "  ✅ ui-ux-pro-max installed"
else
  echo "  ↻ ui-ux-pro-max (already installed)"
fi

echo ""
echo "=== Setup Complete ==="
echo "Restart Claude Code to apply changes."
echo ""
echo "Installed: $(ls -d "$SKILLS_DIR"/*/SKILL.md 2>/dev/null | wc -l | tr -d ' ') skills total"
