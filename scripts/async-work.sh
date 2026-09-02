#!/usr/bin/env bash
# 未完了の非同期作業の台帳 — ターン境界で持ち越しを機械照合するための登録簿.
#
# Issue: Cor-Incorporated/aidd-governance#96（進行中の非同期作業を報告して停止した）
#        Cor-Incorporated/aidd-governance#95（レーンが正常終了で減るのに補充されない）
#
# 起点事故 (2026-08-27):
#   監督は Alpha CD run 33091489486 が in_progress (success=17/25 step) の状態で
#   「進んでいる」と報告してターンを終えた。11 分後に CD は失敗した。セッションは
#   ターン間で実行されないため、失敗を受け取る主体が存在しなかった。ユーザーが
#   翌朝指摘するまで 7 時間 25 分だれも気づかなかった。
#
#   同日、実装レーンは 12 本が `exited with code 0` で正常終了したが、空いた枠は
#   補充されなかった。ユーザーが 5 回以上「レーンが減っている」と指摘し、そのたびに
#   監督が手で補充した。レーンは壊れていない。完了イベントを「報告する対象」として
#   扱い「補充する契機」として扱っていなかった。
#
# --- この台帳が持つ事実 --------------------------------------------------------
#   1 件 = 「ターンをまたいで生き続ける作業」1 つ。kind は cd-run / lane / generic。
#   register した時点で unresolved。resolve で終端する。
#
#   **resolve は conclusion を要求する。** status=in_progress / queued / running を
#   終端の根拠として受け付けない。#96 の核心は「in_progress を根拠に前進と報告した」
#   ことなので、そこを台帳側で拒否する。
#
# --- この台帳が持たない機能（過大主張しない） ----------------------------------
#   常駐しない。ポーリングしない。ターンが終わった後に何かを検知することはできない。
#   本スクリプトは「今この瞬間に未解決の持ち越しが何件あるか」を答えるだけであり、
#   それを読んで止めるのは hooks/aidd-turn-boundary-stop.sh（Stop hook）である。
#   ターンが正当に終わった後の無人区間を刈り取るには常駐 daemon が要る。要らないと
#   書いてはならない。
set -uo pipefail

STATE_DIR="${AIDD_ASYNC_STATE:-$HOME/.claude/state/async-work}"

die() { printf 'async-work: %s\n' "$*" >&2; exit 2; }

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-120; }

cmd_register() {
  local id="" kind="generic" detail="" owner="" check_cmd="" source="manual"
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) id="${2:-}"; shift 2 ;;
      --kind) kind="${2:-}"; shift 2 ;;
      --detail) detail="${2:-}"; shift 2 ;;
      --owner) owner="${2:-}"; shift 2 ;;
      --check-cmd) check_cmd="${2:-}"; shift 2 ;;
      --source) source="${2:-}"; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [ -n "$id" ] || die "--id is required"
  case "$kind" in
    cd-run | lane | generic) ;;
    *) die "--kind must be cd-run|lane|generic (got: $kind)" ;;
  esac
  mkdir -p "$STATE_DIR" 2>/dev/null || die "cannot create $STATE_DIR"
  local file="$STATE_DIR/$(slug "$id").json"
  # 既に解決済みの id を再登録した場合は新しい持ち越しとして開き直す。
  python3 - "$file" "$id" "$kind" "$detail" "$owner" "$check_cmd" "$source" <<'PY' \
    || die "register failed"
import json, sys, time
path, ident, kind, detail, owner, check_cmd, source = sys.argv[1:8]
json.dump({
    "id": ident, "kind": kind, "detail": detail, "owner": owner,
    "check_cmd": check_cmd, "source": source,
    "registered_ts": int(time.time()), "resolved_ts": 0,
    "resolved": False, "conclusion": "",
}, open(path, "w"), ensure_ascii=False)
PY
  printf '%s\n' "$file"
}

# conclusion として受け付けない語。#96 の「status=in_progress を前進の根拠に
# してはならない」を台帳側で強制する点であり、緩めてはならない。
NON_TERMINAL="in_progress queued running pending waiting requested none unknown"

cmd_resolve() {
  local id="" conclusion=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) id="${2:-}"; shift 2 ;;
      --conclusion) conclusion="${2:-}"; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [ -n "$id" ] || die "--id is required"
  [ -n "$conclusion" ] || die "--conclusion is required (完了は conclusion の読み出しでしか証明できない)"
  local lowered
  lowered="$(printf '%s' "$conclusion" | tr '[:upper:]' '[:lower:]')"
  for word in $NON_TERMINAL; do
    if [ "$lowered" = "$word" ]; then
      die "conclusion='$conclusion' は終端ではない。status=in_progress を根拠に完了扱いしてはならない (#96)。gh run view --json conclusion で読み出すこと。"
    fi
  done
  local file="$STATE_DIR/$(slug "$id").json"
  [ -f "$file" ] || die "未登録の id: $id"
  python3 - "$file" "$conclusion" <<'PY' || die "resolve failed"
import json, sys, time
path, conclusion = sys.argv[1:3]
row = json.load(open(path, encoding="utf-8"))
row["resolved"] = True
row["resolved_ts"] = int(time.time())
row["conclusion"] = conclusion
json.dump(row, open(path, "w"), ensure_ascii=False)
PY
  printf 'resolved %s (%s)\n' "$id" "$conclusion"
}

# 未解決一覧を JSON 配列で返す。owner が宣言されているものは「次に誰がいつ確認
# するか」が書かれているとみなし、owned=true として区別する。
# 未解決一覧。**test 系 source は既定で除く。**
#
# ここが唯一の濾過点である。停止判定 (aidd-turn-boundary-stop.sh) も次ターン冒頭の
# 照合 (aidd-carryover-reconcile.sh) も本コマンドを読むので、両方が一度に揃う。
# 消費側それぞれに濾過を書くと、片方だけ直る形（本リポが繰り返している宣言↔実体の
# 二重管理）になる。
#
# 除くのは「見えなくする」ためではない。`list` には出るし、`--include-test` で
# いつでも出せる。停止判定の入力から外すだけである。
cmd_unresolved() {
  local include_test=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --include-test) include_test=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  python3 - "$STATE_DIR" "$include_test" <<'PY'
import glob, json, os, sys
state, include_test = sys.argv[1], sys.argv[2] == "1"
rows = []
for path in sorted(glob.glob(os.path.join(state, "*.json"))):
    try:
        row = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError):
        continue
    if row.get("resolved"):
        continue
    source = str(row.get("source") or "")
    if not include_test and (source == "test" or source.startswith("test:")):
        continue
    row["owned"] = bool(str(row.get("owner") or "").strip())
    rows.append(row)
print(json.dumps(rows, ensure_ascii=False))
PY
}

cmd_list() {
  python3 - "$STATE_DIR" <<'PY'
import glob, json, os, sys
state = sys.argv[1]
for path in sorted(glob.glob(os.path.join(state, "*.json"))):
    try:
        row = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError):
        continue
    print("%-10s %-8s %-28s %s" % (
        "resolved" if row.get("resolved") else "OPEN",
        row.get("kind", ""), row.get("id", "")[:28],
        row.get("conclusion") or row.get("detail", "")))
PY
}

cmd_clear() {
  # テスト用。実運用では未解決を消さないこと（消すと持ち越しが見えなくなる）。
  [ "${AIDD_ASYNC_ALLOW_CLEAR:-0}" = "1" ] || die "clear は AIDD_ASYNC_ALLOW_CLEAR=1 が要る"
  rm -f "$STATE_DIR"/*.json 2>/dev/null || true
}

usage() {
  cat >&2 <<'EOF'
usage: async-work.sh <register|resolve|unresolved|list|clear> [flags]

  register --id <id> [--kind cd-run|lane|generic] [--detail <text>]
           [--owner <次に確認する主体>] [--check-cmd <確認コマンド>] [--source <who>]
  resolve  --id <id> --conclusion <success|failure|cancelled|...>
           in_progress / queued / running 等は終端として受け付けない (#96)
  unresolved [--include-test]
               未解決を JSON 配列で。test 系 source は既定で除く
               （停止判定の入力から外すため。list には出る）
  list         人間向け一覧

env:
  AIDD_ASYNC_STATE   台帳ディレクトリ (既定: ~/.claude/state/async-work)
EOF
  exit 2
}

case "${1:-}" in
  register) shift; cmd_register "$@" ;;
  resolve) shift; cmd_resolve "$@" ;;
  unresolved) shift; cmd_unresolved "$@" ;;
  list) shift; cmd_list "$@" ;;
  clear) shift; cmd_clear "$@" ;;
  *) usage ;;
esac
