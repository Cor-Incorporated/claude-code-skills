#!/bin/bash
# setup.sh — Install claude-code-skills + third-party dependencies
set -euo pipefail

SKILLS_DIR="$HOME/.claude/skills"
RULES_DIR="$HOME/.claude/rules"
HOOKS_DIR="$HOME/.claude/hooks"
SCRIPTS_DIR="$HOME/.claude/scripts"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Claude Code Skills Setup ==="
echo ""

# 1. Copy skills
echo "[1/5] Installing skills..."
for d in "$REPO_DIR"/skills/*/; do
  skill_name=$(basename "$d")
  if [ -d "$SKILLS_DIR/$skill_name" ]; then
    echo "  ↻ $skill_name (updating)"
  else
    echo "  + $skill_name (new)"
  fi
  cp -r "$d" "$SKILLS_DIR/$skill_name"
done

# 2. Copy rules
echo "[2/5] Installing rules..."
mkdir -p "$RULES_DIR"
cp "$REPO_DIR"/rules/*.md "$RULES_DIR/"
echo "  Copied $(ls "$REPO_DIR"/rules/*.md | wc -l | tr -d ' ') rule files"

# 3. Copy hooks
echo "[3/5] Installing hooks..."
mkdir -p "$HOOKS_DIR"
cp "$REPO_DIR"/hooks/*.sh "$HOOKS_DIR/"
cp "$REPO_DIR"/hooks/*.py "$HOOKS_DIR/" 2>/dev/null || true
chmod +x "$HOOKS_DIR"/*.sh
SH_COUNT=$(ls "$REPO_DIR"/hooks/*.sh 2>/dev/null | wc -l | tr -d ' ')
PY_COUNT=$(ls "$REPO_DIR"/hooks/*.py 2>/dev/null | wc -l | tr -d ' ')
echo "  Copied ${SH_COUNT} shell + ${PY_COUNT} python hook scripts"

# 4. Copy scripts
echo "[4/5] Installing scripts..."
mkdir -p "$SCRIPTS_DIR"
for f in "$REPO_DIR"/scripts/*; do
  [ -f "$f" ] && cp "$f" "$SCRIPTS_DIR/"
done
chmod +x "$SCRIPTS_DIR"/*.sh 2>/dev/null || true
echo "  Copied $(ls "$REPO_DIR"/scripts/* 2>/dev/null | wc -l | tr -d ' ') script files"

# 5. Install third-party skills
echo "[5/5] Installing third-party dependencies..."

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
