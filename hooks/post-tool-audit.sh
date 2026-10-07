#!/usr/bin/env bash
# hooks/post-tool-audit.sh: PostToolUse hook. Appends tier-2 and tier-3 calls to a daily JSONL
# log, and opens a scope window after a tier-3 call that a human approved.
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"

INPUT=$(cat)
eval "$(echo "$INPUT" | bash "$GUARD_ROOT/hooks/lib/tier-lookup.sh")"

[[ "$TIER" == "1" ]] && exit 0

mkdir -p "$GUARD_AUDIT_DIR"
LOG="$GUARD_AUDIT_DIR/$(date -u +%Y-%m-%d).jsonl"

# Hash the arguments: the log proves what ran without storing message bodies or tokens.
ARGS=$(echo "$INPUT" | jq -c '.tool_input // {}')
ARGS_HASH=$(printf '%s' "$ARGS" | shasum -a 256 | awk '{print $1}')
TOOL=$(echo "$INPUT" | jq -r '.tool_name')

UNLOCK_ACTIVE=false
UNLOCK_SCOPE=""
if [[ -f "$GUARD_SENTINEL" ]]; then
  EXP=$(jq -r '.expires_at // 0' "$GUARD_SENTINEL" 2>/dev/null || echo 0)
  if (( $(date +%s) < EXP )); then
    UNLOCK_ACTIVE=true
    UNLOCK_SCOPE=$(jq -r '.scope' "$GUARD_SENTINEL")
  fi
fi

jq -nc \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg tool "$TOOL" \
  --arg tier "$TIER" \
  --arg scope "${SCOPE:-}" \
  --arg hash "$ARGS_HASH" \
  --argjson unlock_active "$UNLOCK_ACTIVE" \
  --arg unlock_scope "$UNLOCK_SCOPE" \
  --arg scheduled_job "${CLAUDE_GUARD_SCHEDULED_JOB:-}" \
  '{ts: $ts, tool: $tool, tier: ($tier|tonumber), scope: $scope, args_hash: $hash, unlock_active: $unlock_active, unlock_scope: $unlock_scope, scheduled_job: $scheduled_job}' \
  >> "$LOG"

# --- Scope window: the first yes covers the series --------------------------------------------
# A tier-3 call that completes in a supervised session can only have passed through a human yes
# (or a manual unlock). Open a window on that one scope, so a series of commands (a release, a
# diagnostic pass) does not ask at every step.
#
# Restricted to supervised sessions on purpose: a scheduled job that passes through its
# allowlist must not widen itself a window beyond its own run.
if [[ "$TIER" == "3" && -n "${SCOPE:-}" && -z "${CLAUDE_GUARD_SCHEDULED_JOB:-}" ]]; then
  source "$GUARD_ROOT/hooks/lib/supervised.sh"
  source "$GUARD_ROOT/hooks/lib/external-scope.sh"
  if supervised && is_external_scope "$SCOPE"; then
    # Never touch a valid window. Extending it forever would turn one yes into a blank cheque,
    # and overwriting it would shrink a manual 'all' unlock.
    if ! window_covers "$SCOPE"; then
      # A database write gets a short window: it is the one that costs the most if left open.
      case "$SCOPE" in
        db-*) WINDOW_SEC=1800 ;;
        *)    WINDOW_SEC=7200 ;;
      esac
      NOW=$(date +%s)
      mkdir -p "$(dirname "$GUARD_SENTINEL")"
      jq -n \
        --arg scope "$SCOPE" \
        --argjson expires "$(( NOW + WINDOW_SEC ))" \
        --argjson created "$NOW" \
        --arg origin "auto-window" \
        '{scope: $scope, expires_at: $expires, created_at: $created, origin: $origin}' \
        > "$GUARD_SENTINEL"
    fi
  fi
fi
