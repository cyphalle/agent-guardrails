#!/usr/bin/env bash
# hooks/post-tool-audit.sh: PostToolUse hook. Appends tier-2 and tier-3 calls to a daily JSONL
# log, and opens a scope window after a tier-3 call that a human approved.
set -euo pipefail

fail() { echo "agent-guardrails audit: $1. This call was not logged." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is not installed"
trap 'fail "internal error in post-tool-audit.sh at line $LINENO"' ERR

# shellcheck source=hooks/lib/common.sh
source "$(dirname "$0")/lib/common.sh"

INPUT=$(cat)
LOOKUP=$(bash "$GUARD_ROOT/hooks/lib/tier-lookup.sh" <<< "$INPUT")
TIER="" SCOPE=""
while IFS= read -r line; do
  case "$line" in
    TIER=*)  TIER="${line#TIER=}" ;;
    SCOPE=*) SCOPE="${line#SCOPE=}" ;;
  esac
done <<< "$LOOKUP"

[[ "$TIER" == "1" ]] && exit 0

mkdir -p "$GUARD_AUDIT_DIR"
LOG="$GUARD_AUDIT_DIR/$(date -u +%Y-%m-%d).jsonl"

# The arguments are stored as a sha256, not in clear: the log can confirm that a given call ran
# without keeping message bodies or tokens. It is a plain file owned by you, so it is a record,
# not a tamper-proof one: any process running as you can edit it. The guard gates writes to it
# from the agent's own tools, nothing more.
ARGS=$(jq -c '.tool_input // {}' <<< "$INPUT")
ARGS_HASH=$(printf '%s' "$ARGS" | shasum -a 256 | awk '{print $1}')
TOOL=$(jq -r '.tool_name' <<< "$INPUT")
SESSION_ID=$(jq -r '.session_id // ""' <<< "$INPUT")
WINDOWS=$(guard_windows | jq -sc '[.[] | {scope, origin}]')

jq -nc \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg tool "$TOOL" \
  --arg tier "$TIER" \
  --arg scope "$SCOPE" \
  --arg hash "$ARGS_HASH" \
  --arg session "$SESSION_ID" \
  --argjson windows "$WINDOWS" \
  --arg scheduled_job "$(guard_job)" \
  --argjson nested "$GUARD_NESTED" \
  '{ts: $ts, tool: $tool, tier: ($tier | tonumber), scope: $scope, args_hash: $hash, session_id: $session,
    open_windows: $windows, unlock_active: ($windows | length > 0), scheduled_job: $scheduled_job, nested: ($nested == 1)}' \
  >> "$LOG"

# --- Scope window: the first yes covers the series --------------------------------------------
# A tier-3 call on an external scope that completes in a supervised session can only have passed
# through a human yes (or a manual unlock). Open a window on that one scope, for this session
# only, so a series of commands (a release, a diagnostic pass) does not ask at every step.
#
# Never for a scheduled job (it must not widen itself a window beyond its own run), never for a
# locked scope (each write to the guard's configuration is approved on its own), and never
# without a session id to bind it to.
if [[ "$TIER" == "3" && -n "$SCOPE" && -n "$SESSION_ID" && -z "$(guard_job)" ]] && ! is_locked_scope "$SCOPE"; then
  # shellcheck source=hooks/lib/external-scope.sh
  source "$GUARD_ROOT/hooks/lib/external-scope.sh"
  if supervised && is_external_scope "$SCOPE" && ! window_covers "$SCOPE" "$SESSION_ID"; then
    # A database write gets a short window: it is the one that costs the most if left open.
    case "$SCOPE" in
      db-*) WINDOW_SEC=1800 ;;
      *)    WINDOW_SEC=7200 ;;
    esac
    guard_add_window "$SCOPE" "$WINDOW_SEC" auto-window "$SESSION_ID"
  fi
fi
exit 0
