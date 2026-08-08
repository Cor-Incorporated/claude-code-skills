#!/usr/bin/env bash
# H4 link test: facts.yaml pairs must both exist; prints both values on failure
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FACTS="$ROOT/facts.yaml"
fail=0

if [[ ! -f "$FACTS" ]]; then
  echo "FAIL: facts.yaml missing"
  exit 1
fi

# Minimal parse: for each path-like token after declaration/enforcement keys, require file existence
while IFS= read -r line; do
  if [[ "$line" =~ declaration:[[:space:]]*(.+) ]]; then
    decl="${BASH_REMATCH[1]}"
    decl_path="${decl%%#*}"
  fi
  if [[ "$line" =~ enforcement:[[:space:]]*(.+) ]]; then
    enf="${BASH_REMATCH[1]}"
    # support a+b+c style
    IFS='+' read -ra parts <<<"$enf"
    missing=()
    for p in "${parts[@]}"; do
      p="${p%%#*}"
      p="${p// /}"
      if [[ ! -e "$ROOT/$p" ]]; then
        missing+=("$p")
      fi
    done
    if [[ ! -e "$ROOT/${decl_path}" ]]; then
      echo "FAIL H4 link: declaration missing path=$decl_path enforcement=$enf"
      fail=1
    elif ((${#missing[@]} > 0)); then
      echo "FAIL H4 link: both sides — declaration=$decl_path enforcement_missing=${missing[*]}"
      fail=1
    else
      echo "PASS H4: $decl_path ↔ $enf"
    fi
  fi
done <"$FACTS"

# Ledger wiring presence for hard blocks
for h in git-push-guard protect-branches block-local-hooks-write validate-no-local-hooks; do
  if ! grep -q 'aidd_ledger_append\|aidd-ledger' "$ROOT/hooks/${h}.sh" 2>/dev/null; then
    echo "FAIL H4: hard block $h missing ledger wiring (declaration=CANONICAL enforcement=hook)"
    fail=1
  fi
done

exit "$fail"
