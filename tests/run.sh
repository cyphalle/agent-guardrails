#!/usr/bin/env bash
# tests/run.sh: run every test against a throwaway config, window file and audit dir.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export CLAUDE_GUARD_CONFIG_DIR="$TMP/config"
export CLAUDE_GUARD_SENTINEL="$TMP/unlock"
export CLAUDE_GUARD_AUDIT_DIR="$TMP/audit"
export CLAUDE_GUARD_SCHEDULED_JOBS="$TMP/scheduled-jobs.json"
unset CLAUDE_GUARD_SCHEDULED_JOB CLAUDE_GUARD_RULES_DIR CLAUDE_GUARD_EXTERNAL_SCOPES CLAUDE_GUARD_DEFAULT_TIER
mkdir -p "$CLAUDE_GUARD_CONFIG_DIR"
# Placeholder values for the database rules, as a user would set them.
cp "$ROOT/examples/placeholders.json" "$CLAUDE_GUARD_CONFIG_DIR/placeholders.json"

LOOKUP="$ROOT/hooks/lib/tier-lookup.sh"
GATE="$ROOT/hooks/pre-tool-gate.sh"
AUDIT="$ROOT/hooks/post-tool-audit.sh"

pass=0
fail() { echo "FAIL: $1"; exit 1; }
ok()   { pass=$((pass + 1)); }

bash_call() { jq -nc --arg c "$1" '{tool_name: "Bash", session_id: "sess-A", tool_input: {command: $c}}'; }
tool_call() { jq -nc --arg t "$1" --argjson i "$2" '{tool_name: $t, session_id: "sess-A", tool_input: $i}'; }
tier_of()   { bash_call "$1" | bash "$LOOKUP"; }
expect()    { local out; out=$(tier_of "$1"); echo "$out" | grep -q "^TIER=$2$" || fail "'$1' should be T$2 ($out)"; ok; }
expect_scope() { local out; out=$(tier_of "$1"); echo "$out" | grep -q "^SCOPE=$2$" || fail "'$1' should be scope $2 ($out)"; ok; }
lookup_json() { echo "$1" | bash "$LOOKUP"; }

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
expect "git push origin HEAD 2>&1 | tail -2; pgrep -f nightly.sh" 1
expect "ps -o etime= -p 1 && git push origin HEAD" 1
expect 'git push origin HEAD; echo "done: main"' 1
# ...and an anchored rule now sees the command after a separator.
expect "cd repo && git push --force origin feat" 3
# A backslash continuation is folded before the split.
expect $'git push \\\n  --force origin feat' 3
# Across the commands of a line the highest tier wins: a tier-2 match first does not hide a
# tier-3 command later on.
expect "db-readonly tables; psql -h localhost -p 5434 app" 3

# Database: the port decides (placeholders from examples/placeholders.json), the read-only
# wrapper is free.
expect "db-readonly tables prod" 2
expect "pg_restore -h localhost -p 5434 -d app dump.sql" 3
expect_scope "pg_restore -h localhost -p 5434 -d app dump.sql" db-write
expect "DATABASE_URL=postgres://u:p@localhost:5434/app cargo run" 3
expect "pgcli -h localhost -p 5433 app" 3
expect_scope "pgcli -h localhost -p 5433 app" db-dev
expect "psql -h localhost -p 5432 app" 1
expect "psql -h localhost -p 54345 app" 1
expect "echo 'psql -p 5434' > notes.md" 1
expect 'psql -h db.example.com -c "select 1"' 3
expect 'psql postgres://u@db.example.com/app' 3
expect 'psql -h dbXexampleXcom -c "select 1"' 1
# Without placeholders.json the database rules are inert, by design.
out=$(bash_call "psql -p 5434 app" | CLAUDE_GUARD_CONFIG_DIR="$TMP/no-config" bash "$LOOKUP")
echo "$out" | grep -q "^TIER=1$" || fail "an unset placeholder must match nothing ($out)"; ok

# MCP tools.
out=$(echo '{"tool_name":"mcp__google-workspace__send_email","tool_input":{}}' | bash "$LOOKUP")
echo "$out" | grep -q "^TIER=3$" || fail "send_email should be T3"; ok
out=$(echo '{"tool_name":"mcp__google-workspace__draft_email","tool_input":{}}' | bash "$LOOKUP")
echo "$out" | grep -q "^TIER=1$" || fail "draft_email should be T1"; ok

# --- M3: the command word is normalised before the rules see it -------------------------------
expect "git push -fu origin feat" 3
expect "git push origin +feat" 3
expect "git push origin :feat" 3
expect "git push --force-with-lease=feat origin feat" 3
expect "git push --dry-run origin feat" 1
expect "command git push --force origin x" 3
expect "/usr/bin/git push --force o x" 3
expect "git -C . push --force o x" 3
expect "git -c core.x=y push --force o x" 3
expect "(git push --force o x)" 3
expect "bash -c 'git push --force o x'" 3
expect "eval 'git push -f o x'" 3
expect "sudo git push -f o x" 3
expect "sudo -u deploy env A=1 git push --force o x" 3
expect "git push origin HEAD:refs/heads/main" 3
expect "git push origin main:main" 3
expect_scope "gh pr merge 42 --squash" gh-merge-main
expect_scope "gh api -X PUT repos/o/r/pulls/42/merge" gh-merge-main
out=$(tool_call mcp__plugin_github_github__merge_pull_request '{"pullNumber": 4}' | bash "$LOOKUP")
echo "$out" | grep -q "^SCOPE=gh-merge-main$" || fail "MCP merge should be gh-merge-main ($out)"; ok
expect "export PGPORT=5434; psql -c 'delete from t'" 3
expect "/opt/homebrew/bin/psql -p 5434 -c x" 3
expect "env psql -p 5434" 3
expect "PGPORT=5434 psql -c x" 3

# --- C1: the guard's own configuration is tier 3 on the locked scope guard-config -------------
for c in \
  "echo '{\"scope\":\"all\",\"expires_at\":9999999999}' > ~/.claude/guardrails-unlock" \
  "mkdir -p ~/.claude/guardrails/rules" \
  "jq . x.json > ~/.claude/guardrails/scheduled-jobs.json" \
  "cp /tmp/x \$HOME/.claude/settings.json" \
  "sed -i '' 's/a/b/' ~/.claude/settings.local.json" \
  "mv /tmp/r ~/.claude/guardrails/rules/10-x.json" \
  "ln -s /tmp/evil ~/.claude/guardrails-unlock" \
  "chmod 777 ~/.claude/guardrails" \
  "rm -rf ~/.claude/guardrails-audit" \
  "cd ~/.claude && rm -rf guardrails" \
  "cd ~/.claude/guardrails && ls && rm scheduled-jobs.json" \
  "printf x | tee ~/.claude/guardrails-unlock" \
  "bash -c 'echo x > ~/.claude/guardrails-unlock'" \
  "echo x > $CLAUDE_GUARD_SENTINEL" \
  "touch $CLAUDE_GUARD_CONFIG_DIR/rules"; do
  expect_scope "$c" guard-config
done
expect "cat ~/.claude/settings.json" 1
expect "grep -n x ~/.claude/guardrails/rules/10-database.json 2>/dev/null" 1
expect "ls ~/.claude/guardrails 2>&1 | head" 1
expect "echo done > /tmp/notes.md" 1
for t in Write Edit NotebookEdit; do
  out=$(tool_call "$t" "$(jq -nc --arg p "$HOME/.claude/guardrails-unlock" '{file_path: $p, notebook_path: $p}')" | bash "$LOOKUP")
  echo "$out" | grep -q "^SCOPE=guard-config$" || fail "$t on the window file should be guard-config ($out)"; ok
done
out=$(tool_call Edit "$(jq -nc --arg p "$HOME/.claude/settings.json" '{file_path: $p}')" | bash "$LOOKUP")
echo "$out" | grep -q "^SCOPE=guard-config$" || fail "Edit on settings.json should be guard-config ($out)"; ok
out=$(tool_call Write '{"file_path": "/tmp/project/notes.md"}' | bash "$LOOKUP")
echo "$out" | grep -q "^TIER=1$" || fail "an ordinary Write should be T1 ($out)"; ok

# --- H3: rules that fail to load are tier 3 on guard-misconfigured, never a silent tier 1 -----
SEND='{"tool_name":"mcp__google-workspace__send_email","session_id":"sess-A","tool_input":{"to":"x@y.com"}}'
mis() { local out; out=$(echo "$SEND" | CLAUDE_GUARD_RULES_DIR="$1" bash "$LOOKUP"); echo "$out" | grep -q "^SCOPE=guard-misconfigured$" || fail "$2 ($out)"; ok; }
mkdir -p "$TMP/r-empty" "$TMP/r-bad" "$TMP/r-tier" "$TMP/r-regex" "$TMP/r-none"
mis "$TMP/r-empty" "an empty rules dir must be guard-misconfigured"
cp "$ROOT"/rules/*.json "$TMP/r-bad/"; echo '{bad' > "$TMP/r-bad/05-x.json"
mis "$TMP/r-bad" "an invalid rule file must be guard-misconfigured"
echo '{"rules":[{"match":{"tool":"X"},"tier":5,"scope":"x"}]}' > "$TMP/r-tier/1.json"
mis "$TMP/r-tier" "a tier outside 1-3 must be guard-misconfigured"
echo '{"rules":[{"match":{"tool":"Bash","command_regex":"(unclosed"},"tier":3,"scope":"x"}]}' > "$TMP/r-regex/1.json"
mis "$TMP/r-regex" "a pattern bash cannot compile must be guard-misconfigured"
echo '{"rules":[]}' > "$TMP/r-none/1.json"
mis "$TMP/r-none" "zero rules loaded must be guard-misconfigured"
# An empty rules folder in the config dir no longer replaces the rules with nothing.
mkdir -p "$CLAUDE_GUARD_CONFIG_DIR/rules"
out=$(echo "$SEND" | bash "$LOOKUP")
echo "$out" | grep -q "^SCOPE=guard-misconfigured$" || fail "an empty config rules dir must be guard-misconfigured ($out)"; ok
rmdir "$CLAUDE_GUARD_CONFIG_DIR/rules"
echo '{"PROD_PORT": "5434; rm"}' > "$TMP/bad-ph.json"
mkdir -p "$TMP/ph-config"; cp "$TMP/bad-ph.json" "$TMP/ph-config/placeholders.json"
out=$(echo "$SEND" | CLAUDE_GUARD_CONFIG_DIR="$TMP/ph-config" bash "$LOOKUP")
echo "$out" | grep -q "^SCOPE=guard-misconfigured$" || fail "a bad placeholder value must be guard-misconfigured ($out)"; ok

# --- M2: the lookup reports the command that matched, for the dialog --------------------------
out=$(tier_of "cd repo && git push --force origin feat")
echo "$out" | grep -q "^MATCH=git push --force origin feat$" || fail "MATCH should be the matched command ($out)"; ok
grep -q 'default button "Deny"' "$GATE" || fail "the bypass-mode dialog must default to Deny"; ok

# --- gate, nobody in front --------------------------------------------------------------------
headless() { echo "$1" | CLAUDE_GUARD_ASSUME_UNSUPERVISED=1 bash "$GATE"; }
decision() { jq -r '.hookSpecificOutput.permissionDecision // "silent"' <<< "${1:-{\}}"; }
# window <scope> <seconds> [origin] [session] [created_at offset]
window() {
  local now; now=$(date +%s)
  jq -n --arg s "$1" --argjson e "$(( now + $2 ))" --argjson c "$(( now + ${5:-0} ))" --arg o "${3:-manual}" --arg sess "${4:-}" \
    '{windows: [{scope: $s, expires_at: $e, created_at: $c, origin: $o} + (if $sess == "" then {} else {session_id: $sess} end)]}' > "$CLAUDE_GUARD_SENTINEL"
}

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

# C1: a window longer than 24h, or without created_at, is ignored.
window gmail-send 999999999
[[ "$(decision "$(headless "$SEND")")" == deny ]] || fail "a window over 24h must be ignored"; ok
window gmail-send 1800 manual "" 100000
[[ "$(decision "$(headless "$SEND")")" == deny ]] || fail "a window created in the future must be ignored"; ok
echo '{"scope":"all","expires_at":9999999999}' > "$CLAUDE_GUARD_SENTINEL"
[[ "$(decision "$(headless "$SEND")")" == deny ]] || fail "a forged legacy window must be ignored"; ok

# C1: guard-config is covered by a manual window on that exact scope, and by nothing else.
GUARDW=$(tool_call Write "$(jq -nc --arg p "$HOME/.claude/guardrails-unlock" '{file_path: $p}')")
window all 1800
[[ "$(decision "$(headless "$GUARDW")")" == deny ]] || fail "'all' must not cover guard-config"; ok
window guard-config 1800 auto-window sess-A
[[ "$(decision "$(headless "$GUARDW")")" == deny ]] || fail "an automatic window must not cover guard-config"; ok
window guard-config 1800 manual
[[ -z "$(headless "$GUARDW")" ]] || fail "a manual guard-config window should pass"; ok

# M1: an automatic window covers the session that opened it, not another one.
window gmail-send 1800 auto-window sess-A
[[ -z "$(headless "$SEND")" ]] || fail "an automatic window should cover its own session"; ok
SEND_B=$(jq -c '.session_id = "sess-B"' <<< "$SEND")
[[ "$(decision "$(headless "$SEND_B")")" == deny ]] || fail "an automatic window must not cover another session"; ok
window gmail-send 1800 manual
[[ -z "$(headless "$SEND_B")" ]] || fail "a manual window covers every session"; ok
rm -f "$CLAUDE_GUARD_SENTINEL"

# L2: a denial is logged.
headless "$SEND" >/dev/null
grep -q '"event":"t3-deny"' "$CLAUDE_GUARD_AUDIT_DIR/$(date -u +%Y-%m-%d).jsonl" || fail "a deny should be logged"; ok
rm -rf "$CLAUDE_GUARD_AUDIT_DIR"

# Scheduled jobs: allowlist only.
echo '{"release-job":{"scopes":["gh-release","guard-config"]}}' > "$CLAUDE_GUARD_SCHEDULED_JOBS"
job() { echo "$1" | CLAUDE_GUARD_SCHEDULED_JOB=release-job CLAUDE_GUARD_ASSUME_UNSUPERVISED=1 bash "$GATE"; }
out=$(job "$(bash_call "gh release create v1")")
[[ -z "$out" ]] || fail "allow-listed job scope should pass ($out)"; ok
[[ "$(decision "$(job "$SEND")")" == deny ]] || fail "job scope outside its allowlist should deny"; ok
[[ "$(decision "$(job "$GUARDW")")" == deny ]] || fail "a job is never granted guard-config, even if listed"; ok

# H3 at the gate: a misconfigured guard denies with nobody in front.
out=$(echo "$SEND" | CLAUDE_GUARD_RULES_DIR="$TMP/r-empty" CLAUDE_GUARD_ASSUME_UNSUPERVISED=1 bash "$GATE")
[[ "$(decision "$out")" == deny ]] || fail "a misconfigured guard should deny headless ($out)"; ok

# --- H2: the gate fails closed on its own errors ----------------------------------------------
mkdir -p "$TMP/r-space"
echo '{"rules":[{"match":{"tool":"X"},"tier":3,"scope":"a b; touch '"$TMP"'/pwned"}]}' > "$TMP/r-space/1.json"
out=$(echo '{"tool_name":"X","tool_input":{}}' | CLAUDE_GUARD_RULES_DIR="$TMP/r-space" CLAUDE_GUARD_ASSUME_UNSUPERVISED=1 bash "$GATE")
[[ "$(decision "$out")" == deny ]] || fail "a scope with spaces should still deny ($out)"; ok
[[ ! -e "$TMP/pwned" ]] || fail "a scope must never be evaluated as shell"; ok
mkdir -p "$TMP/nojq"
for b in bash cat dirname date ps awk head tr mkdir id sed; do
  p=$(command -v "$b" || true); [[ -n "$p" ]] && ln -sf "$p" "$TMP/nojq/$b"
done
rc=0; echo "$SEND" | PATH="$TMP/nojq" CLAUDE_GUARD_ASSUME_UNSUPERVISED=1 "$(command -v bash)" "$GATE" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail "a gate without jq must block with exit 2 (got $rc)"; ok
rc=0; echo 'not json' | CLAUDE_GUARD_ASSUME_UNSUPERVISED=1 bash "$GATE" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail "a gate that cannot parse its input must block with exit 2 (got $rc)"; ok

# --- H1: a claude started under another claude is never supervised and ignores CLAUDE_GUARD_* --
mkdir -p "$TMP/fake"
printf '%s\n' '#!/usr/bin/env bash' '"$@"' 'exit $?' > "$TMP/fake/claude"
chmod +x "$TMP/fake/claude"
nested() { "$TMP/fake/claude" "$TMP/fake/claude" "$@"; }
nested bash -c "source '$ROOT/hooks/lib/supervised.sh'; guard_nested" || fail "two claude ancestors should read as nested"; ok
if nested bash -c "source '$ROOT/hooks/lib/supervised.sh'; supervised"; then fail "a nested claude must not be supervised"; fi; ok
# A forged sentinel path given through the environment is no longer the protected one: the
# nested lookup ignores the variable and protects the real path instead.
out=$(bash_call "echo x > $CLAUDE_GUARD_SENTINEL" | nested bash "$LOOKUP")
echo "$out" | grep -q "^TIER=1$" || fail "a nested lookup must ignore CLAUDE_GUARD_SENTINEL ($out)"; ok
# A permissive rules dir given through the environment is ignored by a nested lookup.
mkdir -p "$TMP/r-open"; echo '{"rules":[{"match":{"tool":"Bash"},"tier":1,"scope":null}]}' > "$TMP/r-open/1.json"
out=$(bash_call "gh release create v1" | CLAUDE_GUARD_RULES_DIR="$TMP/r-open" bash "$LOOKUP")
echo "$out" | grep -q "^TIER=1$" || fail "the permissive rules dir should apply outside nesting ($out)"; ok
REAL_HOME=$(eval "echo ~$(id -un)")
if [[ ! -e "$REAL_HOME/.claude/guardrails/rules" && ! -e "$REAL_HOME/.claude/guardrails-unlock" ]]; then
  out=$(bash_call "gh release create v1" | CLAUDE_GUARD_RULES_DIR="$TMP/r-open" nested bash "$LOOKUP")
  echo "$out" | grep -q "^TIER=3$" || fail "a nested lookup must ignore CLAUDE_GUARD_RULES_DIR ($out)"; ok
  out=$(bash_call "gh release create v1" | CLAUDE_GUARD_SCHEDULED_JOB=release-job nested bash "$GATE")
  [[ "$(decision "$out")" == deny ]] || fail "a nested claude must not inherit a job allowlist ($out)"; ok
else
  echo "skip: nested gate cases (a real guardrails config exists in $REAL_HOME/.claude)"
fi
# A pseudo-terminal from `script` does not make a nested claude supervised, nor unlock it.
# A script, not a function: it runs under the fake claude, in a child process.
# util-linux script takes one command string; BSD script takes argv.
cat > "$TMP/fake/with_pty" <<'PTY'
#!/usr/bin/env bash
if script --version >/dev/null 2>&1; then exec script -qec "$(printf '%q ' "$@")" /dev/null; fi
exec script -q /dev/null "$@"
PTY
chmod +x "$TMP/fake/with_pty"
with_pty="$TMP/fake/with_pty"
if command -v script >/dev/null 2>&1; then
  # Control: the pty is real, so the checks below fail for the right reason.
  "$with_pty" bash -c 'tty' </dev/null 2>/dev/null | grep -qE '/dev/(ttys?[0-9]|pts/)' || fail "script should provide a pty"; ok
  out=$(nested "$with_pty" bash -c "source '$ROOT/hooks/lib/supervised.sh'; supervised && echo SUPERVISED || echo headless" </dev/null 2>/dev/null)
  [[ "$out" == *headless* ]] || fail "a pty from script must not make a nested claude supervised ($out)"; ok
  out=$(nested "$with_pty" bash "$ROOT/bin/unlock" --scope all </dev/null 2>&1 || true)
  [[ "$out" == *"refuses to run under a Claude Code process"* ]] || fail "unlock under a claude process must refuse, even with a pty ($out)"; ok
  [[ ! -e "$CLAUDE_GUARD_SENTINEL" ]] || fail "a refused unlock must not write a window"; ok
else
  echo "skip: pty cases (no script command)"
fi

# --- gate, human in front (only when the test itself runs in a terminal) ----------------------
if bash -c "source '$ROOT/hooks/lib/supervised.sh'; supervised"; then
  [[ "$(decision "$(echo "$SEND" | bash "$GATE")")" == ask ]] || fail "supervised external T3 should ask"; ok
  [[ -z "$(bash_call "git push origin main" | bash "$GATE")" ]] || fail "supervised internal T3 should pass"; ok
  [[ "$(decision "$(bash_call "psql -p 5434 app" | bash "$GATE")")" == ask ]] || fail "supervised prod write should ask"; ok
  [[ "$(decision "$(echo "$GUARDW" | bash "$GATE")")" == ask ]] || fail "supervised guard-config should ask"; ok
  out=$(echo "$SEND" | CLAUDE_GUARD_RULES_DIR="$TMP/r-empty" bash "$GATE")
  [[ "$(decision "$out")" == ask ]] || fail "a misconfigured guard should ask with a human in front ($out)"; ok
  # M1: the automatic window opened after a yes carries the session id.
  echo "$SEND" | bash "$AUDIT"
  [[ "$(jq -r '.windows[0].session_id' "$CLAUDE_GUARD_SENTINEL")" == sess-A ]] || fail "an automatic window should carry its session"; ok
  rm -f "$CLAUDE_GUARD_SENTINEL"
  echo "$GUARDW" | bash "$AUDIT"
  [[ ! -e "$CLAUDE_GUARD_SENTINEL" ]] || fail "no automatic window for guard-config"; ok
  rm -rf "$CLAUDE_GUARD_AUDIT_DIR"
else
  echo "skip: supervised cases (no TTY)"
fi

# --- audit ------------------------------------------------------------------------------------
rm -rf "$CLAUDE_GUARD_AUDIT_DIR"
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
