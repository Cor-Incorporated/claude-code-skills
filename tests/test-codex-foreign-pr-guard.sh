#!/usr/bin/env bash
# Phase 16 T16-2: Codex foreign PR truth table.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/codex/protect-branches-codex.sh"
TMP_DIR="$(mktemp -d)"
REPO="$TMP_DIR/repo"
LEDGER="$TMP_DIR/guard-ledger.jsonl"
export AIDD_LEDGER_SOURCE=test

mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" remote add origin git@github.com:Cor-Incorporated/claude-code-skills.git

actual_for() {
  local command="$1" output
  output=$(jq -cn --arg command "$command" '{tool_input:{command:$command}}' \
    | (cd "$REPO" && CODEX_GUARD_LEDGER="$LEDGER" bash "$HOOK"))
  if printf '%s' "$output" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'block\n'
  else
    printf 'allow\n'
  fi
}

# --- Markdown-escape axis (2026-09-02) ---------------------------------------
# Codex Desktop passes UI text through to the hook with Markdown escaping still
# applied. The real payload observed was:
#   ["/bin/zsh","-lc","echo AIDD\_CODEX\_HOOK\_SPIKE\_MARKER"]
# A bare string comparison then fails to see `\-\-repo` as `--repo`, so the
# foreign-PR guard returned ALLOW on a command it must block.
# Falsifiable: drop the sed unescape from cmd_norm and the escaped rows go allow.
esc_fail=0
printf '\nescape_case\texpected\tactual\tverdict\n'
while IFS='|' read -r label command expected; do
  [ -z "$label" ] && continue
  actual="$(actual_for "$command")"
  if [ "$actual" = "$expected" ]; then verdict=PASS; else verdict=FAIL; esc_fail=$((esc_fail + 1)); fi
  printf '%s\t%s\t%s\t%s\n' "$label" "$expected" "$actual" "$verdict"
done <<'CASES'
foreign-pr-escaped|gh pr create \-\-repo anomalyco/opencode \-\-base dev|block
foreign-pr-plain|gh pr create --repo anomalyco/opencode --base dev|block
spike-marker-escaped|echo AIDD\_CODEX\_HOOK\_SPIKE\_MARKER|block
spike-marker-plain|echo AIDD_CODEX_HOOK_SPIKE_MARKER|block
force-push-escaped|git push \-\-force origin main|block
mirror-push-escaped|git push \-\-mirror origin|block
benign-escaped|echo hello\_world|allow
benign-underscore-branch|git push origin develop\_x|allow
CASES
if [ "$esc_fail" -ne 0 ]; then
  printf 'FAIL: markdown-escape axis mismatches=%s\n' "$esc_fail"
  fail=$((fail + esc_fail))
else
  printf 'PASS: markdown-escape axis mismatches=0\n'
fi

fail=0
printf 'repo_axis\toperation\texpected\tactual\tverdict\n'
for repo_axis in foreign same none; do
  for operation in create merge; do
    case "$repo_axis" in
      foreign)
        repo_arg='--repo anomalyco/opencode'
        expected=block
        ;;
      same)
        repo_arg='--repo "cor-incorporated/another-repo"'
        expected=allow
        ;;
      none)
        repo_arg=''
        expected=allow
        ;;
    esac
    command="gh pr $operation"
    [[ -n "$repo_arg" ]] && command="$command $repo_arg"
    actual=$(actual_for "$command")
    verdict=PASS
    if [[ "$actual" != "$expected" ]]; then
      verdict=FAIL
      fail=$((fail + 1))
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$repo_axis" "$operation" "$expected" "$actual" "$verdict"
  done
done

# Equals-form and GitHub URL are part of the same owner contract.
[[ "$(actual_for 'gh pr create --repo=anomalyco/opencode')" == block ]] || fail=$((fail + 1))
[[ "$(actual_for 'gh pr merge --repo=https://github.com/Cor-Incorporated/example.git')" == allow ]] || fail=$((fail + 1))

# --- ledger JSON axis (2026-09-25) --------------------------------------------
# emit_deny appends one line per deny to $LEDGER, and every line must parse as
# one JSON object with ts/hook/decision/cmd_head. On 2026-09-25 the real
# ~/.codex/hooks/guard-ledger.jsonl had 62 of 414 lines that did not parse:
# cmd_head went into printf raw, so the Markdown-escaped rows above left a
# backslash (Invalid \escape) and a multi-line command split into several lines.
# The rows below add the other shapes; each must deny and add exactly one line,
# and its cmd_head must keep the command (first 120 bytes cut on a UTF-8
# boundary, " as ', newline/tab/CR as a space), so a fix that empties or mangles
# the value does not pass either. Falsifiable: with emit_deny from develop
# d71d782 the escaped rows above and every row below leave lines that do not
# parse.
ledger_lines() { [ -f "$LEDGER" ] && wc -l <"$LEDGER" | tr -d ' ' || printf '0\n'; }
BS="\\"
pad="$(printf '%89s' '' | tr ' ' x)" # 30-byte prefix + 89 = byte 119
ledger_fail=0
ledger_cmds=()
printf 'ledger_case\tactual\tlines_added\tverdict\n'
for label in multi-line tab-and-quote backslash-at-byte-120 utf8-across-byte-120 control-char; do
  case "$label" in
    multi-line) command="git push --force origin main"$'\r\n'"echo second line" ;;
    tab-and-quote) command='git push --force origin "main"'$'\t''# tabbed' ;;
    backslash-at-byte-120) command="git push --force origin main #${pad}${BS}tail" ;;
    utf8-across-byte-120) command="git push --force origin main #${pad}日本語" ;;
    control-char) command="git push --force origin main # "$'\001'" ctl" ;;
  esac
  ledger_cmds+=("$command")
  before="$(ledger_lines)"
  actual="$(actual_for "$command")"
  added=$(($(ledger_lines) - before))
  if [[ "$actual" == block && "$added" -eq 1 ]]; then verdict=PASS; else verdict=FAIL; ledger_fail=$((ledger_fail + 1)); fi
  printf '%s\t%s\t%s\t%s\n' "$label" "$actual" "$added" "$verdict"
done
python3 - "$LEDGER" "${ledger_cmds[@]}" <<'PY' || ledger_fail=$((ledger_fail + 1))
import json, re, sys
path, commands = sys.argv[1], sys.argv[2:]
raw = open(path, "rb").read()
lines = raw.split(b"\n")
if lines and lines[-1] == b"":
    lines.pop()
broken, recs = [], []
if raw and not raw.endswith(b"\n"):
    broken.append(f"  file does not end with a newline: {raw[-40:]!r}")
for n, line in enumerate(lines, 1):
    try:
        rec = json.loads(line.decode("utf-8"))
        if not isinstance(rec, dict) or not {"ts", "hook", "decision", "cmd_head"} <= rec.keys():
            raise ValueError(f"not a ledger record: {rec!r:.60}")
        if (rec["hook"], rec["decision"]) != ("protect-branches-codex", "deny"):
            raise ValueError(f"hook={rec['hook']} decision={rec['decision']}")
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", str(rec["ts"])):
            raise ValueError(f"ts={rec['ts']!r}")
        recs.append(rec)
    except Exception as exc:
        broken.append(f"  line {n}: {type(exc).__name__}: {exc} | {line[:60]!r}")


def expected(cmd):
    head = cmd.encode("utf-8")[:120].decode("utf-8", "ignore")
    return head.replace('"', "'").replace("\n", " ").replace("\t", " ").replace("\r", " ")


def printable(s):  # the jq path escapes other control chars, the fallback drops them
    return "".join(ch for ch in s if ord(ch) >= 0x20)


if not broken:
    for cmd, rec in zip(commands, recs[-len(commands):]):
        got, want = rec["cmd_head"], expected(cmd)
        if printable(got) != printable(want):
            broken.append(f"  cmd_head {got!r} != {want!r}")
print(f"ledger lines={len(lines)} broken={len(broken)}")
for b in broken:
    print(b)
sys.exit(1 if broken or len(recs) < len(commands) else 0)
PY
if [[ "$ledger_fail" -ne 0 ]]; then
  printf 'FAIL: ledger JSON axis mismatches=%s\n' "$ledger_fail"
  fail=$((fail + ledger_fail))
else
  printf 'PASS: ledger JSON axis mismatches=0\n'
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: Codex foreign PR truth table mismatches=$fail" >&2
  exit 1
fi
echo "PASS: Codex foreign PR truth table mismatches=0 false_positives=0"
