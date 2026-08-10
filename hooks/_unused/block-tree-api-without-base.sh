#!/usr/bin/env bash

set -euo pipefail

input="$(cat)"
command=""
if command -v jq >/dev/null 2>&1; then
  command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
elif [ "$#" -eq 0 ]; then
  # setup.sh refuses to install this hook without jq, but if jq later disappears
  # the PreToolUse hook must not block every ordinary Bash command.
  exit 0
fi

if [ -z "$command" ] && [ "$#" -gt 0 ]; then
  command="$*"
fi
if [ -z "$command" ]; then
  exit 0
fi

has_exact_base_tree_cli_field() {
  local text="$1"

  if printf '%s' "$text" \
    | grep -Eq '(^|[[:space:]])(--field|--raw-field)(=|[[:space:]]+)["'\'']?base_tree='; then
    return 0
  fi

  if printf '%s' "$text" \
    | grep -Eq '(^|[[:space:]])(-F|-f)([[:space:]]+["'\'']?base_tree=|["'\'']?base_tree=)'; then
    return 0
  fi

  return 1
}

has_exact_base_tree_json_key_text() {
  local text="$1"
  printf '%s' "$text" | grep -Eq '["'\'']base_tree["'\''][[:space:]]*:'
}

json_file_has_exact_base_tree_key() {
  local path="$1"

  if command -v jq >/dev/null 2>&1; then
    jq -e 'type == "object" and has("base_tree")' "$path" >/dev/null 2>&1 || return 1
    return 0
  fi

  has_exact_base_tree_json_key_text "$(cat "$path")"
}

# Permit single read-only inspection commands that merely mention gh api.
if [[ "$command" != *$'\n'* ]] \
  && ! printf '%s' "$command" | grep -qE '[;&|`<>]|\$\(' \
  && printf '%s' "$command" | grep -qE '^[[:space:]]*(grep|egrep|fgrep|cat|head|tail|wc|comm|diff|cut|tr|uniq|jq|ls|which|type|echo|printf)([[:space:]]|$)'; then
  exit 0
fi

if ! printf '%s' "$command" | grep -qE '(^|[^[:alnum:]_-])gh[[:space:]]+api([^[:alnum:]_-]|$)'; then
  exit 0
fi

normalized="$(printf '%s' "$command" | tr '\n' ' ')"

if ! [[ "$normalized" =~ (^|[[:space:]\"\'])/?repos/[^[:space:]\"\'\?]+/[^[:space:]\"\'\?]+/git/trees([[:space:]\"\'\?]|$) ]] \
  && ! [[ "$normalized" =~ (^|[[:space:]\"\'])https://api\.github\.com/repos/[^[:space:]\"\'\?]+/[^[:space:]\"\'\?]+/git/trees([[:space:]\"\'\?]|$) ]]; then
  exit 0
fi

if [[ "$normalized" =~ (^|[[:space:]])(--method(=|[[:space:]]+)GET|-X[[:space:]]*GET)([[:space:]]|$) ]]; then
  exit 0
fi

is_post=false
if [[ "$normalized" =~ (^|[[:space:]])(--method(=|[[:space:]]+)POST|-X[[:space:]]*POST)([[:space:]]|$) ]]; then
  is_post=true
fi
if [[ "$normalized" =~ (^|[[:space:]])(--field|--raw-field|-F|-f)(=|[[:space:]]|$) ]]; then
  is_post=true
fi
if [[ "$normalized" =~ (^|[[:space:]])--input(=|[[:space:]]|$) ]]; then
  is_post=true
fi

if [ "$is_post" != "true" ]; then
  exit 0
fi

if has_exact_base_tree_cli_field "$normalized"; then
  exit 0
fi

if [[ "$normalized" =~ (^|[[:space:]])--input(=|[[:space:]]+)-([[:space:]]|$) ]] \
  && has_exact_base_tree_json_key_text "$normalized"; then
  exit 0
fi

input_path="$(
  printf '%s' "$normalized" \
    | sed -nE 's/.*--input[ =]([^[:space:];|&]+).*/\1/p' \
    | tail -1 \
    | sed -E 's/^["'\'']|["'\'']$//g'
)"
if [ -n "$input_path" ] && [ "$input_path" != "-" ] && [ -f "$input_path" ]; then
  if json_file_has_exact_base_tree_key "$input_path"; then
    exit 0
  fi
fi

echo "base_tree is required for gh api git/trees POST" >&2
echo "Include base_tree in the JSON payload or pass --field base_tree=<tree-sha>." >&2
exit 2
