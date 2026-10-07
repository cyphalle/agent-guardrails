#!/usr/bin/env bash
# hooks/lib/common.sh: paths shared by the gate, the audit and the unlock script.

GUARD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD_SENTINEL="${CLAUDE_GUARD_SENTINEL:-$HOME/.claude/guardrails-unlock}"
GUARD_AUDIT_DIR="${CLAUDE_GUARD_AUDIT_DIR:-$HOME/.claude/guardrails-audit}"
GUARD_SCHEDULED_JOBS="${CLAUDE_GUARD_SCHEDULED_JOBS:-$GUARD_ROOT/scheduled-jobs.json}"

# True when the sentinel holds an unexpired window on this scope, or on 'all'.
window_covers() {
  local scope="$1" now cur_scope cur_exp
  [[ -f "$GUARD_SENTINEL" ]] || return 1
  now=$(date +%s)
  cur_scope=$(jq -r '.scope // ""' "$GUARD_SENTINEL" 2>/dev/null || echo "")
  cur_exp=$(jq -r '.expires_at // 0' "$GUARD_SENTINEL" 2>/dev/null || echo 0)
  (( now < cur_exp )) && [[ "$cur_scope" == "$scope" || "$cur_scope" == "all" ]]
}
