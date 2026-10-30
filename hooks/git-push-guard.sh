#!/bin/bash
# git-push-guard.sh — PreToolUse hook for git push (minimal safety net, ADR-006)
# Blocks: force-push to protected branches, direct push to protected branches.
set -euo pipefail

_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aidd-ledger.sh"
# shellcheck source=/dev/null
[ -f "$_LEDGER_LIB" ] && . "$_LEDGER_LIB"
_aidd_block() {
  # Optional rule tag (mirror of protect-branches.sh). Callers without one keep
  # the previous "protected-push".
  local rule="${1:-protected-push}"
  if declare -F aidd_ledger_append >/dev/null 2>&1; then
    aidd_ledger_append "git-push-guard" "block" "deny" "${cmd:-${cmd_norm:-}}" "$rule"
  fi
  exit 2
}

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# --- Push destination resolver (F22, 2026-10-30) ---
# 2026-10-30 統括の独立ドライラン（develop の checkout 上）で、素の `git push` と
# `git push origin HEAD` が 2 本とも通っていた。protect-branches.sh は Check 3b の
# grep が `push` の後の空白を要求し、無いと pipefail + set -e で rc=1（非ブロックの
# エラー = 素通り）。git-push-guard.sh は明示の ref しか見ず、暗黙ブランチは force
# 限定だった。どちらも `HEAD` を current に解決しなかった。
#
# この解決器は `git push` 1 回ごとに「更新する宛先ブランチ」を 1 行ずつ出す:
#   <branch> TAB <git が読む dir> TAB explicit|current|push-upstream|matching
# dir は hook の process cwd ではなく、入力 JSON の .cwd を起点に、先行する
# `cd <dir>` と、その呼び出し自身の `git -C <dir>`（累積・相対可）で決める。
# `( … )` / `$( … )` / バッククォートの中の cd は外へ持ち越さない（実シェルと同じ）。
# 宛先: refspec の dst 側（`+` と refs/heads/ を外す。`:x` の削除も x）。`HEAD` と `@`
# と、current を返す既知の置換（`$(git branch --show-current)` など）は current。
# 他のコマンド置換は宛先不明として何も出さない（develop を返す置換は見逃す）。
# refspec が無い / remote だけなら push.default と @{push} で決める（呼び出しの
# `-c` も効かせる）: nothing → 無し、matching → ローカル枝すべて、@{push} が
# 決まればその枝だけ、決まらなければ current。`--tags` だけなら枝は出さない。
# データ文脈（cat / echo / printf / tee / grep / head / tail …、パイプ無し）が食う
# heredoc の本文は読まない。本文を実行するもの（python3 - <<PY、| bash）は子として読む。
# `bash -c "<cmd>"` / `sh -c` / `eval "<cmd>"` の引数も子として読む。
# 区切り（; | & < > ( ) 改行）はクォートの外でだけ切る（`sh -c 'cd x && git push'`）。
# 宛先の決め方は hooks/codex/protect-branches-codex.sh と hooks/cursor/git-guard.sh の
# push_destination() と同じで、全 refspec と push.default に広げてある。
# 本文は protect-branches.sh と git-push-guard.sh で一字一句同じ
# （tests/test-hard-block-implicit-push.sh の P 行が比較する）。
IFS= read -r -d '' _push_dests_py <<'PY' || true
import os
import re
import shlex
import subprocess
import sys

cmd = sys.argv[1]
run = sys.argv[2] if len(sys.argv) > 2 and os.path.isdir(sys.argv[2]) else os.getcwd()
env = dict(os.environ)
seen = set()
DATA = {"cat", "echo", "printf", "tee", "grep", "egrep", "fgrep", "rg", "ag", "head", "tail"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
RUNNERS = {"sudo", "doas", "env", "command", "exec", "nohup", "time", "nice", "timeout", "stdbuf", "setsid", "xargs"}
SUBST = "__f22_subst__"
Q1, Q2 = chr(39), chr(34)
CURRENT = r"git\s+(?:branch\s+--show-current|rev-parse\s+--abbrev-ref\s+HEAD|symbolic-ref\s+(?:-q\s+)?--short(?:\s+-q)?\s+HEAD)"


def expand(s):
    s = re.sub(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", lambda m: env.get(m.group(1), m.group(0)), s)
    return os.path.expanduser(s)


def resolve(d, cur):
    return os.path.normpath(os.path.join(cur, expand(d)))


def words(seg):
    try:
        lex = shlex.shlex(seg, posix=True)
        lex.whitespace_split = True
        lex.commenters = ""
        return list(lex)
    except ValueError:
        return seg.translate({34: 32, 39: 32}).split()


def heredocs(text):
    # Outer text without heredoc bodies, and the bodies a shell or interpreter runs.
    # A body fed to a data command (cat / echo / tee / grep ...) with no pipe is data.
    out, code, delim, body, keep = [], [], None, [], False
    for line in text.split("\n"):
        if delim is not None:
            if line.strip() == delim:
                if keep:
                    code.append("\n".join(body))
                delim, body = None, []
            else:
                body.append(line)
            continue
        out.append(line)
        m = re.search(r"(?<!<)<<(?!<)-?\s*([\x22\x27]?)([A-Za-z_][A-Za-z0-9_]*)\1", line)
        if m and not (line[:m.start()].count(Q1) % 2 or line[:m.start()].count(Q2) % 2):
            head = re.split(r"\$\(|[;&|(`]", line[:m.start()])[-1]
            w = [t for t in words(head) if not re.match(r"[A-Za-z_][A-Za-z0-9_]*=", t)]
            data = bool(w) and os.path.basename(w[0]) in DATA and "|" not in line[m.end():]
            delim, keep = m.group(2), not data
    if delim is not None and keep and body:
        code.append("\n".join(body))
    return "\n".join(out), code


def close_paren(text, k):
    depth, q, i = 0, None, k
    while i < len(text):
        c = text[i]
        if q:
            if c == "\\" and q == Q2:
                i += 2
                continue
            if c == q:
                q = None
        elif c in (Q1, Q2):
            q = c
        elif c == "\\":
            i += 2
            continue
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(text)


def split_top(text):
    # [(segment, substitutions, delimiter)] split at unquoted ; | & < > ( ) newline.
    # $( ) and backquotes become SUBST in the segment; their text is returned to run in a child scope.
    out, buf, subs, i, q = [], [], [], 0, None
    while i < len(text):
        c = text[i]
        if q == Q1:
            buf.append(c)
            q = None if c == Q1 else q
            i += 1
        elif c == "\\":
            buf.append(text[i:i + 2])
            i += 2
        elif c == "$" and text[i + 1:i + 2] == "(":
            j = close_paren(text, i + 1)
            subs.append(text[i + 2:j])
            buf.append(SUBST)
            i = j + 1
        elif c == "`":
            j = text.find("`", i + 1)
            j = len(text) if j < 0 else j
            subs.append(text[i + 1:j])
            buf.append(SUBST)
            i = j + 1
        elif q == Q2:
            buf.append(c)
            q = None if c == Q2 else q
            i += 1
        elif c in (Q1, Q2):
            q = c
            buf.append(c)
            i += 1
        elif c == "#" and (not buf or buf[-1][-1:].isspace()):
            j = text.find("\n", i)
            i = len(text) if j < 0 else j
        elif c in ";|&<>()\n":
            out.append(("".join(buf), subs, c))
            buf, subs = [], []
            i += 1
        else:
            buf.append(c)
            i += 1
    out.append(("".join(buf), subs, ""))
    return out


def git(d, gopts, *args):
    try:
        r = subprocess.run(["git", "-C", d] + gopts + list(args),
                           capture_output=True, text=True, timeout=5)
    except Exception:
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def emit(name, d, how):
    if name and (name, d, how) not in seen:
        seen.add((name, d, how))
        print(name + "\t" + d + "\t" + how)


def implicit(d, gopts, remote):
    b = git(d, gopts, "symbolic-ref", "--short", "-q", "HEAD")
    if not b:
        return
    mode = git(d, gopts, "config", "push.default") or "simple"
    if mode == "nothing":
        return
    if mode == "matching":
        for name in git(d, gopts, "for-each-ref", "--format=%(refname:short)", "refs/heads").split("\n"):
            emit(name, d, "matching")
        return
    pr = (git(d, gopts, "config", "branch." + b + ".pushRemote")
          or git(d, gopts, "config", "remote.pushDefault")
          or git(d, gopts, "config", "branch." + b + ".remote"))
    up = git(d, gopts, "rev-parse", "--symbolic-full-name", "@{push}")
    prefix = "refs/remotes/" + pr + "/"
    if pr and (not remote or remote == pr) and up.startswith(prefix):
        dst = up[len(prefix):]
        emit(dst, d, "current" if dst == b else "push-upstream")
        return
    emit(b, d, "current")


def push(d, gopts, rest):
    pos, tags, k = [], False, 0
    while k < len(rest):
        t = rest[k]
        if t == "--":
            pos += rest[k + 1:]
            break
        if t.startswith("-") and t != "-":
            if t in ("-o", "--push-option", "--repo", "--receive-pack", "--exec"):
                k += 1
            elif t == "--tags":
                tags = True
            k += 1
            continue
        pos.append(t)
        k += 1
    if len(pos) < 2:
        if not tags:
            implicit(d, gopts, pos[0] if pos else "")
        return
    for ref in pos[1:]:
        if SUBST in ref:
            continue
        ref = ref[1:] if ref.startswith("+") else ref
        if ":" in ref:
            src, dst = ref.split(":", 1)
            ref = dst or src
        if ref in ("HEAD", "@"):
            emit(git(d, gopts, "symbolic-ref", "--short", "-q", "HEAD"), d, "current")
            continue
        if ref.startswith("refs/heads/"):
            ref = ref[len("refs/heads/"):]
        emit(ref, d, "explicit")


def child(text):
    global run
    saved = run
    process(text)
    run = saved


def segment(w):
    global run
    if w and w[0] == "export":
        w = w[1:]
    if w and all(re.match(r"[A-Za-z_][A-Za-z0-9_]*=", t) for t in w):
        for t in w:
            name, _, val = t.partition("=")
            env[name] = expand(val)
        return
    if w and w[0] in ("cd", "pushd"):
        nxt = resolve(w[1], run) if len(w) > 1 else os.path.expanduser("~")
        if os.path.isdir(nxt):
            run = nxt
        return
    for i, t in enumerate(w):
        # `bash -c "<cmd>"` / `eval "<cmd>"` at command position (after env / VAR=... and
        # similar runners) run their argument as a command line in a child.
        if not all(p in RUNNERS or p.startswith("-") or p.isdigit()
                   or re.match(r"[A-Za-z_][A-Za-z0-9_]*=", p) for p in w[:i]):
            break
        if t == "eval" or (os.path.basename(t) in SHELLS and "-c" in w[i + 1:]):
            k = i + 1 if t == "eval" else w.index("-c", i + 1) + 1
            if k < len(w):
                child(" ".join(w[k:]) if t == "eval" else w[k])
            return
    for i, t in enumerate(w):
        if os.path.basename(t) != "git":
            continue
        d, j, gopts = run, i + 1, []
        while j < len(w) and w[j].startswith("-"):
            o = w[j]
            if o == "-C" and j + 1 < len(w):
                d = resolve(w[j + 1], d)
                j += 2
            elif o in ("-c", "--config-env", "--git-dir", "--work-tree") and j + 1 < len(w):
                gopts += [o, expand(w[j + 1])]
                j += 2
            elif o.startswith(("--git-dir=", "--work-tree=", "--config-env=")):
                gopts.append(o)
                j += 1
            elif o == "--namespace" and j + 1 < len(w):
                j += 2
            else:
                j += 1
        if j < len(w) and w[j] == "push":
            push(d, gopts, w[j + 1:])


def process(text):
    global run
    text, bodies = heredocs(text)
    text = re.sub(r"\$\(\s*" + CURRENT + r"\s*\)|`\s*" + CURRENT + r"\s*`", "HEAD", text)
    stack = []
    for seg, subs, delim in split_top(text):
        for s in subs:
            child(s)
        segment(words(seg))
        if delim == "(":
            stack.append(run)
        elif delim == ")" and stack:
            run = stack.pop()
    for body in bodies:
        child(body)


process(cmd)
PY
# The Bash tool's cwd, not the hook process cwd (which may be the session's start dir).
_push_base=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || true)
[ -n "$_push_base" ] && [ -d "$_push_base" ] || _push_base="$PWD"

# --- Resolve git context dir: honor `cd <dir> && ...` and `git -C <dir>` ---
# The hook process cwd is the SESSION cwd, not the repo the command targets.
# Without this, the implicit-branch force-push check (git rev-parse HEAD) and
# the pre-push lint checks (rev-parse --show-toplevel) evaluate whatever repo
# the session happens to sit in — blocking pushes to repo B because repo A
# has lint errors, or misreading the current branch entirely.
ctx_dirs=$(CMD="$cmd" BASE="$_push_base" python3 - <<'PY'
import os, re
cmd = os.environ.get("CMD", "")
base = os.environ.get("BASE", "") or os.getcwd()
q1, q2 = chr(34), chr(39)
pat_val = r'((?:%s[^%s]+%s)|(?:%s[^%s]+%s)|(?:[^\s;&|]+))' % (q1, q1, q1, q2, q2, q2)
def _resolve(m):
    if not m:
        return ""
    d = os.path.expanduser(os.path.expandvars(m.group(1).strip(q1 + q2)))
    d = os.path.join(base, d) if d else ""
    return d if d and os.path.isdir(d) else ""

# `git -C <dir>` wins over a leading `cd <dir> &&` (git resolves -C itself),
# but only when its value is a real directory — a `git -C` appearing inside a
# quoted string (e.g. an issue title) must not shadow a valid leading cd.
#
# Resolve -C per PUSHING invocation, not once for the whole command. Taking the
# first `git -C` anywhere mismatched the push target whenever an earlier
# invocation named a different repo: `git -C A status && git -C B push --force`
# read repo A's HEAD while repo B was the one actually pushed, so a force push
# to a protected branch fell through (rc 0) and a legitimate feature-branch one
# was blocked (rc 2). Every pushing segment is emitted, and the implicit-branch
# check below blocks if ANY of them sits on a protected branch — a second push
# must not hide behind a benign first one. Segment split matches
# hooks/cursor/git-guard.sh, which already scoped its push rules this way.
# (Issue #263)
lead_cd = _resolve(re.match(r'^\s*cd\s+' + pat_val + r'\s*(?:&&|;)', cmd))
seen, out = set(), []
for seg in re.split(r'&&|\|\||[;\n|]', cmd):
    if not re.search(r'\bgit\b.*\bpush\b', seg):
        continue
    d = _resolve(re.search(r'git\s+-C\s+' + pat_val, seg)) or lead_cd
    if d not in seen:
        seen.add(d)
        out.append(d)
print("\n".join(out) if out else lead_cd)
PY
)

# Current branch of every pushing invocation's repo (one per line).
# An empty ctx dir means the Bash tool's cwd (.cwd), which is what plain `git`
# reads — not the hook process cwd (F22, 2026-10-30).
ctx_branches() {
  local d
  while IFS= read -r d || [[ -n "$d" ]]; do
    git -C "${d:-$_push_base}" rev-parse --abbrev-ref HEAD 2>/dev/null || true
  done <<< "$ctx_dirs"
}

# cmd_norm: collapse git global options (-C <dir>, -c <k=v>, --no-pager) so the
# push/commit pattern matches below cannot be dodged with `git -C <repo> push`
# (fail-open bypass). Quote-aware: -C "/path with spaces" collapses too.
# ctx_dirs above still reads the ORIGINAL command.
cmd_norm=$(CMD="$cmd" python3 - <<'PY'
import os, re
cmd = os.environ.get("CMD", "")
q1, q2 = chr(34), chr(39)
val = r'(?:%s[^%s]*%s|%s[^%s]*%s|[^\s;&|]+)' % (q1, q1, q1, q2, q2, q2)
opt = r'(?:\s+-C\s+' + val + r'|\s+-c\s+' + val + r'|\s+--no-pager)'
print(re.sub(r'git' + opt + r'+(\s+)', r'git\g<1>', cmd), end="")
PY
)

# mentions_protected_ref <cmd> <branch>
# Returns 0 if <branch> appears as a push ref token anywhere in <cmd>, tolerant
# of process substitution `<(...)`, command chains, redirects and refspec forms
# (origin main / :main / refs/heads/main). Position-independent so a force push
# wrapped as `cat <(git push --force origin main)` can no longer hide the
# protected branch from extraction (parser-gap fix).
mentions_protected_ref() {
  printf '%s' "$1" | grep -qE "(^|[^A-Za-z0-9._/-])(refs/heads/)?$2([^A-Za-z0-9._/-]|$)"
}

has_explicit_push_ref() {
  # Detect "git push <remote> <ref>" even when wrapped in a chain or process
  # substitution. If a ref is explicit, current-branch fallback would be a false
  # positive when the hook itself runs from develop/main.
  local segment token after_push non_option_count normalized
  normalized=$(printf '%s' "$1" | tr '<>();|&' '\n')
  while IFS= read -r segment || [[ -n "$segment" ]]; do
    [[ "$segment" == *"git push"* ]] || continue
    after_push=false
    non_option_count=0
    for token in $segment; do
      if [[ "$after_push" != true ]]; then
        [[ "$token" == "push" ]] && after_push=true
        continue
      fi
      [[ "$token" == -* ]] && continue
      non_option_count=$((non_option_count + 1))
    done
    [[ "$non_option_count" -ge 2 ]] && return 0
  done <<< "$normalized"
  return 1
}

# Skip ONLY a single read-only inspection command that merely MENTIONS the operation
# (e.g. grep "gh pr create" ...). Requires a single-line command with NO shell operator,
# so a real operation cannot be chained after a benign first token (prevents
# `echo x && git push --force` style bypass). Executor tools excluded.
if [[ -n "$cmd" ]] \
   && [[ "$cmd" != *$'\n'* ]] \
   && ! printf '%s' "$cmd" | grep -qE '[;&|`<>]|\$\(' \
   && printf '%s' "$cmd" | grep -qE '^[[:space:]]*(grep|egrep|fgrep|cat|head|tail|wc|comm|diff|cut|tr|uniq|jq|ls|which|type|echo|printf)\b'; then
  exit 0
fi

# --- 0. Early exit: only run on git push commands (Issue #150) ---
# Without this guard, black/ruff checks in section 3 block ALL Bash commands,
# creating an unrecoverable deadlock where even `black .` is blocked.
if ! echo "$cmd_norm" | grep -qE '\bgit\s+push\b'; then
  exit 0
fi

# --- 1. Force push to shared branches check (Issue #17) ---
# Block --force / --force-with-lease to develop/main/master
# Feature branches are allowed (user's own branch history cleanup is legitimate)
#
# 2026-09-05 (claude-code-skills#365): 従来は force フラグの検出と保護名の照合を
# コマンド文字列**全体**に当てていた。`git push origin feat/x && pkill -f X` は
# `.*` が `&&` を跨いで force push と読まれ、暗黙ブランチのフォールバックで
# develop 上の運用者を止めた。has_explicit_push_ref() と同じ `tr '<>();|&'` で
# セグメント化し、force フラグ付きの git push を含むセグメントの中だけで読む。
# protect-branches.sh Check 0b と対で直す（片方だけ変えない）。
force_push_segment() {
  # <segment>: true if this one segment is a `git push` carrying a force flag
  printf '%s' "$1" | grep -qE 'git\s+push\b.*(--(force|force-with-lease)\b|-f\b)' \
    || printf '%s' "$1" | grep -qE 'git\s+push\s+-[a-zA-Z]*f'
}
while IFS= read -r _fp_seg || [[ -n "$_fp_seg" ]]; do
  force_push_segment "$_fp_seg" || continue
    # Check explicit branch names in this segment
    for branch in develop main master; do
        if mentions_protected_ref "$_fp_seg" "$branch"; then
            cat >&2 <<ERRMSG
[BLOCK] 共有ブランチ '${branch}' への force push を検出

理由: force push は履歴を書き換えます。
  - 他のエンジニアの作業ベースが壊れる可能性
  - レビュー済みコミット履歴が失われる可能性
  - --force-with-lease も --force と同等に扱います

対処法: ユーザーが手動で実行してください。
  (Claude Code プロンプトで) ! git push --force-with-lease origin ${branch}

Ref: Issue #17 — AI からの force push はブロック、ユーザー手動実行に限定
ERRMSG
            _aidd_block
        fi
    done

    # Fallback: if no explicit push ref in this segment, check current branch
    # Catches: git push --force, git push --force origin (implicit branch)
    if ! has_explicit_push_ref "$_fp_seg"; then
      while IFS= read -r current_branch || [[ -n "$current_branch" ]]; do
        for branch in develop main master; do
            if [[ "$current_branch" == "$branch" ]]; then
                cat >&2 <<ERRMSG
[BLOCK] 共有ブランチ '${branch}' への force push を検出（暗黙的ブランチ）

現在のブランチ '${branch}' は共有ブランチです。
コマンドにブランチ名が明示されていなくても、force push はブロックされます。

対処法: ユーザーが手動で実行してください。
  (Claude Code プロンプトで) ! git push --force-with-lease origin ${branch}

Ref: Issue #28 — 差分有無にかかわらず共有ブランチへの force push をブロック
ERRMSG
                _aidd_block
            fi
        done
      done < <(ctx_branches)
    fi
done < <(printf '%s' "$cmd_norm" | tr '<>();|&' '\n')

# --- 2. Protected branch direct push check ---
# Destination is protected if refspec is bare branch, refs/heads/<branch>,
# or *:<branch> / *:refs/heads/<branch> (Phase 3 T3-1 coverage repair:
# HEAD:refs/heads/main and refs/heads/main previously slipped through
# because only ":${branch}$" / exact "${branch}" were matched).
_is_protected_push_dest() {
  local refspec="$1" branch="$2"
  [ "$refspec" = "$branch" ] && return 0
  [ "$refspec" = "refs/heads/${branch}" ] && return 0
  echo "$refspec" | grep -qE ":(refs/heads/)?${branch}$" && return 0
  return 1
}
for branch in develop main master; do
    # Exclude only pure delete refspecs (`--delete` or a bare leading `:branch`
    # with no source ref before the colon) — `HEAD:branch` / `feat:branch` are
    # real pushes to the protected branch and must still be caught below.
    # Also match refs/heads/<branch> (word-boundary alone is insufficient for
    # the dest equality check below; still used as a cheap prefilter).
    if echo "$cmd_norm" | grep -qE "git\s+push\s+.*(refs/heads/)?${branch}([^A-Za-z0-9._-]|$)" && \
       ! echo "$cmd_norm" | grep -qE "(--delete|(^|[[:space:]]):(refs/heads/)?${branch}\b)"; then
        # F22b: xargs exits 1 on an odd number of quotes (`# it's done`), which
        # set -e turned into rc=1 = a non-blocking error = the push went through.
        push_target=$(echo "$cmd_norm" | grep -oE "push\s+[^|;&)<>]*" | sed 's/push\s*//' | sed 's/\s*-[a-zA-Z-]*//g' | tr -d "\"'" | xargs) || true
        refspec=$(echo "$push_target" | awk '{print $NF}')
        if _is_protected_push_dest "$refspec" "$branch"; then
            echo "[BLOCKED] Direct push to '${branch}'. Use PR instead." >&2
            echo "  git push -u origin feat/xxx && gh pr create --base develop" >&2
            _aidd_block
        fi
    fi
done

# --- 3. Every branch each `git push` updates, in the repo git reads (F22) ---
# §1 covers implicit force only and §2 covers explicit refs only, so a plain
# `git push` / `git push origin HEAD` on develop passed both (2026-10-30). The
# resolver above also blocks `:develop` / `--delete develop` here; until now only
# protect-branches.sh refused those.
while IFS=$'\t' read -r _dest _dest_dir _dest_how || [[ -n "${_dest:-}" ]]; do
  for branch in develop main master; do
    [[ "$_dest" == "$branch" ]] || continue
    if [[ "$_dest_how" == "explicit" ]]; then
      echo "[BLOCKED] Direct push to '${branch}'. Use PR instead." >&2
      _rule="protected-push"
    else
      echo "[BLOCKED] Implicit push to '${branch}' (${_dest_how} of ${_dest_dir}). Use PR instead." >&2
      _rule="protected-push-implicit"
    fi
    echo "  git push -u origin feat/xxx && gh pr create --base develop" >&2
    _aidd_block "$_rule"
  done
done < <(python3 -c "$_push_dests_py" "$cmd" "$_push_base" 2>/dev/null || true)

exit 0
