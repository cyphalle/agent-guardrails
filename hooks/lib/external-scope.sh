#!/usr/bin/env bash
# hooks/lib/external-scope.sh: does this tier-3 scope need an explicit human yes?
#
# External means it leaves the company or commits a third party, and no revert catches up with
# it. Those scopes ask even with a human in front. The other tier-3 scopes stay tier 3 (denied
# with nobody in front, allow-listed for scheduled jobs) but do not interrupt a watched session.
#
# Fail-closed: a missing, unreadable or malformed file makes every scope external.

is_external_scope() {
  local scope="$1" f="${2:-}"
  if [[ -z "$f" ]]; then
    f="${CLAUDE_GUARD_EXTERNAL_SCOPES:-${CLAUDE_GUARD_CONFIG_DIR:-$HOME/.claude/guardrails}/external-scopes.json}"
    [[ -n "${CLAUDE_GUARD_EXTERNAL_SCOPES:-}" || -f "$f" ]] || f="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/external-scopes.json"
  fi
  [[ -f "$f" ]] || return 0
  jq -e '.external | type == "array"' "$f" >/dev/null 2>&1 || return 0
  jq -e --arg s "$scope" '.external | index($s)' "$f" >/dev/null 2>&1
}
