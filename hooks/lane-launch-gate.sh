#!/usr/bin/env bash
# PreToolUse(Bash): レーン発射ゲート — 基点規律 (#91) と同族反復上限 (#88).
#
# Issue: Cor-Incorporated/aidd-governance#91, #88
#
# 起点:
#   #91 — worktree の基点が数時間前の develop のまま 4 レーンを同時起動し、
#         feat/l-s6-api が develop 既存の 4 ファイルを独立に再実装。マージ時に
#         add/add 4 件、delivery_incident_judgment_store.go は develop 650 行 対
#         ブランチ 290 行でブランチ側を全損。
#   #88 — 宣言済み Terraform 移行戦略と温存済み前提の乖離を検出せず、同一境界の
#         "exact" 修理を 16 サイクル継続。再裁定 0 回。
#
#   2026-09-02 実測: 当日 11 worktree のうち 10 本が behind=0 だったのは規律では
#   なく時刻である。7:45 に同一 head から一斉起動したため。3 PR が着地した後に
#   起動した 1 本（verify/cluster-d）だけが 6 commit 遅れていた。並列度と経過
#   時間に比例してずれる機構は生きている。
#
# --- なぜ PreToolUse(Bash) なのか（スパイクの実測結果） -----------------------
# Claude Code には worktree 作成専用の `WorktreeCreate` イベントがあるが、その
# 契約は「既定の git 挙動を置き換える」= stdout にパスを 1 本だけ出し、非ゼロ
# 終了で作成を中止する、という **replace セマンティクス**である。既に
# claude-code-harness plugin が matcher `*` で占有しており、同じイベントに 2 本目
# を積むと「どちらのパスが採用されるか」が未定義になる。助言的ゲートを置く場所
# ではない。
#
# そして 2026-09-02 の当日 11 worktree はいずれも `worktree-info.json` を持た
# ない = `WorktreeCreate` は発火していない。全て Bash の `git worktree add` で
# 作られた。したがって **本 hook は当日の 11/11 を被覆する**。
#
# --- 被覆しないもの（正直に書く） ---------------------------------------------
#   1. `WorktreeCreate` 経由（Agent team が runtime に作らせる形）。上記の理由で
#      本 hook は届かない。届かせるには replace セマンティクスの hook を書く
#      必要があり、既存 plugin との調停が要る。本 PR の範囲外。
#   2. スクリプト内部の `git worktree add`（codex-parallel.sh など）。PreToolUse
#      が見るのは Claude が発行したツール呼び出しの文字列であって、その中で
#      起動されるプロセスではない。経路 C は wrapper 側の既存ゲート
#      (scripts/codex-parallel.sh) が担当する。**両者は排他であり二重発火しない**
#      — テストで実測している。
#   3. zsh の `git()` 関数経由のガード（~/.zshrc → .agent-guards/
#      git-worktree-boundary-guard.sh）は **パス境界**のみを見る。基点は見ない。
#      機能重複はない。
#
# --- 誤検知の設計方針（protect-branches とは意図的に別方針）-------------------
# protect-branches.sh は tail-risk 型なので「既定は網、データ文脈だけ除外」と
# している。本 hook は違う。誤ブロック = レーン 1 本の発射が止まるだけで可逆、
# 見逃し = 重複実装の手戻りで、これも可逆。**どちらも不可逆ではない。**
# したがって網を先に張らず、`git worktree add` の **実行**をコマンド位置で
# 同定したときだけ判定する。`git commit -m "worktree add"` や grep パターンでは
# 発火しない。判定は git-worktree-boundary-guard.sh と同じくトークン位置で行う。
#
# --- ADR-006 入場料 -----------------------------------------------------------
#   台帳: 発火は scripts/lane-basepoint-check.sh / repair-loop-breaker.sh 経由で
#         guard-ledger.jsonl へ届く。本 hook 自身も skip 理由を measure で残す。
#   陰性テスト: tests/test-lane-launch-gate.sh（欠陥注入で red を実測）
#   廃止条件: 誤ブロック率 > 30%/四半期 → LANE_BEHIND_LIMIT を緩める。
#             発火ゼロ 90 日 → 降格候補（H6 共通様式）。
set -uo pipefail

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
[ -f "$_LEDGER_LIB" ] || _LEDGER_LIB="$HOME/.claude/hooks/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"

# 依存スクリプトの解決順。setup.sh は scripts/* を ~/.claude/scripts/ へ配る。
_resolve() {
  local name="$1" c
  for c in \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    "$HOME/Developer/claude-code-skills/scripts/$name"
  do
    [ -f "$c" ] && printf '%s' "$c" && return 0
  done
  return 1
}
BASEPOINT_SH="$(_resolve lane-basepoint-check.sh || true)"
# #88 の判定は aidd-governance が正本。ここでは呼ぶだけで再実装しない
# （両側に判定を置いたらそれ自体が宣言↔実体の二重管理になる）。
BREAKER_SH="${LANE_BREAKER_SH:-}"
if [ -z "$BREAKER_SH" ]; then
  for c in "$HOME/Developer/aidd-governance/scripts/repair-loop-breaker.sh" \
           "$HOME/.claude/scripts/repair-loop-breaker.sh"; do
    [ -f "$c" ] && BREAKER_SH="$c" && break
  done
fi

input="$(cat 2>/dev/null || true)"
command -v python3 >/dev/null 2>&1 || exit 0

emit_allow() { exit 0; }
emit_deny() {
  # PreToolUse の exit 2 = 実行を拒否し、stderr をエージェントへ返す。
  printf '%s\n' "$1" >&2
  exit 2
}

cmd="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit(0)
ti = d.get("tool_input") or {}
print(ti.get("command") or ti.get("cmd") or d.get("command") or "")
' 2>/dev/null || true)"
[ -n "$cmd" ] || emit_allow

# --- `git worktree add` の *実行* をコマンド位置で同定する --------------------
# 出力は 1 行 1 件 "<repo>\x1f<start-ref>\x1f<target-path>"。
# 区切りにタブを使わない: タブは IFS の空白類なので `read` が連続区切りを 1 つへ
# 潰し、start が空のとき target が start へずれる（実測で踏んだ）。
# git-worktree-boundary-guard.sh と同じく、`worktree` の直後が `add` であること
# をトークン位置で要求する。文字列に含まれるだけでは発火しない。
parsed="$(python3 - "$cmd" <<'PY' 2>/dev/null || true
import re, shlex, sys

cmd = sys.argv[1]

# データ文脈のセグメントは落とす。ここは「積極的に同定できたものだけ」。
DATA_ONLY = {"grep", "egrep", "fgrep", "rg", "ag", "echo", "printf", "cat",
             "tee", "head", "tail", "sed", "awk"}
RUNNER = {"env", "sudo", "doas", "nohup", "time", "timeout", "stdbuf", "nice",
          "setsid", "command", "exec", "xargs", "bash", "sh", "zsh"}
# -C は値を取る。--git-dir なども同様に読み飛ばす。
TAKES_VALUE = {"-C", "--git-dir", "--work-tree", "--namespace", "-c", "--config"}

out = []
for seg in re.split(r"[;&|\n]+", cmd):
    seg = seg.strip()
    if not seg:
        continue
    try:
        toks = shlex.split(seg)
    except ValueError:
        continue
    i = 0
    # runner と VAR=... を読み飛ばして最初のコマンド語を得る
    while i < len(toks) and (toks[i] in RUNNER or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[i])):
        i += 1
    if i >= len(toks):
        continue
    if toks[i] in DATA_ONLY:
        continue
    if toks[i] != "git" and not toks[i].endswith("/git"):
        continue
    i += 1
    repo = "."
    # git のグローバルオプション
    while i < len(toks) and toks[i].startswith("-"):
        if toks[i] in TAKES_VALUE and i + 1 < len(toks):
            if toks[i] == "-C":
                repo = toks[i + 1]
            i += 2
        else:
            i += 1
    # ここが「worktree」で、その次が「add」でなければ対象外
    if i + 1 >= len(toks) or toks[i] != "worktree" or toks[i + 1] != "add":
        continue
    rest = toks[i + 2:]

    start = ""
    positional = []
    j = 0
    while j < len(rest):
        t = rest[j]
        if t == "--":
            positional.extend(rest[j + 1:]); break
        if t in ("-b", "-B", "--orphan"):
            # -b <new-branch> — 起点は次の positional（省略時は HEAD）
            j += 2; continue
        if t.startswith("-"):
            j += 1; continue
        positional.append(t); j += 1
    # positional = [<path>, <commit-ish>?]
    target = positional[0] if positional else ""
    if len(positional) >= 2:
        start = positional[1]
    out.append("%s\x1f%s\x1f%s" % (repo, start, target))

for line in out:
    print(line)
PY
)"
[ -n "$parsed" ] || emit_allow

note_ledger() {
  declare -F aidd_ledger_append_record >/dev/null 2>&1 || return 0
  local row
  row="$(python3 - "$1" "$2" "$3" <<'PY' 2>/dev/null || true
import json, sys
event, rule, detail = sys.argv[1:4]
print(json.dumps({"component": "H11", "event": event, "rule": rule,
                  "detail": detail, "subject": {"gate": "lane-launch-gate"}},
                 ensure_ascii=False, separators=(",", ":")))
PY
)"
  [ -n "$row" ] && aidd_ledger_append_record "$row" "claude-code" >/dev/null 2>&1 || true
}

while IFS=$'\x1f' read -r repo start target; do
  [ -n "$repo" ] || continue
  [ -d "$repo" ] || continue
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue

  # --- (1) #91 基点規律 -------------------------------------------------------
  if [ -n "$BASEPOINT_SH" ] && [ -n "$start" ]; then
    out="$(LANE_LEDGER_SOURCE=lane-launch-gate bash "$BASEPOINT_SH" basepoint-ref "$repo" "$start" 2>&1)"
    brc=$?
    if [ "$brc" -ne 0 ]; then
      emit_deny "$(printf 'レーン発射ゲート [基点規律 #91]\n%s\n\n  起点を取り直してから再実行してください。\n  意図的に無視する場合のみ LANE_BASEPOINT_ENFORCE=0（降格は台帳へ記帳されます）。' "$out")"
    fi
  elif [ -z "$BASEPOINT_SH" ]; then
    # 判定スクリプトが解決できない = hook は配備されたのに検査が効いていない。
    # 壊れた関門で作業を止めるのは正しくないので通すが、**黙っては通さない**。
    # 無言で素通しすると「配備済みなのに無効」が発見されないまま残る。
    # 同型の実例: #81（secret-patterns が merge されたが未配備）/
    # #121（checker は配備したが harness-spec.md を配らず恒久 rc=2）。
    note_ledger measure basepoint-unavailable \
      "lane-basepoint-check.sh が解決できないため基点判定を省略: $target"
    printf '[lane-launch-gate] lane-basepoint-check.sh が見つからないため基点判定を省略しました。setup.sh の配備を確認してください。\n' >&2
  elif [ -z "$start" ]; then
    # 起点省略（`-b new <path>` のみ）= git は現 HEAD を使う。hook 側で HEAD を
    # 確定できないので判定しない。黙って通さず、通したことを記録する。
    note_ledger measure basepoint-skipped "start-point 省略のため基点判定を省略: $target"
    printf '[lane-launch-gate] 起点未指定のため基点判定を省略しました。origin/<base> を明示すると検査されます。\n' >&2
  fi

  # --- (2) #88 同族反復上限 ---------------------------------------------------
  # 発射時点では diff が無いので family を導出できない。触る予定のパスが
  # LANE_PATHS（改行区切り）で宣言されているときだけ判定する。
  # 宣言が無ければ **判定を省略し、省略したことを記録する**（黙って通さない）。
  if [ -n "${LANE_PATHS:-}" ] && [ -n "$BREAKER_SH" ]; then
    family="$(printf '%s\n' "$LANE_PATHS" | bash "$BREAKER_SH" family --paths-from - 2>/dev/null | tail -1)"
    if [ -n "$family" ]; then
      ledger_file="${LANE_REPAIR_LEDGER:-$HOME/.claude/state/repair-ledger.jsonl}"
      if [ -f "$ledger_file" ]; then
        bout="$(bash "$BREAKER_SH" evaluate --ledger "$ledger_file" \
                  --family "$family" ${LANE_READJ_ENTRY:+--entry "$LANE_READJ_ENTRY"} 2>&1)"
        crc=$?
        if [ "$crc" -ne 0 ]; then
          emit_deny "$(printf 'レーン発射ゲート [同族反復上限 #88]\n%s\n\n  同じ家系の修理が閾値に達しています。再裁定エントリを書いてから発射してください。\n  LANE_READJ_ENTRY=<path> で再裁定エントリを渡せます。' "$bout")"
        fi
      else
        note_ledger measure repair-ledger-absent "修理台帳が無いため #88 判定を省略: $ledger_file"
        printf '[lane-launch-gate] 修理台帳 %s が無いため #88 判定を省略しました。\n' "$ledger_file" >&2
      fi
    else
      # 宣言はあったが family を導出できなかった。上と同じ理由で黙らない。
      note_ledger measure repair-family-underivable \
        "LANE_PATHS から family を導出できないため #88 判定を省略"
      printf '[lane-launch-gate] LANE_PATHS から family を導出できないため #88 判定を省略しました。\n' >&2
    fi
  elif [ -n "${LANE_PATHS:-}" ] && [ -z "$BREAKER_SH" ]; then
    printf '[lane-launch-gate] repair-loop-breaker.sh が見つからないため #88 判定を省略しました。\n' >&2
    note_ledger measure breaker-absent "repair-loop-breaker.sh 未解決のため #88 判定を省略"
  fi
done <<<"$parsed"

emit_allow
