#!/usr/bin/env bash
# hooks/lib/supervised.sh: is a human in front of this session?
#
# Walk up the parent chain until a real TTY shows up. A session started from a terminal has
# one. A `claude -p` under launchd, cron or an agent orchestrator has none.
#
# The agent cannot forge it from its tool loop: a Bash call mutates a subshell, never the TTY
# of the claude process that hosts it.

supervised() {
  # Test escape hatch. It can only harden (force a deny), never open.
  [[ "${CLAUDE_GUARD_ASSUME_UNSUPERVISED:-}" == "1" ]] && return 1
  local pid="${1:-$$}" depth=0 tty
  while [[ -n "$pid" && "$pid" != "0" && $depth -lt 8 ]]; do
    read -r tty pid < <(ps -o tty=,ppid= -p "$pid" 2>/dev/null) || return 1
    # macOS prints ttys001, Linux prints pts/0. No terminal prints ?? or ?.
    [[ "$tty" == tty* || "$tty" == pts/* ]] && return 0
    depth=$((depth + 1))
  done
  return 1
}
