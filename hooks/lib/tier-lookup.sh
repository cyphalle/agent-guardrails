#!/usr/bin/env bash
# hooks/lib/tier-lookup.sh: read a tool call as JSON on stdin, print TIER= and SCOPE=.
set -euo pipefail

GUARD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RULES_DIR="${CLAUDE_GUARD_RULES_DIR:-$GUARD_ROOT/rules}"

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# A command_regex describes ONE command, so it is matched against ONE command and never against
# the whole shell line. Left unsplit, a rule's `.*` walks straight through the shell separators
# and matches a fragment that belongs to another command. Real case: an ordinary `git push` was
# blocked as a force push because a `pgrep -f` three commands later supplied the short flag the
# force rule looks for. Sending someone to unlock a force-push scope to land an ordinary push is
# the opposite of least privilege, and the habit it builds is worse than the block itself.
#
# Splitting also TIGHTENS the anchored rules (those that start with `^`): unsplit, they only
# ever saw the first command of the line, and anything after a `&&` slipped past them.
#
# Split on ; & && || | and newlines, AFTER folding backslash-newline continuations. Without the
# fold, a command written across two lines is cut in half and sails through. The split is
# conservative by construction: it can only produce more segments, never merge two.
# Pure bash + tr: this runs on every tool call and must never be the thing that breaks.
cmd_segments() {
  local c="$1"
  c="${c//\\$'\n'/ }"
  printf '%s' "$c" | tr ';|&\n' '\n\n\n\n'
}
CMD_SEGMENTS=$(cmd_segments "$CMD")

if [[ -z "$TOOL" ]]; then
  echo "TIER=1"
  echo "SCOPE="
  exit 0
fi

# Every rule of every file, flattened in ONE jq pass, in file-name order (first match wins).
# Name your files 10-*.json, 50-*.json, 90-*.json to set the priority.
#
# The first version ran two jq per rule plus five more to pull the fields out: about 1,200
# processes for 131 rules, 13 s for a single lookup, paid twice per tool call (the gate and the
# audit). A gate nobody can afford to run is a gate that ends up removed, so this cost is a
# safety property.
#
# NINE LINES PER RULE, one field each. A delimiter-joined line broke the hook outright: bash 3.2,
# the bash macOS ships, does not split on IFS=$'\001' (zsh does, which is why it passed when
# tried by hand). `@tsv` is no way out either: it escapes backslashes, and the patterns are made
# of them. Newlines are folded to spaces at the source, so a multi-line value can never shift
# the fields out of step, a failure that would be silent and total.
collect_rules() {
  local files=() f
  for f in "$RULES_DIR"/*.json; do
    [[ -f "$f" ]] && files+=("$f")
  done
  [[ ${#files[@]} -gt 0 ]] || return 0
  jq -r '.rules[]? | [
      (.tier | tostring),
      (.scope // ""),
      (.match.tool // ""),
      (.match.tool_prefix // ""),
      (.match.suffix // ""),
      (.match.suffix_regex // ""),
      (.match.command_regex // ""),
      (.match.input_field // ""),
      (.match.input_regex // "")
    ] | map(gsub("\n"; " ")) | .[]' "${files[@]}" 2>/dev/null
}

check_rules() {
  local tier scope match_tool match_prefix match_suffix match_suffix_regex match_cmd_regex
  local match_input_field match_input_regex
  local seg seg_hit input_value

  while IFS= read -r tier \
     && IFS= read -r scope \
     && IFS= read -r match_tool \
     && IFS= read -r match_prefix \
     && IFS= read -r match_suffix \
     && IFS= read -r match_suffix_regex \
     && IFS= read -r match_cmd_regex \
     && IFS= read -r match_input_field \
     && IFS= read -r match_input_regex; do

    if [[ -n "$match_tool" && "$TOOL" != "$match_tool" ]]; then continue; fi
    if [[ -n "$match_prefix" && "$TOOL" != "$match_prefix"* ]]; then continue; fi
    if [[ -n "$match_suffix" && "$TOOL" != *"$match_suffix" ]]; then continue; fi
    if [[ -n "$match_suffix_regex" && ! "$TOOL" =~ $match_suffix_regex ]]; then continue; fi
    if [[ -n "$match_cmd_regex" ]]; then
      seg_hit=0
      while IFS= read -r seg; do
        # Trim leading blanks so an anchored rule sees the start of ITS command.
        seg="${seg#"${seg%%[![:space:]]*}"}"
        [[ -z "$seg" ]] && continue
        if [[ "$seg" =~ $match_cmd_regex ]]; then seg_hit=1; break; fi
      done <<< "$CMD_SEGMENTS"
      [[ "$seg_hit" == 1 ]] || continue
    fi
    # One named argument of an MCP call. Scoped to ONE field on purpose: matching the whole
    # serialized tool_input would let a message body trip a rule meant for a channel id.
    # A rule that names a field the call does not carry never matches.
    if [[ -n "$match_input_regex" ]]; then
      [[ -n "$match_input_field" ]] || continue
      input_value=$(echo "$INPUT" | jq -r --arg f "$match_input_field" '.tool_input[$f] // empty' 2>/dev/null)
      [[ -n "$input_value" ]] || continue
      [[ "$input_value" =~ $match_input_regex ]] || continue
    fi

    echo "TIER=$tier"
    echo "SCOPE=$scope"
    return 0
  done < <(collect_rules)
  return 1
}

if check_rules; then exit 0; fi

echo "TIER=${CLAUDE_GUARD_DEFAULT_TIER:-1}"
echo "SCOPE="
