#!/usr/bin/env python3
"""Branches each `git push` in a Bash command updates (F22, 2026-10-30).

Used by hooks/protect-branches.sh (Check 3c) and hooks/git-push-guard.sh (§3):

    python3 push_dests.py <command> <cwd>

prints one line per destination branch:

    <branch> TAB <dir git reads> TAB explicit|current|push-upstream|matching|wildcard|remote-push

Why: on 2026-10-30 a plain `git push` and `git push origin HEAD` on a develop
checkout passed both hard blocks. protect-branches exited 1 (a non-blocking
error) because its grep needs a space after `push`; git-push-guard read only
explicit refs, and neither resolved HEAD.

Directory: the input's .cwd (the Bash tool's cwd, not the hook process cwd),
moved by earlier `cd` / `pushd`, then the push's own `git -C <dir>`
(cumulative, relative allowed). `( )`, `$( )`, backquotes, `bash -c` and
heredoc bodies run as children: a `cd` inside does not leak out.

Splitting: only at unquoted `; | & < > ( )` and newlines; `#` comments are
dropped. `$( )` / backquotes and `bash|sh|zsh|dash|ksh -c "<cmd>"` /
`eval "<cmd>"` at command position are read as child command lines. A heredoc
body fed to a data command (cat / echo / printf / tee / grep / head / tail, no
pipe) is dropped; a body a shell or interpreter runs is a child command line.
The arguments of a data command are text, not a git call.

Destinations: the refspec's dst side (`+`, refs/heads/, `src:dst`, `:dst`
delete), every refspec. `HEAD`, `@` and the known current-branch substitutions
(`$(git branch --show-current)`, `$(git rev-parse --abbrev-ref HEAD)`, ... with
an optional `2>/dev/null`) are the current branch; variables set earlier in the
command are expanded. Any other computed destination (another substitution, an
unset variable, `$1`, `${B:-x}`, a loop variable, `xargs`-supplied arguments,
`--mirror`, `--prune`) cannot be decided here and prints `*  <dir>  computed`,
which both hooks block. Wildcard refspecs map the local branches matching src
onto dst; `:` and `--all` / `--branches` mean every local branch. Backslash
line continuations are joined and `$'..'` is decoded before splitting; git
aliases that expand to `push` are followed. With no refspec or a remote only: remote.<remote>.push first, then
push.default (nothing -> none, matching -> every local branch, upstream ->
branch.<b>.merge, else the current branch), with the push's own `-c`.
`--tags` alone updates no branch. A `git switch` / `git checkout <branch>`
earlier in the same command sets the current branch.

Unknown state fails open, an unknown destination fails closed: a directory
or branch the parser cannot read (`cd "$X"`, `cd -`, detached, an unreadable
switch) gives no destination, while a destination the command computes is
blocked (code review 2026-10-30: computed destinations were the bypasses). Before
this change every implicit push passed; a false positive in a hard block stops
work; the server-side branch protection stays the last line.

The rules follow push_destination() in hooks/codex/protect-branches-codex.sh
and hooks/cursor/git-guard.sh, widened as above.
tests/test-hard-block-implicit-push.sh pins each rule with a row.
"""
import fnmatch
import os
import re
import shlex
import subprocess
import sys

cmd = sys.argv[1]
run = sys.argv[2] if len(sys.argv) > 2 and os.path.isdir(sys.argv[2]) else os.getcwd()
env = dict(os.environ)
seen = set()
heads = {}
DATA = {"cat", "echo", "printf", "tee", "grep", "egrep", "fgrep", "rg", "ag", "head", "tail"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
RUNNERS = {"sudo", "doas", "env", "command", "exec", "nohup", "time", "nice", "timeout", "stdbuf", "setsid", "xargs"}
SUBST = "__f22_subst__"
COMPUTED = "*"
BUILTINS = {
    "add", "am", "apply", "archive", "bisect", "blame", "branch", "bundle", "cat-file", "checkout",
    "cherry-pick", "clean", "clone", "commit", "config", "describe", "diff", "fetch", "for-each-ref",
    "format-patch", "gc", "grep", "help", "init", "log", "ls-files", "ls-remote", "merge", "mv", "notes",
    "pull", "push", "range-diff", "rebase", "reflog", "remote", "reset", "restore", "rev-parse", "revert",
    "rm", "shortlog", "show", "stash", "status", "submodule", "switch", "symbolic-ref", "tag", "update-ref",
    "version", "worktree",
}
Q1, Q2 = chr(39), chr(34)
ASSIGN = r"[A-Za-z_][A-Za-z0-9_]*="
CURRENT = (r"git\s+(?:branch\s+--show-current|rev-parse\s+--abbrev-ref\s+(?:HEAD|@)"
           r"|symbolic-ref\s+(?:-q\s+)?--short(?:\s+-q)?\s+HEAD)(?:\s+2>(?:&1|\s*/dev/null))?")
UNRESOLVED = r"\$(?:\{|[A-Za-z_0-9@*#?!-])"


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


def head(d, gopts):
    # The branch the push reads. "" = detached, None = unknown (a switch it could not
    # read): both give no destination, so an unparsed state fails open, never closed.
    key = os.path.realpath(d)
    if key in heads:
        return heads[key]
    return git(d, gopts, "symbolic-ref", "--short", "-q", "HEAD")


def switched(d, gopts, sub, rest):
    # Track `git switch` / `git checkout` earlier in the command: the push reads that HEAD.
    key = os.path.realpath(d)
    if "--detach" in rest or (sub == "switch" and "-d" in rest):
        heads[key] = ""
        return
    pos, track = [], False
    for k, t in enumerate(rest):
        if t == "--":
            if sub == "checkout":
                return  # `git checkout <tree-ish> -- <paths>` restores files; HEAD stays
            break
        if t in ("-c", "-C", "--create", "--force-create", "-b", "-B", "--orphan") and k + 1 < len(rest):
            heads[key] = rest[k + 1]
            return
        m = re.match(r"(?:--(?:create|force-create|orphan)=|-[cCbB])(.+)$", t)
        if m:
            heads[key] = m.group(1)
            return
        if t == "-":
            heads[key] = None if key in heads else (git(d, gopts, "rev-parse", "--abbrev-ref", "@{-1}") or None)
            return
        if t in ("-t", "--track"):
            track = True
        if not t.startswith("-"):
            pos.append(t)
    if not pos or (sub == "checkout" and len(pos) > 1):
        return  # nothing named, or `git checkout <tree-ish> <paths>`
    t = pos[0]
    if track:
        # `-t origin/develop` creates the local branch named after the remote one.
        for r in git(d, gopts, "remote").split("\n"):
            if r and t.startswith(r + "/"):
                heads[key] = t[len(r) + 1:]
                return
        heads[key] = None
        return
    # A branch (local, or remote-tracking that switch / checkout would create) moves
    # HEAD there; a commit detaches it; a path leaves it.
    if (git(d, gopts, "rev-parse", "--verify", "-q", "refs/heads/" + t)
            or git(d, gopts, "for-each-ref", "--format=%(refname)", "refs/remotes/*/" + t)):
        heads[key] = t
    elif git(d, gopts, "rev-parse", "--verify", "-q", t + "^{commit}"):
        heads[key] = ""


def emit(name, d, how):
    if name and (name, d, how) not in seen:
        seen.add((name, d, how))
        print(name + "\t" + d + "\t" + how)


def local_branches(d, gopts, how):
    for name in git(d, gopts, "for-each-ref", "--format=%(refname:short)", "refs/heads").split("\n"):
        emit(name, d, how)


def branch_of(ref):
    return ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref


def split_refspec(ref):
    # `src:dst` at the first colon outside `${...}` (`${B:-develop}` is one operand).
    depth = 0
    for n, ch in enumerate(ref):
        if ref.startswith("${", n):
            depth += 1
        elif ch == "}" and depth:
            depth -= 1
        elif ch == ":" and not depth:
            return ref[:n], ref[n + 1:]
    return ref, ""


def refspec(ref, d, gopts, how):
    ref = expand(ref)
    ref = ref[1:] if ref.startswith("+") else ref
    if ref == ":":
        local_branches(d, gopts, "matching")
        return
    src, dst = split_refspec(ref)
    dst = dst or src
    if SUBST in dst or re.search(UNRESOLVED, dst):
        # A destination the command computes cannot be decided here: fail closed.
        # `$(git rev-parse HEAD):develop` still reads its literal dst.
        emit(COMPUTED, d, "computed")
        return
    if "*" in src or "*" in dst:
        # Map each local branch the source pattern matches onto the destination pattern.
        if src.count("*") != 1 or dst.count("*") != 1:
            return
        sp = src if src.startswith("refs/") else "refs/heads/" + src
        dp = dst if dst.startswith("refs/") else "refs/heads/" + dst
        pre, post = sp.split("*")
        for name in git(d, gopts, "for-each-ref", "--format=%(refname)", "refs/heads").split("\n"):
            if name and fnmatch.fnmatchcase(name, sp):
                out = dp.replace("*", name[len(pre):len(name) - len(post)])
                if out.startswith("refs/heads/"):
                    emit(branch_of(out), d, "wildcard")
        return
    if dst in ("HEAD", "@"):
        emit(head(d, gopts), d, "current")
        return
    emit(branch_of(dst), d, how)


def implicit(d, gopts, remote):
    b = head(d, gopts)
    if not b:
        return
    pr = (git(d, gopts, "config", "branch." + b + ".pushRemote")
          or git(d, gopts, "config", "remote.pushDefault")
          or git(d, gopts, "config", "branch." + b + ".remote"))
    specs = git(d, gopts, "config", "--get-all", "remote." + (remote or pr or "origin") + ".push")
    if specs:
        for spec in specs.split("\n"):
            refspec(spec.strip(), d, gopts, "remote-push")
        return
    mode = git(d, gopts, "config", "push.default") or "simple"
    if mode == "nothing":
        return
    if mode == "matching":
        local_branches(d, gopts, "matching")
        return
    if mode in ("upstream", "tracking"):
        merge = git(d, gopts, "config", "branch." + b + ".merge")
        if merge and (not remote or remote == git(d, gopts, "config", "branch." + b + ".remote")):
            dst = branch_of(merge)
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
            elif t in ("--all", "--branches"):
                local_branches(d, gopts, "all")
            elif t in ("--mirror", "--prune"):
                emit(COMPUTED, d, "computed")  # may delete remote branches
            k += 1
            continue
        pos.append(t)
        k += 1
    if len(pos) < 2:
        if not tags:
            implicit(d, gopts, pos[0] if pos else "")
        return
    for ref in pos[1:]:
        refspec(ref, d, gopts, "explicit")


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
        k = 1
        while k < len(w) and w[k].startswith("-") and w[k] != "-":
            k += 1
            if w[k - 1] == "--":
                break
        if k >= len(w):
            run = os.path.expanduser("~")
        elif w[k] == "-" or "$" in w[k] or SUBST in w[k] or not os.path.isdir(resolve(w[k], run or "/")):
            run = None
        elif run is not None or os.path.isabs(expand(w[k])):
            run = resolve(w[k], run or "/")
        return
    # Command position: past sudo / env / VAR=... / timeout 5 and similar runners.
    c = 0
    while c < len(w) and (w[c] in RUNNERS or w[c].startswith("-") or w[c].isdigit() or re.match(ASSIGN, w[c])):
        c += 1
    if c < len(w):
        cw = os.path.basename(w[c])
        if cw in DATA:
            return
        # `bash -c "<cmd>"` / `eval "<cmd>"` run their argument as a command line in a child.
        if cw == "eval":
            child(" ".join(w[c + 1:]))
            return
        if cw in SHELLS:
            # `-c`, `-lc`, `-xc`, `-c --`: the first operand after the options is the command.
            k, has_c = c + 1, False
            while k < len(w) and w[k][:1] in ("-", "+"):
                if w[k] == "--":
                    k += 1
                    break
                if re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", w[k]):
                    has_c = True
                elif w[k] in ("-o", "+o", "-O", "+O"):
                    k += 1
                k += 1
            if has_c:
                if k < len(w):
                    child(w[k])
                return
    for i, t in enumerate(w):
        if os.path.basename(expand(t)) != "git":
            continue
        d, j, gopts = run, i + 1, []
        while j < len(w) and w[j].startswith("-"):
            o = w[j]
            if o == "-C" and j + 1 < len(w):
                c_dir = expand(w[j + 1])
                d = resolve(c_dir, d) if d is not None or os.path.isabs(c_dir) else None
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
        if d is None:
            continue
        sub, rest = (w[j], w[j + 1:]) if j < len(w) else ("", [])
        if sub and sub not in BUILTINS:
            # A git alias that expands to push (`-c alias.p=push` or the config).
            val = ""
            for n in range(0, len(gopts) - 1):
                if gopts[n] == "-c" and gopts[n + 1].startswith("alias." + sub + "="):
                    val = gopts[n + 1].split("=", 1)[1]
            val = val or git(d, gopts, "config", "--get", "alias." + sub)
            if val.split()[:1] == ["push"]:
                sub, rest = "push", val.split()[1:] + rest
        if sub == "push" and "xargs" in [os.path.basename(x) for x in w[:i]]:
            emit(COMPUTED, d, "computed")  # xargs supplies the refspecs from stdin
        elif sub == "push":
            push(d, gopts, rest)
        elif sub in ("switch", "checkout"):
            switched(d, gopts, sub, rest)


def ansi_c(m):
    try:
        return shlex.quote(m.group(1).encode("latin-1", "backslashreplace").decode("unicode_escape"))
    except (UnicodeDecodeError, UnicodeEncodeError):
        return m.group(0)


def process(text):
    global run
    text = text.replace("\\\n", "")  # backslash line continuation
    text = re.sub(r"\$'((?:[^'\\]|\\.)*)'", ansi_c, text)
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



if __name__ == "__main__":
    process(cmd)
