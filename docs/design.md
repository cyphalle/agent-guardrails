# Design notes

Each rule of this repo exists because the setup was weaker without it. This file keeps the
reasoning, so a future change can tell a rule that still protects from one that only costs.

## 1. The lock follows the human

A first design gated on the action: a tier-3 call always needed a manual `unlock` typed in
another terminal. Most blocks then land on internal actions taken with the author in front of
the session. The block protects nothing there, and it trains the habit of opening a long
blanket window.

The current design asks a different question: can anyone see this call? Scopes are split by
who an action affects. External actions (email, CRM, payments, production database writes) ask
a human every time. Internal actions on your own repositories pass in a supervised session and
are logged. With nobody in front, everything tier 3 is denied, except what a scheduled job
lists.

## 2. In bypass mode, the gate does not rely on `ask`

In bypass mode the gate never relies on `ask`: it shows its own confirmation dialog, and with
no screen attached it denies. The answer goes to the audit log, and the gate returns `allow` or
`deny` itself. The dialog shows what will actually run (the command of the line that matched,
or the main arguments of an MCP call) and Deny is the default button, so a reflex Enter
refuses.

## 3. Post-hooks repair, pre-hooks block

A blocking pre-hook on PR creation (no reviewer, no assignee: refused) only sends the agent to
replay the same command with one more flag. It also cannot see the MCP path, `gh pr create
--web`, or flags that GitHub silently drops.

The post-hook reads the real state of the PR and gives the agent the exact `gh pr edit` that
repairs it. The rule does not change. Only the moment of the check moves.

## 4. One command per match

A rule describes one command, so it runs on one command and never on the whole shell line.
Unsplit, the `.*` of a force-push rule finds a `-f` that belongs to a `pgrep` later on the
line, and a patch to a file that quotes the patterns is blocked by its own comments.

The lookup folds backslash continuations, splits on `; & | &&` and newlines, and tests each
command. Each command is tested twice: as written, and with its command word normalised
(`sudo`, `env`, `command`, `exec`, `VAR=value`, an absolute path, a leading parenthesis,
`git -C dir` and `git -c k=v`, and the body of `sh -c '...'` or `eval '...'`). A rule written as
`^git push` then also sees `sudo /usr/bin/git -C repo push`.

First match wins within one command. Across the commands of a line, the highest tier wins: a
tier-2 rule on the first command must not hide a tier-3 command after it.

## 5. The database gate keys on the port

When databases sit in a private network, a client aimed at the cloud hostname hangs, and the
only working path is a local tunnel on a known port. A rule that gates only the hostname locks
the path that cannot work and leaves the tunnel open. So the rules look for a database client
in command position with the tunnel port in its arguments, or any environment assignment that
carries the port (`PGPORT=`, `DATABASE_URL=`). The ports and the production host are
placeholders (`<DEV_PORT>`, `<PROD_PORT>`, `<PROD_HOST>`) filled from `placeholders.json`,
because they differ in every setup.

The rule does not parse SQL: a `-c 'select 1; UPDATE ...'` splits into two commands, and a verb
regex would only see the harmless half. The read path is a wrapper that forces a read-only
transaction in Postgres, and it stays tier 2.

## 6. The guard protects itself

The guard reads three things an agent could write: the window file, the rules folder and the
job allowlist. Writing a window with scope `all`, creating an empty rules folder, or adding a
scope to a job would each switch the guard off. Editing the Claude Code settings could remove
the hook altogether. So writes to all of them are tier 3 on `guard-config`:

- a built-in rule, not a `rules/*.json` entry, so a custom rules folder cannot drop it;
- on Bash lines that write (redirect, `cp`, `mv`, `sed -i`, `rm`, `ln`, `chmod`, `mkdir`,
  `tee`, an interpreter...) to those paths, and on Write, Edit and NotebookEdit calls;
- read-only commands (`cat`, `grep`, `ls`, `jq` without a redirect...) stay free;
- a locked scope: no automatic window, no `all` window and no scheduled job covers it, only a
  manual `bin/unlock --scope guard-config`.

Windows are also bounded when read: at most 24 hours from their creation and from now, and a
window without `created_at` is ignored. A forged window with a far expiry is worthless even if
it gets written.

## 7. A claude under a claude is not a human

The supervision check walks the parent chain for a TTY. An agent can fake one: `script -q
/dev/null claude -p ...` gives the child a pseudo-terminal. It can also hand the child any
environment: a scheduled-job name, a rules folder, a window file path, a different `HOME`.

So the gate first looks for a claude process above the one that runs the hook. If it finds one,
the session is nested: unsupervised, its `CLAUDE_GUARD_*` variables are dropped, and `HOME`
comes from the user database. `bin/unlock` refuses to run with any claude among its ancestors,
because a pseudo-terminal defeats its TTY check too. The scheduled-job variable is honoured
only with no claude above and no terminal in the chain, which is what launchd or cron gives.

The check is a walk of the parent chain, and its limit is stated in the README: a process that
detaches from its parent first leaves no ancestor to find.

## 8. Speed is a safety property

The gate runs twice per tool call (the pre-hook and the audit). A lookup that spawns several
`jq` per rule is slow enough to be worth removing, so one `jq` pass emits every rule, nine
lines per rule. A delimiter-joined line breaks on bash 3.2, which macOS ships: it does not
split on `IFS=$'\001'`. Each field starts with a marker, so empty trailing fields survive the
command substitution. The parent-chain walk costs one `ps` per ancestor, which on macOS is
faster than one `ps` over a list of pids or over every process.

## 9. Fail-closed defaults

- `jq` missing, a malformed hook input, or any internal error in the gate: exit 2, the call is
  blocked.
- The lookup output is read line by line, never evaluated: a scope is data.
- Rules that fail to load, or zero rules: tier 3 on `guard-misconfigured`.
- Missing or malformed `external-scopes.json`: every tier-3 scope asks.
- Scheduled job without an entry: deny.
- `unlock` without a TTY on stdin, or under a claude process: refused.
- The test escape `CLAUDE_GUARD_ASSUME_UNSUPERVISED` can only force a deny.
- An automatic window never extends a valid one, and covers only the session that opened it.
