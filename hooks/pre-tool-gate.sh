#!/usr/bin/env bash
# hooks/pre-tool-gate.sh: PreToolUse hook. Gates tier-3 calls on the absence of a human.
#
# Fail-closed on its own errors: a missing jq, a malformed input or any failing command ends in
# exit 2, which Claude Code treats as a block. A gate that crashes must never let the call pass.
set -euo pipefail

fail() {
  echo "agent-guardrails: $1. The call is blocked; fix the guard, do not work around it." >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || fail "jq is not installed"
trap 'fail "internal error in pre-tool-gate.sh at line $LINENO"' ERR

# shellcheck source=hooks/lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=hooks/lib/external-scope.sh
source "$GUARD_ROOT/hooks/lib/external-scope.sh"

INPUT=$(cat)
PERMISSION_MODE=$(jq -r '.permission_mode // ""' <<< "$INPUT")
SESSION_ID=$(jq -r '.session_id // ""' <<< "$INPUT")
TOOL=$(jq -r '.tool_name // ""' <<< "$INPUT")

# The lookup prints KEY=value lines. Read them one by one: never eval them, a scope is data.
LOOKUP=$(bash "$GUARD_ROOT/hooks/lib/tier-lookup.sh" <<< "$INPUT")
TIER="" SCOPE="" MATCH="" REASON=""
while IFS= read -r line; do
  case "$line" in
    TIER=*)   TIER="${line#TIER=}" ;;
    SCOPE=*)  SCOPE="${line#SCOPE=}" ;;
    MATCH=*)  MATCH="${line#MATCH=}" ;;
    REASON=*) REASON="${line#REASON=}" ;;
  esac
done <<< "$LOOKUP"
[[ "$TIER" =~ ^[123]$ ]] || fail "the tier lookup returned no tier"

# Tier 1 and tier 2 pass silently. Tier 2 is audited after the fact by post-tool-audit.sh.
[[ "$TIER" == "3" ]] || exit 0

decide() {
  jq -n --arg d "$1" --arg reason "$2" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $d,
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# Denials are logged too, so the log shows what was stopped and not only what ran.
deny() {
  guard_audit "$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg tool "$TOOL" --arg scope "$SCOPE" \
    --arg session "$SESSION_ID" --arg reason "$1" \
    '{ts: $ts, event: "t3-deny", tool: $tool, scope: $scope, session_id: $session, reason: $reason}')"
  decide deny "$1"
}

audit_prompt() {
  guard_audit "$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg scope "$SCOPE" --arg answer "$1" \
    --arg session "$SESSION_ID" '{ts: $ts, event: "t3-prompt", scope: $scope, session_id: $session, answer: $answer}')"
}

LOCKED=false
is_locked_scope "$SCOPE" && LOCKED=true
WHY="${REASON:+ $REASON.}"

# Tier 3. The lock is about the absence of a human, not the nature of the action.

# 1. Scheduled job: explicit allowlist, least privilege, fail-closed. guard_job returns the job
# name only for a claude with no terminal and no claude ancestor, so neither an interactive
# session nor a claude started by an agent can claim one. A locked scope is never granted.
JOB=$(guard_job)
if [[ -n "$JOB" ]]; then
  if [[ "$LOCKED" == false && -f "$GUARD_SCHEDULED_JOBS" ]] \
     && jq -e --arg j "$JOB" --arg s "$SCOPE" '(.[$j].scopes // []) | index($s)' "$GUARD_SCHEDULED_JOBS" >/dev/null 2>&1; then
    exit 0
  fi
  deny "Tier-3 action blocked ($SCOPE).$WHY Scheduled job $JOB is not allow-listed for this scope. Add it to scheduled-jobs.json if intended (least privilege, fail-closed)."
fi

# 2. A window is already open on this scope for this session: pass silently.
window_covers "$SCOPE" "$SESSION_ID" && exit 0

# 3. A human is in front.
if supervised; then
  # Internal or reversible tier 3 (push to main, force push, dev database): someone watches the
  # thread and the audit keeps the trace, so do not interrupt. It stays tier 3, so it is still
  # denied as soon as nobody is in front. Locked scopes always ask.
  if [[ "$LOCKED" == false ]] && ! is_external_scope "$SCOPE"; then
    exit 0
  fi

  if [[ "$LOCKED" == true ]]; then
    ASK_REASON="Tier-3 action on the guard itself (scope: $SCOPE).$WHY Approving it opens no window."
  else
    ASK_REASON="Tier-3 action: external and irreversible (scope: $SCOPE). A yes opens a window on this scope for the rest of this session's series."
  fi

  # Outside bypass mode, the harness shows its own prompt: delegate to it.
  [[ "$PERMISSION_MODE" == "bypassPermissions" ]] || decide ask "$ASK_REASON"

  # In bypass mode the gate never relies on `ask`: it shows its own confirmation dialog, and
  # with no screen attached it denies. The dialog shows what will run (the matched command, or
  # the main arguments of an MCP call) and Deny is the default button. A refusal, a timeout or
  # no dialog at all is a deny.
  if [[ -n "$MATCH" ]]; then
    DETAIL="$TOOL: $MATCH"
  else
    DETAIL=$(jq -r '.tool_name + "\n" + ((.tool_input // {}) | to_entries
      | map("\(.key): \(.value | tostring | .[0:160])") | .[0:8] | join("\n"))' <<< "$INPUT")
  fi
  DETAIL="${DETAIL:0:700}"
  ANSWER="NO_DIALOG"
  if command -v osascript >/dev/null 2>&1; then
    ANSWER=$(osascript - "$SCOPE" "$DETAIL" "$ASK_REASON" <<'OSA' 2>/dev/null || echo ERROR
on run argv
  set s to item 1 of argv
  set d to item 2 of argv
  set w to item 3 of argv
  set r to display dialog w & return & return & "scope: " & s & return & return & d with title "agent-guardrails" buttons {"Allow", "Deny"} default button "Deny" with icon caution giving up after 60
  if gave up of r then return "TIMEOUT"
  return button returned of r
end run
OSA
)
  fi
  audit_prompt "$ANSWER"

  [[ "$ANSWER" == "Allow" ]] && decide allow "Tier-3 ($SCOPE) approved by hand."
  deny "Tier-3 action blocked ($SCOPE).$WHY Refused at validation ($ANSWER). Do not retry: report it."
fi

# 4. Nobody in front and no declared job: deny.
deny "Tier-3 action blocked ($SCOPE).$WHY No human in the loop and no active unlock. A human can run \`bin/unlock --scope $SCOPE --duration 30m\` from their own terminal."
