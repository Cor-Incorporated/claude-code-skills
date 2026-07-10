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
echo "[1/9] Installing settings..."
mkdir -p "$CLAUDE_DIR"
cp "$REPO_DIR/settings.json" "$CLAUDE_DIR/settings.json"
echo "  Copied settings.json to $CLAUDE_DIR/settings.json"

# 2. Sanitize local settings overrides
echo "[2/9] Sanitizing local settings overrides..."
bash "$REPO_DIR/scripts/sanitize-local-permissions.sh" \
  "$CLAUDE_DIR/settings.local.json" \
  "$REPO_DIR/.claude/settings.local.json"

# 3. Copy skills
echo "[3/9] Installing skills..."
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
echo "[4/9] Installing rules..."
mkdir -p "$RULES_DIR"
cp "$REPO_DIR"/rules/*.md "$RULES_DIR/"
echo "  Copied $(ls "$REPO_DIR"/rules/*.md | wc -l | tr -d ' ') rule files"

# 5. Copy hooks
echo "[5/9] Installing hooks..."
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
echo "[6/9] Installing scripts..."
mkdir -p "$SCRIPTS_DIR"
for f in "$REPO_DIR"/scripts/*; do
  [ -f "$f" ] && cp "$f" "$SCRIPTS_DIR/"
done
chmod +x "$SCRIPTS_DIR"/*.sh 2>/dev/null || true
echo "  Copied $(ls "$REPO_DIR"/scripts/* 2>/dev/null | wc -l | tr -d ' ') script files"

# 7. Prune retired hooks/scripts/rules + gate state (ADR-006 minimal safety net)
# setup.sh only ever COPIES; nothing else deletes stale deployed files. This
# step is the single mechanism that removes hooks/scripts/rules retired from
# the repo, and cleans up state owned by the gates we removed. Scoped strictly
# to $HOOKS_DIR, $SCRIPTS_DIR, $RULES_DIR and the named state files below —
# never touches anything else under $HOME.
echo "[7/9] Pruning retired hooks/scripts/rules + gate state (ADR-006)..."

# 7a. Deployed hooks not present in the repo hooks/ (excluding repo's _unused/)
if [ -d "$HOOKS_DIR" ]; then
  for f in "$HOOKS_DIR"/*.sh "$HOOKS_DIR"/*.py; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    if [ ! -e "$REPO_DIR/hooks/$base" ]; then
      rm -f "$f"
      echo "  - pruned hook: $base"
    fi
  done
  # gate-modes/ and _unused/ never belong on the deployed side
  rm -rf "$HOOKS_DIR/gate-modes" "$HOOKS_DIR/_unused" "$HOOKS_DIR/__pycache__"
fi

# 7b. Deployed scripts not present in the repo scripts/
if [ -d "$SCRIPTS_DIR" ]; then
  for f in "$SCRIPTS_DIR"/*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    if [ ! -e "$REPO_DIR/scripts/$base" ]; then
      rm -f "$f"
      echo "  - pruned script: $base"
    fi
  done
fi

# 7c. Deployed rules not present in the repo rules/ (incl. stale .bak files)
if [ -d "$RULES_DIR" ]; then
  for f in "$RULES_DIR"/*.md "$RULES_DIR"/*.md.bak; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .bak)
    if [ ! -e "$REPO_DIR/rules/$base" ]; then
      rm -f "$f"
      echo "  - pruned rule: $(basename "$f")"
    fi
  done
fi

# 7d. State owned by retired gates — safe to remove: the gates that wrote
# these files are all deleted, so nothing will recreate or read them.
STATE_DIR="$HOME/.claude/state"
RETIRED_STATE_FILES=(
  "factcheck-status.json"
  "context-budget.json"
  "context-budget-mode.txt"
  "codex-task-gate.json"
  "review-status.json"
  "pr-review-lock.json"
  "pr-review-read.json"
  "pending-review-comments.json"
  "rebase-session.json"
  "pr-gate-diagnostic.log"
  "parallel-team.json"
)
if [ -d "$STATE_DIR" ]; then
  for name in "${RETIRED_STATE_FILES[@]:-}"; do
    [ -z "$name" ] && continue
    if [ -e "$STATE_DIR/$name" ]; then
      rm -f "$STATE_DIR/$name"
      echo "  - pruned state: $name"
    fi
  done
fi

# 8. Sync OpenCode permissions
echo "[8/9] Syncing OpenCode background-safe permissions..."
if [ -f "$OPENCODE_CONFIG" ]; then
  bash "$REPO_DIR/scripts/sync-opencode-background-permissions.sh" "$OPENCODE_CONFIG"
else
  echo "  ↻ OpenCode config not found, skipping sync"
fi

# 9. Install third-party skills
echo "[9/9] Installing third-party dependencies..."

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

# Ensure provider profile directory exists (secrets stay local, never in repo settings.json)
echo ""
echo "Ensuring provider profile directory..."
mkdir -p "$CLAUDE_DIR/providers"
chmod 700 "$CLAUDE_DIR/providers" 2>/dev/null || true
if [ -x "$SCRIPTS_DIR/claude-provider.sh" ]; then
  echo "  Provider switcher: bash ~/.claude/scripts/claude-provider.sh status"
  echo "  Profiles: anthropic (default/subscription) | zai"
  # Non-fatal status for visibility
  bash "$SCRIPTS_DIR/claude-provider.sh" status 2>/dev/null | head -20 || true
else
  echo "  ↻ claude-provider.sh not installed yet"
fi

echo ""
echo "=== Setup Complete ==="
echo "Restart Claude Code to apply changes."
echo ""
echo "Installed: $(ls -d "$SKILLS_DIR"/*/SKILL.md 2>/dev/null | wc -l | tr -d ' ') skills total"
