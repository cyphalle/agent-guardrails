#!/usr/bin/env bash
# shellcheck shell=bash
# hooks/lib/common.sh: paths and window helpers shared by the hooks and bin/.

GUARD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=hooks/lib/supervised.sh
source "$GUARD_ROOT/hooks/lib/supervised.sh"

# A nested claude (one started by an agent from its own Bash tool) inherits an environment the
# agent wrote. Its CLAUDE_GUARD_* variables would let it point the gate at an empty rules folder,
# a forged window or a job allowlist, and its HOME would do the same through the defaults. So in
# a nested session both are dropped: the variables are unset and HOME comes from the user
# database. CLAUDE_GUARD_ASSUME_UNSUPERVISED stays, because it can only harden.
GUARD_NESTED=0
if guard_nested; then
  GUARD_NESTED=1
  while IFS= read -r _v; do
    [[ "$_v" == CLAUDE_GUARD_ASSUME_UNSUPERVISED ]] || unset "$_v"
  done < <(compgen -v CLAUDE_GUARD_ || true)
  _u=$(id -un 2>/dev/null || true)
  if [[ "$_u" =~ ^[A-Za-z0-9._-]+$ ]]; then
    eval "_h=~$_u"
    # shellcheck disable=SC2154
    [[ -d "$_h" ]] && HOME="$_h"
  fi
  unset _v _u _h
fi

# User config lives outside the repo, so a plugin update never overwrites it.
GUARD_CONFIG_DIR="${CLAUDE_GUARD_CONFIG_DIR:-$HOME/.claude/guardrails}"
GUARD_SENTINEL="${CLAUDE_GUARD_SENTINEL:-$HOME/.claude/guardrails-unlock}"
GUARD_AUDIT_DIR="${CLAUDE_GUARD_AUDIT_DIR:-$HOME/.claude/guardrails-audit}"
# shellcheck disable=SC2034  # read by the scripts that source this file
GUARD_SCHEDULED_JOBS="${CLAUDE_GUARD_SCHEDULED_JOBS:-$GUARD_CONFIG_DIR/scheduled-jobs.json}"

# A window can never last longer than this, whatever the sentinel file claims.
GUARD_MAX_WINDOW=86400

# Scopes that protect the guard itself. No automatic window, no 'all' window and no scheduled
# job covers them: only a manual window on that exact scope, opened by bin/unlock.
GUARD_LOCKED_SCOPES="guard-config guard-misconfigured"
is_locked_scope() {
  case " $GUARD_LOCKED_SCOPES " in *" $1 "*) return 0 ;; esac
  return 1
}

# The scheduled-job name, or nothing. Honoured only with no claude ancestor and no terminal in
# the chain: a job started by launchd or cron. A nested claude has had the variable unset above.
guard_job() {
  [[ -n "${CLAUDE_GUARD_SCHEDULED_JOB:-}" ]] || return 0
  [[ "$GUARD_NESTED" == 0 ]] || return 0
  if supervised; then return 0; fi
  printf '%s' "$CLAUDE_GUARD_SCHEDULED_JOB"
}

# Valid windows, one JSON object per line. The sentinel holds {"windows": [...]}; a single legacy
# object is still read. A window is valid only if it is unexpired, was created in the past, and
# spans at most GUARD_MAX_WINDOW seconds both from its creation and from now. A window without
# created_at is invalid.
guard_windows() {
  [[ -f "$GUARD_SENTINEL" ]] || return 0
  jq -c --argjson now "$(date +%s)" --argjson max "$GUARD_MAX_WINDOW" '
    (if type == "object" and has("windows") then .windows
     elif type == "object" then [.] else [] end)
    | (if type == "array" then .[] else empty end)
    | select(type == "object")
    | select((.scope | type) == "string" and (.expires_at | type) == "number" and (.created_at | type) == "number")
    | select(.expires_at > $now and .created_at <= $now + 60
             and (.expires_at - .created_at) <= $max and (.expires_at - $now) <= $max)
  ' "$GUARD_SENTINEL" 2>/dev/null || true
}

# True when a valid window covers this scope for this session.
#  - An automatic window carries the session that opened it and covers only that session.
#  - A manual window (bin/unlock) carries no session and covers every session.
#  - A locked scope is covered only by a manual window on that exact scope.
window_covers() {
  local scope="$1" session="${2:-}" locked=false
  is_locked_scope "$scope" && locked=true
  guard_windows | jq -s -e --arg s "$scope" --arg sess "$session" --argjson locked "$locked" '
    any(.[];
      (if $locked then (.scope == $s and .origin == "manual" and (has("session_id") | not))
       else (.scope == $s or .scope == "all") end)
      and ((has("session_id") | not) or (.session_id != "" and .session_id == $sess)))
  ' >/dev/null 2>&1
}

# Append a window, dropping the expired ones. Written to a temp file and moved, so a reader never
# sees half a file.
guard_add_window() {
  local scope="$1" seconds="$2" origin="$3" session="${4:-}" now tmp
  now=$(date +%s)
  mkdir -p "$(dirname "$GUARD_SENTINEL")"
  tmp=$(mktemp "$GUARD_SENTINEL.XXXXXX")
  guard_windows | jq -s \
    --arg scope "$scope" --argjson exp "$((now + seconds))" --argjson now "$now" \
    --arg origin "$origin" --arg sess "$session" '
    {windows: (. + [{scope: $scope, expires_at: $exp, created_at: $now, origin: $origin}
                    + (if $sess == "" then {} else {session_id: $sess} end)])}
  ' > "$tmp"
  mv "$tmp" "$GUARD_SENTINEL"
}

guard_audit() {
  mkdir -p "$GUARD_AUDIT_DIR" 2>/dev/null || return 0
  printf '%s\n' "$1" >> "$GUARD_AUDIT_DIR/$(date -u +%Y-%m-%d).jsonl" 2>/dev/null || true
}
