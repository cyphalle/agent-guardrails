#!/usr/bin/env bash
# hooks/pr-guard-post.sh: PostToolUse hook. After a PR is created (gh CLI or GitHub MCP), read
# the REAL state of the PR and tell the agent to repair a missing reviewer or assignee.
#
# Why after and not before: a PreToolUse version refused `gh pr create` without the flags. It
# only sent the agent to replay the same command with one more flag, and it could not see the
# MCP path, `gh pr create --web`, or flags that GitHub silently drops. Reading the PR after the
# fact covers every path, and the repair costs one `gh pr edit`.
set -u

source "$(dirname "$0")/lib/common.sh"
CONFIG="${CLAUDE_GUARD_PR_CONFIG:-$GUARD_ROOT/pr-guard.json}"
[ -f "$CONFIG" ] || exit 0

payload=$(cat)
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0

case "$tool" in
  Bash)
    cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')
    # `gh pr create` must be in COMMAND POSITION. Otherwise a mere quote of the pattern (a grep,
    # a cat of a skill file) triggers the guard. That false positive happened.
    printf '%s' "$cmd" | grep -qE '(^|[;&|(){}]|[[:space:]](do|then|else)[[:space:]])[[:space:]]*(sudo[[:space:]]+)?gh[[:space:]]+pr[[:space:]]+create' || exit 0
    ;;
  *create_pull_request*) ;;
  *) exit 0 ;;
esac

response=$(printf '%s' "$payload" | jq -r '.tool_response | tostring' 2>/dev/null)
url=$(printf '%s' "$response" | grep -oE 'https://github\.com/[^"[:space:]\\]+/pull/[0-9]+' | head -1)
[ -z "$url" ] && exit 0

repo=$(printf '%s' "$url" | sed -E 's#https://github.com/([^/]+/[^/]+)/pull/.*#\1#')
assignee=$(jq -r '.assignee // empty' "$CONFIG")
norev=$(jq -r --arg r "$repo" '(.no_reviewer // []) | index($r) | if . == null then 0 else 1 end' "$CONFIG")

info=$(gh pr view "$url" --json reviewRequests,latestReviews,assignees,files 2>/dev/null) || exit 0
[ -z "$info" ] && exit 0

nrev=$(printf '%s' "$info" | jq '((.reviewRequests // []) | length) + ((.latestReviews // []) | length)')
nass=$(printf '%s' "$info" | jq '((.assignees // []) | length)')

# Reviewers deduced from the diff: the first matching prefix of each file, deduplicated.
suggested=$(jq -r --argjson info "$info" '
  [ $info.files[]?.path as $p
    | (.reviewers // []) | map(select(.prefix as $x | $p | startswith($x))) | first | .reviewer? ]
  | map(select(. != null)) | unique | join(",")' "$CONFIG")

lack=""
[ "$norev" -eq 0 ] && [ "${nrev:-0}" -eq 0 ] && lack="no reviewer"
[ "${nass:-0}" -eq 0 ] && lack="${lack:+$lack and }no assignee"
[ -z "$lack" ] && exit 0

fix="gh pr edit ${url}"
[ "${nass:-0}" -eq 0 ] && [ -n "$assignee" ] && fix="$fix --add-assignee $assignee"
if [ "$norev" -eq 0 ] && [ "${nrev:-0}" -eq 0 ]; then
  fix="$fix --add-reviewer ${suggested:-<reviewer chosen from the layer of the diff>}"
fi

ctx="The PR ${url} was just created with ${lack}. Fix it NOW, before any other action and without asking: ${fix}."
[ "$norev" -eq 1 ] && ctx="$ctx This repo deliberately ships without a reviewer: add none."

jq -nc --arg c "$ctx" --arg u "$url" '{
  systemMessage: ("PR guard: " + $u + " incomplete, repair in progress"),
  hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: $c }
}'
exit 0
