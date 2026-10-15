#!/usr/bin/env bash
# hooks/lib/tier-lookup.sh: read a tool call as JSON on stdin, print four lines:
#   TIER=<1|2|3>  SCOPE=<scope>  MATCH=<what matched, for the dialog>  REASON=<why, if any>
# The caller reads them line by line. Nothing here is ever passed to eval.
set -euo pipefail

# shellcheck source=hooks/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

emit() {
  local m="${3//$'\n'/ }" w="${4//$'\n'/ }"
  printf 'TIER=%s\nSCOPE=%s\nMATCH=%s\nREASON=%s\n' "$1" "${2//$'\n'/ }" "${m:0:300}" "${w:0:300}"
  exit 0
}
# Any rule problem is a tier-3 call on a locked scope: asked with a human in front, denied
# without one. Silently falling back to tier 1 would turn a typo into an open door.
misconfigured() { emit 3 guard-misconfigured "" "agent-guardrails rules are misconfigured: $(printf '%s' "$1" | tr '\n' ' ')"; }
# Top level only (no -E): inside a command substitution the trap would print into the captured
# value instead of answering. A failure inside a function exits non-zero, and the gate denies.
trap 'misconfigured "internal error in tier-lookup.sh at line $LINENO"' ERR

# Your own rules replace the bundled ones as a whole: a partial merge would make the order of
# first-match-wins hard to read.
if [[ -n "${CLAUDE_GUARD_RULES_DIR:-}" ]]; then
  RULES_DIR="$CLAUDE_GUARD_RULES_DIR"
elif [[ -d "$GUARD_CONFIG_DIR/rules" ]]; then
  RULES_DIR="$GUARD_CONFIG_DIR/rules"
else
  RULES_DIR="$GUARD_ROOT/rules"
fi

INPUT=$(cat)
TOOL=$(jq -r '.tool_name // empty' <<< "$INPUT")
CMD=$(jq -r '.tool_input.command // empty' <<< "$INPUT")

[[ -n "$TOOL" ]] || emit 1 "" "" ""

# --- Segments ----------------------------------------------------------------------------------
# A command_regex describes ONE command, so it is matched against ONE command and never against
# the whole shell line. Left unsplit, a rule's `.*` walks through the separators and matches a
# fragment of another command (a `-f` that belongs to a `pgrep` later on the line).
#
# Fold backslash-newline continuations first, then split on ; & | and newlines. The split can
# only produce more segments, never merge two.
cmd_segments() {
  local c="$1"
  c="${c//\\$'\n'/ }"
  # shellcheck disable=SC2020
  printf '%s\n' "$c" | tr ';|&\n' '\n\n\n\n'
}

# Both helpers set a global instead of printing: a subshell per call made the lookup slow.
_trim() { _T="${1#"${1%%[![:space:]]*}"}"; _T="${_T%"${_T##*[![:space:]]}"}"; }
_rest() { _R="${1#"${1%%[[:space:]]*}"}"; _R="${_R#"${_R%%[![:space:]]*}"}"; }

# Normalise the command word, so a rule written as `^git push` also sees `sudo git push`,
# `/usr/bin/git push`, `env X=1 git push`, `(git push`, `git -C dir push`, and the command inside
# `bash -c '...'` or `eval '...'`. Sets NORM, and NORM_INNER for the body of `sh -c` or `eval`.
# Best effort: quoting is not parsed.
_norm1() {
  local s w prev i opt
  _trim "$1"; s="$_T"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    prev="$s"
    s="${s#"${s%%[![:space:](\{\!]*}"}"
    w="${s%%[[:space:]]*}"
    case "$w" in
      sudo|doas|env|nice|ionice|command|exec|nohup|time|builtin|caffeinate|stdbuf|noglob|timeout)
        _rest "$s"; s="$_R"
        while [[ "$s" == -* ]]; do
          opt="${s%%[[:space:]]*}"
          _rest "$s"; s="$_R"
          case "$w:$opt" in
            sudo:-u|sudo:-g|sudo:-h|sudo:-p|sudo:-C|sudo:-U|sudo:-r|sudo:-t|sudo:-D|doas:-u|doas:-C|env:-u|env:-C|env:-S|nice:-n|ionice:-c|ionice:-n|exec:-a|timeout:-s|timeout:-k)
              _rest "$s"; s="$_R" ;;
          esac
        done
        if [[ "$w" == timeout ]]; then _rest "$s"; s="$_R"; fi
        ;;
      *=*)
        if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then _rest "$s"; s="$_R"; fi
        ;;
    esac
    [[ "$s" != "$prev" ]] || break
  done
  w="${s%%[[:space:]]*}"
  s="${w##*/}${s#"$w"}"
  w="${w##*/}"
  if [[ "$w" == git ]]; then
    _rest "$s"; s="$_R"
    while [[ "$s" == -* ]]; do
      opt="${s%%[[:space:]]*}"
      _rest "$s"; s="$_R"
      case "$opt" in
        -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env) _rest "$s"; s="$_R" ;;
      esac
    done
    s="git${s:+ $s}"
  fi
  NORM="$s"
  NORM_WORD="$w"
}
normalize() {
  local inner=""
  _norm1 "$1"
  case "$NORM_WORD" in
    sh|bash|zsh|dash|ksh)
      if [[ "$NORM" =~ [[:space:]]-[A-Za-z]*c[[:space:]]+(.*)$ ]]; then inner="${BASH_REMATCH[1]}"; fi ;;
    eval)
      _rest "$NORM"; inner="$_R" ;;
  esac
  NORM_INNER=""
  if [[ -n "$inner" ]]; then
    local outer="$NORM" word="$NORM_WORD"
    inner="${inner#[\"\']}"
    _norm1 "$inner"
    NORM_INNER="$NORM"
    NORM="$outer"; NORM_WORD="$word"
  fi
}

# SEG_TEXT holds every variant to match, SEG_RAW the command as written (shown in the dialog),
# SEG_GROUP the index of that command on the line, SEG_NORM its normalised form.
SEG_RAW=()
SEG_TEXT=()
SEG_GROUP=()
SEG_NORM=()
grp=0
while IFS= read -r seg; do
  _trim "$seg"; seg="$_T"
  [[ -n "$seg" ]] || continue
  grp=$((grp + 1))
  normalize "$seg"
  SEG_RAW+=("$seg"); SEG_TEXT+=("$seg"); SEG_GROUP+=("$grp"); SEG_NORM+=("$NORM")
  for n in "$NORM" "$NORM_INNER"; do
    [[ -n "$n" && "$n" != "$seg" ]] || continue
    SEG_RAW+=("$seg"); SEG_TEXT+=("$n"); SEG_GROUP+=("$grp"); SEG_NORM+=("$NORM")
  done
done < <(cmd_segments "$CMD")

# --- Built-in rule: the guard protects its own configuration ----------------------------------
# Not a rules/*.json entry on purpose: a rules folder replaces the bundled one, and a copy made
# before this rule existed would silently drop it. Anyone who can write the window file, the
# rules, the job allowlist or the Claude Code settings can switch the guard off, so those writes
# are tier 3 on the locked scope guard-config.
PROTECT_STRONG='\.claude/(guardrails|settings(\.local)?\.json|plugins/.*agent-guardrails)|guardrails-(unlock|audit)|scheduled-jobs\.json'
# Short names, protected only when the line also mentions .claude (cd ~/.claude && rm -rf guardrails).
PROTECT_BARE='(^|[^A-Za-z0-9_.-])(guardrails[A-Za-z0-9_.-]*|settings(\.local)?\.json|plugins|external-scopes\.json|placeholders\.json)([^A-Za-z0-9_-]|$)'
PROTECT_LITERAL=("$GUARD_SENTINEL" "$GUARD_AUDIT_DIR" "$GUARD_CONFIG_DIR" "$GUARD_SCHEDULED_JOBS" "$RULES_DIR" "$GUARD_ROOT")
READERS=" cat less more head tail grep egrep fgrep rg ag ls stat file wc diff cmp jq shasum sha256sum sha1sum md5 md5sum sed echo printf test [ readlink realpath du tree bat audit-tail true pwd "

CTX=0
[[ "$CMD" =~ \.claude([^A-Za-z0-9_-]|$)|CLAUDE_CONFIG_DIR|CLAUDE_GUARD_ ]] && CTX=1

touches_guard() {
  local s="$1" p
  [[ "$s" =~ $PROTECT_STRONG ]] && return 0
  [[ "$CTX" == 1 && "$s" =~ $PROTECT_BARE ]] && return 0
  for p in "${PROTECT_LITERAL[@]}"; do
    [[ -n "$p" && "$s" == *"$p"* ]] && return 0
  done
  return 1
}

# A reader that writes nothing: known command word, no in-place flag, no redirect left once the
# harmless ones (to /dev/null, to another descriptor, the stub a `2>&1` leaves after the split)
# are removed.
pure_reader() {
  local raw="$1" norm="$2" w r
  w="${norm%%[[:space:]]*}"
  [[ "$READERS" == *" $w "* ]] || return 1
  if [[ "$w" == sed && "$norm" =~ [[:space:]](-[A-Za-z]*i|--in-place) ]]; then return 1; fi
  [[ "$raw" == *">"* ]] || return 0
  r=$(printf '%s' "$raw" | sed -E 's#[0-9]*>{1,2}[[:space:]]*/dev/null##g; s#[0-9]*>&[0-9-]##g; s#[0-9]*>[[:space:]]*$##')
  [[ "$r" != *">"* ]]
}

if [[ "$TOOL" == Bash && -n "$CMD" ]]; then
  cd_into_guard=0
  for ((i = 0; i < ${#SEG_RAW[@]}; i++)); do
    [[ $i -eq 0 || "${SEG_GROUP[$i]}" != "${SEG_GROUP[$((i - 1))]}" ]] || continue
    raw="${SEG_RAW[$i]}"
    norm="${SEG_NORM[$i]}"
    w="${norm%%[[:space:]]*}"
    if touches_guard "$raw"; then
      if [[ "$w" == cd || "$w" == pushd ]]; then cd_into_guard=1; continue; fi
      pure_reader "$raw" "$norm" || emit 3 guard-config "$raw" "writes to the guard's own configuration"
    elif [[ "$cd_into_guard" == 1 ]]; then
      [[ "$w" == cd || "$w" == pushd ]] && continue
      pure_reader "$raw" "$norm" || emit 3 guard-config "$raw" "runs inside the guard's own configuration folder"
    fi
  done
fi

case "$TOOL" in
  Write|Edit|MultiEdit|NotebookEdit|mcp__*filesystem*)
    FILE=$(jq -r '.tool_input | (.file_path // .notebook_path // .path // .destination // empty) | tostring' <<< "$INPUT")
    if [[ -n "$FILE" ]]; then
      CTX=1
      touches_guard "$FILE" && emit 3 guard-config "$TOOL $FILE" "writes to the guard's own configuration"
    fi
    ;;
esac

# --- Placeholders ------------------------------------------------------------------------------
# A rule can name a value that differs per setup, like <PROD_PORT>, and take it from
# placeholders.json in the config folder. An unset placeholder stays literal, so its rule
# matches nothing.
PH='{}'
PH_FILE="$GUARD_CONFIG_DIR/placeholders.json"
if [[ -f "$PH_FILE" ]]; then
  PH=$(jq -c '
    if type != "object" then error("placeholders.json is not an object") else . end
    | with_entries(select(.key | startswith("_") | not))
    | if all(to_entries[]; (.key | test("^[A-Z][A-Z0-9_]*$"))
                           and ((.value | type) == "string" or (.value | type) == "number")
                           and (.value | tostring | test("^[A-Za-z0-9._-]+$")))
      then map_values(tostring)
      else error("placeholders.json: names are UPPER_CASE, values are letters, digits, dot, dash or underscore")
      end' "$PH_FILE" 2>&1) || misconfigured "$PH"
fi

# --- Rules -------------------------------------------------------------------------------------
# Every rule of every file, flattened in ONE jq pass, in file-name order (first match wins).
# Name your files 10-*.json, 50-*.json, 90-*.json to set the priority.
#
# One jq pass for all rules matters: a version that spawned several jq per rule made the lookup
# slow enough to be worth removing, and it runs twice per tool call.
#
# NINE LINES PER RULE, one field each. A delimiter-joined line breaks on bash 3.2 (the bash macOS
# ships does not split on IFS=$'\001'), and `@tsv` escapes the backslashes the patterns are made
# of. Newlines are folded to spaces at the source, so a value can never shift the fields, and
# every field starts with "=" so that empty trailing fields survive the command substitution.
#
# Fail-closed: an unreadable file, a file without a rules array, a rule with a tier other than 1,
# 2 or 3, or zero rules in total makes the call tier 3 on guard-misconfigured.
FILES=()
for f in "$RULES_DIR"/*.json; do
  [[ -f "$f" ]] && FILES+=("$f")
done
[[ ${#FILES[@]} -gt 0 ]] || misconfigured "no rule file in $RULES_DIR"

RULES_RAW=$(jq -n -r --argjson ph "$PH" '
  def fill: gsub("<(?<k>[A-Z][A-Z0-9_]*)>";
                 (.k as $k | if ($ph | has($k)) then ($ph[$k] | gsub("\\."; "\\.")) else "<" + $k + ">" end));
  [ inputs as $doc | input_filename as $f
    | if ($doc | type) != "object" or ($doc.rules | type) != "array"
      then error("\($f): no rules array") else $doc.rules[] end
    | if (type != "object") or ((.match | type) != "object") then error("\($f): a rule without a match object")
      elif ([.tier] | inside([1, 2, 3]) | not) then error("\($f): a rule whose tier is not 1, 2 or 3")
      elif (.scope != null and (.scope | type) != "string") then error("\($f): a scope that is not a string")
      else . end ]
  | if length == 0 then error("no rule loaded") else .[] end
  | [ (.tier | tostring),
      (.scope // ""),
      (.match.tool // ""),
      (.match.tool_prefix // ""),
      (.match.suffix // ""),
      (.match.suffix_regex // ""),
      ((.match.command_regex // "") | fill),
      (.match.input_field // ""),
      ((.match.input_regex // "") | fill) ]
  | map("=" + (tostring | gsub("[\n\r]"; " "))) | .[]' "${FILES[@]}" 2>&1) || misconfigured "$RULES_RAW"

R_TIER=(); R_SCOPE=(); R_TOOL=(); R_PREFIX=(); R_SUFFIX=(); R_SUFFIX_RE=(); R_CMD_RE=(); R_FIELD=(); R_INPUT_RE=()
while IFS= read -r a && IFS= read -r b && IFS= read -r c && IFS= read -r d && IFS= read -r e \
   && IFS= read -r g && IFS= read -r h && IFS= read -r j && IFS= read -r k; do
  a="${a#=}" b="${b#=}" c="${c#=}" d="${d#=}" e="${e#=}" g="${g#=}" h="${h#=}" j="${j#=}" k="${k#=}"
  # A pattern bash cannot compile makes [[ =~ ]] return 2, which an `if` reads as "no match".
  # Check every pattern once, here, instead of letting a broken rule fail open.
  for re in "$g" "$h" "$k"; do
    [[ -n "$re" ]] || continue
    rc=0
    # shellcheck disable=SC2319
    [[ "" =~ $re ]] || rc=$?
    [[ "$rc" != 2 ]] || misconfigured "invalid pattern: $re"
  done
  R_TIER+=("$a"); R_SCOPE+=("$b"); R_TOOL+=("$c"); R_PREFIX+=("$d"); R_SUFFIX+=("$e")
  R_SUFFIX_RE+=("$g"); R_CMD_RE+=("$h"); R_FIELD+=("$j"); R_INPUT_RE+=("$k")
done <<< "$RULES_RAW"
[[ ${#R_TIER[@]} -gt 0 ]] || misconfigured "no rule loaded"

DEFAULT_TIER="${CLAUDE_GUARD_DEFAULT_TIER:-1}"
[[ "$DEFAULT_TIER" =~ ^[123]$ ]] || misconfigured "CLAUDE_GUARD_DEFAULT_TIER must be 1, 2 or 3"

# First matching rule for one command: the variants of segment group $1 (empty for a tool call
# that is not a shell line). Sets M_TIER, M_SCOPE, M_HIT; returns 1 if no rule matches.
first_match() {
  local group="$1" r i re value hit
  for ((r = 0; r < ${#R_TIER[@]}; r++)); do
    [[ -z "${R_TOOL[$r]}" || "$TOOL" == "${R_TOOL[$r]}" ]] || continue
    [[ -z "${R_PREFIX[$r]}" || "$TOOL" == "${R_PREFIX[$r]}"* ]] || continue
    [[ -z "${R_SUFFIX[$r]}" || "$TOOL" == *"${R_SUFFIX[$r]}" ]] || continue
    if [[ -n "${R_SUFFIX_RE[$r]}" ]]; then
      re="${R_SUFFIX_RE[$r]}"; [[ "$TOOL" =~ $re ]] || continue
    fi
    hit=""
    if [[ -n "${R_CMD_RE[$r]}" ]]; then
      [[ -n "$group" ]] || continue
      re="${R_CMD_RE[$r]}"
      for ((i = 0; i < ${#SEG_TEXT[@]}; i++)); do
        [[ "${SEG_GROUP[$i]}" == "$group" ]] || continue
        if [[ "${SEG_TEXT[$i]}" =~ $re ]]; then hit="${SEG_RAW[$i]}"; break; fi
      done
      [[ -n "$hit" ]] || continue
    fi
    # One named argument of an MCP call. Scoped to ONE field on purpose: matching the whole
    # serialized tool_input would let a message body trip a rule meant for a channel id.
    if [[ -n "${R_INPUT_RE[$r]}" ]]; then
      [[ -n "${R_FIELD[$r]}" ]] || continue
      value=$(jq -r --arg f "${R_FIELD[$r]}" '.tool_input[$f] // empty | tostring' <<< "$INPUT")
      re="${R_INPUT_RE[$r]}"
      [[ -n "$value" && "$value" =~ $re ]] || continue
      hit="${R_FIELD[$r]}: $value"
    fi
    M_TIER="${R_TIER[$r]}"; M_SCOPE="${R_SCOPE[$r]}"; M_HIT="$hit"
    return 0
  done
  return 1
}

# First match wins WITHIN one command. ACROSS the commands of a line, the highest tier wins: a
# tier-2 rule on the first command must not hide a tier-3 command later on the same line.
B_TIER=0; B_SCOPE=""; B_HIT=""
consider() {
  if [[ "$1" -gt "$B_TIER" ]]; then B_TIER="$1"; B_SCOPE="$2"; B_HIT="$3"; fi
}
if [[ ${#SEG_GROUP[@]} -eq 0 ]]; then
  if first_match ""; then consider "$M_TIER" "$M_SCOPE" "$M_HIT"; else consider "$DEFAULT_TIER" "" ""; fi
else
  last=""
  for ((n = 0; n < ${#SEG_GROUP[@]}; n++)); do
    [[ "${SEG_GROUP[$n]}" != "$last" ]] || continue
    last="${SEG_GROUP[$n]}"
    if first_match "$last"; then consider "$M_TIER" "$M_SCOPE" "$M_HIT"; else consider "$DEFAULT_TIER" "" ""; fi
  done
fi
emit "$B_TIER" "$B_SCOPE" "$B_HIT" ""
