#!/bin/bash
# =============================================================================
# Auto-Update Third-Party Plugins (SessionStart hook)
# =============================================================================
# Claude Code の plugin sync は公式マーケットプレースのみ自動同期する。
# サードパーティマーケットプレースのプラグインは手動更新が必要なため、
# SessionStart 時にバックグラウンドで自動更新を実行する。
#
# Issue #219: claude-code-harness が v2.18.11 のまま40日間放置され、
# type: "prompt" の Stop hook が無限ループを引き起こした事故の再発防止。
# =============================================================================

set -euo pipefail

CLAUDE_CMD="${CLAUDE_CMD:-claude}"
STATE_DIR="$HOME/.claude/state"
STATE_FILE="$STATE_DIR/plugin-update-last-run.json"
COOLDOWN_HOURS=24

# --- クールダウンチェック ---
# 毎セッションで更新すると遅いので、24時間に1回だけ実行
if [ -f "$STATE_FILE" ]; then
    last_run=$(python3 -c "
import json, sys
from datetime import datetime, timezone
try:
    with open('$STATE_FILE') as f:
        d = json.load(f)
    last = datetime.fromisoformat(d['last_run'])
    now = datetime.now(timezone.utc)
    diff_hours = (now - last).total_seconds() / 3600
    print(f'{diff_hours:.1f}')
except Exception:
    print('999')
" 2>/dev/null)

    if python3 -c "import sys; sys.exit(0 if float('$last_run') < $COOLDOWN_HOURS else 1)" 2>/dev/null; then
        exit 0
    fi
fi

# --- マーケットプレース一覧からサードパーティを抽出 ---
KNOWN_MARKETPLACES="$HOME/.claude/plugins/known_marketplaces.json"
if [ ! -f "$KNOWN_MARKETPLACES" ]; then
    exit 0
fi

third_party_marketplaces=$(python3 -c "
import json
OFFICIAL = {'claude-plugins-official'}
with open('$KNOWN_MARKETPLACES') as f:
    d = json.load(f)
for name in d:
    if name not in OFFICIAL:
        print(name)
" 2>/dev/null)

if [ -z "$third_party_marketplaces" ]; then
    exit 0
fi

# --- マーケットプレースカタログ更新 ---
updated_marketplaces=()
for mp in $third_party_marketplaces; do
    if "$CLAUDE_CMD" plugin marketplace update "$mp" >/dev/null 2>&1; then
        updated_marketplaces+=("$mp")
    fi
done

# --- 対象プラグインの更新 ---
INSTALLED_PLUGINS="$HOME/.claude/plugins/installed_plugins.json"
if [ ! -f "$INSTALLED_PLUGINS" ]; then
    exit 0
fi

updated_plugins=()
skipped_plugins=()

plugin_names=$(python3 -c "
import json
with open('$INSTALLED_PLUGINS') as f:
    d = json.load(f)
OFFICIAL_MP = {'claude-plugins-official'}
for name in d.get('plugins', {}):
    parts = name.split('@')
    if len(parts) == 2 and parts[1] not in OFFICIAL_MP:
        print(name)
" 2>/dev/null)

for plugin in $plugin_names; do
    output=$("$CLAUDE_CMD" plugin update "$plugin" 2>&1) || true
    if echo "$output" | grep -q "updated from"; then
        version_info=$(echo "$output" | grep -o "from [^ ]* to [^ ]*" || echo "unknown")
        updated_plugins+=("$plugin ($version_info)")
    else
        skipped_plugins+=("$plugin")
    fi
done

# --- 状態ファイル更新 ---
mkdir -p "$STATE_DIR"

_join_array() {
    local IFS="|"
    echo "$*"
}

UPDATED_MP=$(_join_array "${updated_marketplaces[@]+"${updated_marketplaces[@]}"}")
UPDATED_PL=$(_join_array "${updated_plugins[@]+"${updated_plugins[@]}"}")

python3 -c "
import json
from datetime import datetime, timezone
mp = [x for x in '${UPDATED_MP}'.split('|') if x]
pl = [x for x in '${UPDATED_PL}'.split('|') if x]
data = {
    'last_run': datetime.now(timezone.utc).isoformat(),
    'updated_marketplaces': mp,
    'updated_plugins': pl
}
with open('$STATE_FILE', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null

# --- ステータス出力 ---
if [ ${#updated_plugins[@]} -gt 0 ]; then
    echo "🔄 プラグイン更新: ${updated_plugins[*]}" >&2
    echo "⚠️ 次回セッション再起動で適用されます" >&2
else
    echo "✅ サードパーティプラグインは最新です" >&2
fi
