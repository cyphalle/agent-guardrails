#!/usr/bin/env bash
# shellcheck shell=bash
# hooks/lib/supervised.sh: who is in front of this session?
#
# Two questions, answered from ONE snapshot of the process table:
#
# 1. Is this hook running under a NESTED Claude Code, that is a claude process that has another
#    claude process among its ancestors? An agent can start a second claude from its Bash tool,
#    and that child inherits whatever the agent put in front of it: a pseudo-terminal from
#    `script`, CLAUDE_GUARD_* variables, a different HOME. None of that is a human. A nested
#    session is therefore treated as unsupervised, and common.sh ignores its CLAUDE_GUARD_*
#    variables and its HOME.
#
# 2. Is a human in front? Walk up the parent chain until a real TTY shows up. A session started
#    from a terminal has one. A `claude -p` under launchd, cron or an orchestrator has none.
#
# Limit: both answers read the parent chain. A process that detaches from its parent before it
# starts claude (a double fork, `setsid`, a launchd job written by the agent) has no claude
# ancestor left to find, and a `script` pty would then look like a terminal. Renaming the claude
# binary also hides it from the check. See "Limits" in the README.

# Print the ancestor chain of this shell, one line per process, nearest first,
# up to but excluding pid 1:
#   <pid> <tty> <is_claude: 0|1>
# One `ps` per ancestor. On macOS that is several times faster than one `ps -p a,b,c` or a
# `ps -A` with command lines, and this runs on every tool call. Cached per shell.
_GUARD_CHAIN_CACHE=""
guard_chain() {
  local pid="$$" d=0 line ppid tty a1 a2 rest c out=""
  if [[ -n "$_GUARD_CHAIN_CACHE" ]]; then
    printf '%s\n' "$_GUARD_CHAIN_CACHE"; return 0
  fi
  while [[ -n "$pid" && "$pid" != 0 && "$pid" != 1 && $d -lt 64 ]]; do
    line=$(ps -o ppid= -o tty= -o args= -p "$pid" 2>/dev/null) || break
    [[ -n "$line" ]] || break
    a2=""; read -r ppid tty a1 a2 rest <<< "$line"
    c=0
    # The binary itself (`claude`), a script run by an interpreter (`node .../claude`), or the npm
    # package path as the interpreter's first argument. Only the first two words are read: the
    # rest of a command line is free text, and a shell that merely mentions claude is not one.
    if [[ "${a1##*/}" == claude || "${a2##*/}" == claude || "$a2" == *@anthropic-ai/claude-code/* ]]; then c=1; fi
    out="$out$pid $tty $c"$'\n'
    pid="$ppid"; d=$((d + 1))
  done
  [[ -n "$out" ]] || return 1
  out="${out%$'\n'}"
  _GUARD_CHAIN_CACHE="$out"
  printf '%s\n' "$out"
}

# True when the claude process that runs this hook has another claude above it.
# Fail-closed: no process table to read counts as nested.
guard_nested() {
  local chain
  guard_chain >/dev/null || return 0
  chain=$(guard_chain) || return 0
  _guard_nested_in "$chain"
}

_guard_nested_in() {
  local chain="$1" host=0 line
  [[ -n "$chain" ]] || return 0
  while IFS= read -r line; do
    if [[ "${line##* }" == 1 ]]; then
      [[ "$host" == 1 ]] && return 0
      host=1
    fi
  done <<< "$chain"
  return 1
}

supervised() {
  # Test escape hatch. It can only harden (force a deny), never open.
  [[ "${CLAUDE_GUARD_ASSUME_UNSUPERVISED:-}" == "1" ]] && return 1
  local chain line tty depth=0
  guard_chain >/dev/null || return 1
  chain=$(guard_chain) || return 1
  _guard_nested_in "$chain" && return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ $depth -lt 8 ]] || break
    tty="${line#* }"; tty="${tty%% *}"
    # macOS prints ttys001, Linux prints pts/0. No terminal prints ?? or ?.
    [[ "$tty" == tty* || "$tty" == pts/* ]] && return 0
    depth=$((depth + 1))
  done <<< "$chain"
  return 1
}
