#!/bin/bash
# setup.sh — Install claude-code-skills + third-party dependencies
set -euo pipefail

SKILLS_DIR="$HOME/.claude/skills"
RULES_DIR="$HOME/.claude/rules"
HOOKS_DIR="$HOME/.claude/hooks"
SCRIPTS_DIR="$HOME/.claude/scripts"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Branch guard (CC-D3 / ADR-006 rewind prevention):
# main historically carried ~63 hook registrations. Copying from non-develop
# rewinds the minimal safety net. Canonical deploy branch is develop only.
# See docs/CANONICAL-STATE.md.
current_branch="$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || true)"
if [ "$current_branch" != "develop" ]; then
  echo "develop 以外から setup 禁止 (current: ${current_branch:-unknown})"
  echo "  Checkout develop and re-run. Ref: docs/CANONICAL-STATE.md"
  exit 1
fi

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
chmod +x "$HOOKS_DIR"/*.sh
echo "  Copied $(ls "$REPO_DIR"/hooks/*.sh | wc -l | tr -d ' ') hook scripts"

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
if [ ! -d "$SKILLS_DIR/gstack" ]; then
  echo "  + gstack (cloning from garrytan/gstack)..."
  git clone https://github.com/garrytan/gstack.git "$SKILLS_DIR/gstack"
  cd "$SKILLS_DIR/gstack" && ./setup
  ~/.claude/skills/gstack/bin/gstack-config set telemetry off
  cd "$REPO_DIR"
  echo "  ✅ gstack installed (telemetry disabled)"
else
  echo "  ↻ gstack (already installed, run /gstack-upgrade to update)"
fi

# ui-ux-pro-max
if ! command -v uipro &>/dev/null; then
  echo "  + ui-ux-pro-max (installing via npm)..."
  npm install -g uipro-cli
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
