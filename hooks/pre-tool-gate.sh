#!/usr/bin/env bash
# hooks/pre-tool-gate.sh: PreToolUse hook. Gates tier-3 calls on the absence of a human.
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"
source "$GUARD_ROOT/hooks/lib/supervised.sh"
source "$GUARD_ROOT/hooks/lib/external-scope.sh"

INPUT=$(cat)
PERMISSION_MODE=$(echo "$INPUT" | jq -r '.permission_mode // ""')

eval "$(echo "$INPUT" | bash "$GUARD_ROOT/hooks/lib/tier-lookup.sh")"

# Tier 1 and tier 2 pass silently. Tier 2 is audited after the fact by post-tool-audit.sh.
[[ "$TIER" == "1" || "$TIER" == "2" ]] && exit 0

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

audit_prompt() {
  mkdir -p "$GUARD_AUDIT_DIR" 2>/dev/null || return 0
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg scope "$SCOPE" --arg answer "$1" \
    '{ts: $ts, event: "t3-prompt", scope: $scope, answer: $answer}' \
    >> "$GUARD_AUDIT_DIR/$(date -u +%Y-%m-%d).jsonl" 2>/dev/null || true
}

# Tier 3. The lock is about the absence of a human, not the nature of the action.

# 1. Scheduled job: explicit allowlist, least privilege, fail-closed.
# CLAUDE_GUARD_SCHEDULED_JOB is set by the launchd plist or the cron line and inherited by
# claude, then by this hook. An interactive session cannot forge it: its Bash mutates a
# subshell, not the env of the claude process.
JOB="${CLAUDE_GUARD_SCHEDULED_JOB:-}"
if [[ -n "$JOB" ]]; then
  if [[ -f "$GUARD_SCHEDULED_JOBS" ]] && jq -e --arg j "$JOB" --arg s "$SCOPE" '(.[$j].scopes // []) | index($s)' "$GUARD_SCHEDULED_JOBS" >/dev/null 2>&1; then
    exit 0
  fi
  deny "Tier-3 action blocked ($SCOPE). Scheduled job $JOB is not allow-listed for this scope. Add it to scheduled-jobs.json if intended (least privilege, fail-closed)."
fi

# 2. A window is already open on this scope: pass silently.
window_covers "$SCOPE" && exit 0

# 3. A human is in front: ask in the thread, instead of sending them to type a command in
# another terminal. A yes opens a window (see post-tool-audit.sh) for the rest of the series.
if supervised; then
  # Internal or reversible tier 3 (push to main, force push, dev database): someone watches the
  # thread and the audit keeps the trace, so do not interrupt. It stays tier 3, so it is still
  # denied as soon as nobody is in front.
  if ! is_external_scope "$SCOPE"; then
    exit 0
  fi

  # Outside bypass mode, the harness shows its own prompt: delegate to it.
  if [[ "$PERMISSION_MODE" != "bypassPermissions" ]]; then
    jq -n --arg scope "$SCOPE" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: "Tier-3 action: external and irreversible (scope: \($scope)). A yes opens a window on this scope for the rest of the series."
      }
    }'
    exit 0
  fi

  # Under --dangerously-skip-permissions, an `ask` is swallowed and acts as an allow: a tier-3
  # action went through with no prompt and no window when this was first tested. So keep the
  # human in the loop with a native dialog and decide here. Fail-closed: a refusal, a timeout,
  # or no screen at all is a deny.
  ACTION=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_name' | head -c 200)
  ANSWER="NO_DIALOG"
  if command -v osascript >/dev/null 2>&1; then
    ANSWER=$(osascript - "$SCOPE" "$ACTION" <<'OSA' 2>/dev/null || echo ERROR
on run argv
  set s to item 1 of argv
  set d to item 2 of argv
  set r to display dialog "External, irreversible action." & return & return & "scope: " & s & return & return & d with title "claude-guardrails" buttons {"Deny", "Allow"} default button "Allow" giving up after 45
  if gave up of r then return "TIMEOUT"
  return button returned of r
end run
OSA
)
  fi
  audit_prompt "$ANSWER"

  if [[ "$ANSWER" == "Allow" ]]; then
    jq -n --arg scope "$SCOPE" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        permissionDecisionReason: "Tier-3 (\($scope)) approved by hand."
      }
    }'
    exit 0
  fi
  deny "Tier-3 action blocked ($SCOPE). Refused at validation ($ANSWER). Do not retry: report it."
fi

# 4. Nobody in front and no declared job: deny.
deny "Tier-3 action blocked ($SCOPE). No human in the loop and no active unlock. Run \`bin/unlock --scope $SCOPE --duration 30m\` from your own terminal."
