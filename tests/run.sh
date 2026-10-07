#!/usr/bin/env bash
# tests/run.sh: run every test against a throwaway sentinel and audit dir.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export CLAUDE_GUARD_SENTINEL="$TMP/unlock"
export CLAUDE_GUARD_AUDIT_DIR="$TMP/audit"
export CLAUDE_GUARD_SCHEDULED_JOBS="$TMP/scheduled-jobs.json"
unset CLAUDE_GUARD_SCHEDULED_JOB

LOOKUP="$ROOT/hooks/lib/tier-lookup.sh"
GATE="$ROOT/hooks/pre-tool-gate.sh"
AUDIT="$ROOT/hooks/post-tool-audit.sh"

pass=0
fail() { echo "FAIL: $1"; exit 1; }
ok()   { pass=$((pass + 1)); }

bash_call() { jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'; }
tier_of()   { bash_call "$1" | bash "$LOOKUP"; }
expect()    { local out; out=$(tier_of "$1"); echo "$out" | grep -q "^TIER=$2$" || fail "'$1' should be T$2 ($out)"; ok; }
expect_scope() { local out; out=$(tier_of "$1"); echo "$out" | grep -q "^SCOPE=$2$" || fail "'$1' should be scope $2 ($out)"; ok; }

# --- tier lookup ------------------------------------------------------------------------------
out=$(echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}' | bash "$LOOKUP")
echo "$out" | grep -q "^TIER=1$" || fail "unknown tool should be T1"; ok

expect "git push origin main" 3
expect_scope "git push origin main" gh-merge-main
expect "git push origin HEAD:main" 3
expect "git push origin main --force" 3
expect_scope "git push origin main --force" gh-force
expect "git push --force origin develop" 3
expect "git push origin develop" 1
expect "git push origin update-domain" 1
expect "npm install --force" 1
expect "git branch -D old-feature" 3

# A rule matches ONE command, never across shell separators.
expect "git push origin HEAD 2>&1 | tail -2; pgrep -f run-job.sh" 1
expect "ps -o etime= -p 1 && git push origin HEAD" 1
expect 'git push origin HEAD; echo "done: main"' 1
# ...and an anchored rule now sees the command after a separator.
expect "cd repo && git push --force origin feat" 3
# A backslash continuation is folded before the split.
expect $'git push \\\n  --force origin feat' 3

# Database: the port decides, the read-only wrapper is free.
expect "db-readonly tables prod" 2
expect "pg_restore -h localhost -p 25432 -d app dump.sql" 3
expect_scope "pg_restore -h localhost -p 25432 -d app dump.sql" db-write
expect "DATABASE_URL=postgres://u:p@localhost:25432/app cargo run" 3
expect "pgcli -h localhost -p 15432 app" 3
expect_scope "pgcli -h localhost -p 15432 app" db-dev
expect "psql -h localhost -p 5432 app" 1
expect "echo 'psql -p 25432' > notes.md" 1
expect 'psql -h prod.abc.eu-west-1.rds.amazonaws.com -c "select 1"' 3

# MCP tools.
out=$(echo '{"tool_name":"mcp__google-workspace__send_email","tool_input":{}}' | bash "$LOOKUP")
echo "$out" | grep -q "^TIER=3$" || fail "send_email should be T3"; ok
out=$(echo '{"tool_name":"mcp__google-workspace__draft_email","tool_input":{}}' | bash "$LOOKUP")
echo "$out" | grep -q "^TIER=1$" || fail "draft_email should be T1"; ok

# --- gate, nobody in front --------------------------------------------------------------------
SEND='{"tool_name":"mcp__google-workspace__send_email","tool_input":{"to":"x@y.com"}}'
headless() { echo "$1" | CLAUDE_GUARD_ASSUME_UNSUPERVISED=1 bash "$GATE"; }
decision() { jq -r '.hookSpecificOutput.permissionDecision // "silent"' <<< "${1:-{\}}"; }
window()   { jq -n --arg s "$1" --argjson e "$(( $(date +%s) + $2 ))" '{scope: $s, expires_at: $e}' > "$CLAUDE_GUARD_SENTINEL"; }

[[ -z "$(headless '{"tool_name":"Read","tool_input":{}}')" ]] || fail "T1 should be silent"; ok
[[ "$(decision "$(headless "$SEND")")" == deny ]] || fail "headless T3 should deny"; ok
window gmail-send 1800
[[ -z "$(headless "$SEND")" ]] || fail "matching window should pass"; ok
window gmail-send -1
[[ "$(decision "$(headless "$SEND")")" == deny ]] || fail "expired window should deny"; ok
window gh-release 1800
[[ "$(decision "$(headless "$SEND")")" == deny ]] || fail "wrong-scope window should deny"; ok
window all 1800
[[ -z "$(headless "$SEND")" ]] || fail "'all' window should pass"; ok
rm -f "$CLAUDE_GUARD_SENTINEL"

# Scheduled jobs: allowlist only.
echo '{"release-job":{"scopes":["gh-release"]}}' > "$CLAUDE_GUARD_SCHEDULED_JOBS"
out=$(bash_call "gh release create v1" | CLAUDE_GUARD_SCHEDULED_JOB=release-job CLAUDE_GUARD_ASSUME_UNSUPERVISED=1 bash "$GATE")
[[ -z "$out" ]] || fail "allow-listed job scope should pass ($out)"; ok
out=$(echo "$SEND" | CLAUDE_GUARD_SCHEDULED_JOB=release-job CLAUDE_GUARD_ASSUME_UNSUPERVISED=1 bash "$GATE")
[[ "$(decision "$out")" == deny ]] || fail "job scope outside its allowlist should deny"; ok

# --- gate, human in front (only when the test itself runs in a terminal) ----------------------
if bash -c "source '$ROOT/hooks/lib/supervised.sh'; supervised"; then
  [[ "$(decision "$(echo "$SEND" | bash "$GATE")")" == ask ]] || fail "supervised external T3 should ask"; ok
  [[ -z "$(bash_call "git push origin main" | bash "$GATE")" ]] || fail "supervised internal T3 should pass"; ok
  [[ "$(decision "$(bash_call "psql -p 25432 app" | bash "$GATE")")" == ask ]] || fail "supervised prod write should ask"; ok
else
  echo "skip: supervised cases (no TTY)"
fi

# --- audit ------------------------------------------------------------------------------------
echo '{"tool_name":"Read","tool_input":{}}' | bash "$AUDIT"
[[ ! -d "$CLAUDE_GUARD_AUDIT_DIR" ]] || fail "T1 should not be audited"; ok
echo '{"tool_name":"mcp__plugin_slack_slack__slack_send_message","tool_input":{"text":"hi"}}' | bash "$AUDIT"
LOG="$CLAUDE_GUARD_AUDIT_DIR/$(date -u +%Y-%m-%d).jsonl"
[[ "$(tail -1 "$LOG" | jq -r .tier)" == 2 ]] || fail "T2 should be audited"; ok
[[ "$(tail -1 "$LOG" | jq -r '.args_hash | length')" == 64 ]] || fail "args should be a sha256"; ok
grep -q '"hi"' "$LOG" && fail "the log must not store arguments in clear"; ok

# --- unlock refuses a non-TTY stdin ----------------------------------------------------------
if echo | bash "$ROOT/bin/unlock" --scope gmail-send 2>/dev/null; then fail "unlock must refuse without a TTY"; fi; ok

# --- PR guard, with a stubbed gh ---------------------------------------------------------------
mkdir -p "$TMP/bin"
printf '%s\n' '#!/usr/bin/env bash' \
  "echo '{\"reviewRequests\":[],\"latestReviews\":[],\"assignees\":[],\"files\":[{\"path\":\"backend/a.rs\"},{\"path\":\"frontend/b.vue\"},{\"path\":\"README.md\"}]}'" \
  > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
pr_guard() { echo "$1" | PATH="$TMP/bin:$PATH" CLAUDE_GUARD_PR_CONFIG="$ROOT/examples/pr-guard.json" bash "$ROOT/hooks/pr-guard-post.sh"; }
CREATED='{"tool_name":"Bash","tool_input":{"command":"gh pr create --title x"},"tool_response":{"stdout":"https://github.com/acme/app/pull/12"}}'
ctx=$(pr_guard "$CREATED" | jq -r .hookSpecificOutput.additionalContext)
[[ "$ctx" == *"--add-assignee your-github-login"* ]] || fail "PR guard should add the assignee ($ctx)"; ok
[[ "$ctx" == *"--add-reviewer backend-owner-login,frontend-owner-login"* ]] || fail "PR guard should deduce reviewers from the diff ($ctx)"; ok
QUOTED='{"tool_name":"Bash","tool_input":{"command":"grep \"gh pr create\" skill.md"},"tool_response":{"stdout":"https://github.com/acme/app/pull/12"}}'
[[ -z "$(pr_guard "$QUOTED")" ]] || fail "a quoted gh pr create must not trigger the guard"; ok

echo "PASS: $pass checks"
