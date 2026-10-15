# agent-guardrails

Hooks for [Claude Code](https://docs.claude.com/en/docs/claude-code) that let agents run with
wide autonomy while a few actions stay locked. The lock depends on **whether a human is in
front of the session**. The nature of the action alone does not decide.

They come from a setup where most code, issues and pull requests start in a Claude Code
session, interactive or scheduled. This repo is the safety layer of that setup, made generic.

## The model

Every tool call gets a tier from a list of rules:

| Tier | Meaning | Behaviour |
|---|---|---|
| 1 | Free | Passes. Not logged. |
| 2 | Auditable | Passes. Logged with hashed arguments. |
| 3 | Locked | Depends on who is there, see below. |

A tier-3 call then follows four cases, in this order:

1. **Scheduled job** (`CLAUDE_GUARD_SCHEDULED_JOB` set by the plist or cron line): allowed only
   if `scheduled-jobs.json` lists the scope for this job. Least privilege, fail-closed. The
   variable counts only for a claude with no terminal and no claude process above it.
2. **A window is open** on this scope: passes. A window opened by a human yes covers the
   session that said yes; a window opened with `bin/unlock` covers every session.
3. **A human is in front** (a real TTY in the parent chain, and no claude process above the one
   that runs the hook). Scopes are split by who an action affects:
   - *External* actions (email, CRM, payments, production database writes) ask a human every
     time. The first yes opens a window on that scope for the session, so a series of commands
     does not ask at each step.
   - *Internal* actions on your own repositories pass in a supervised session and are logged.
4. **Nobody in front**: deny.

Two scopes are locked harder, because they protect the guard itself:

- `guard-config`: any write to the guard's configuration (`~/.claude/guardrails*`, the window
  file, the rules, the job allowlist, the Claude Code settings files, the installed plugin). It
  always asks with a human in front, and no automatic window, no `all` window and no scheduled
  job covers it. Only `bin/unlock --scope guard-config` does.
- `guard-misconfigured`: the rules could not be loaded (invalid JSON, a tier other than 1-3, a
  pattern bash cannot compile, zero rules). Every call then becomes tier 3 on this scope: it
  asks with a human in front and is denied without one. A broken rule file never falls back to
  "everything is tier 1".

In bypass mode the gate never relies on `ask`: it shows its own confirmation dialog, and with no
screen attached it denies. The dialog shows the command that matched (or the main arguments of
an MCP call), and Deny is the default button.

Two more hooks complete the set:

- `post-tool-audit.sh` writes tier-2 and tier-3 calls to a daily JSONL log. The gate also logs
  its denials there.
- `pr-guard-post.sh` reads a pull request after its creation and tells the agent to add the
  missing assignee or reviewer. It deduces the reviewer from the paths of the diff.

## Why it is built this way

[`docs/design.md`](docs/design.md) gives the reasoning behind each choice. The short version:

- **Repair after, instead of blocking before.** A pre-hook that refuses `gh pr create` without
  the right flags only sends the agent to replay the same command with one more flag, and it
  cannot see the MCP path or `--web`. A post-hook reads the real state and repairs it.
- **Gate on the human, not on the action.** Blocking internal actions in a watched session
  teaches people to click through. Locking only what is external, or what runs with nobody in
  front, keeps the prompts rare enough to be read.
- **A rule matches one command.** Rules run on each command of a shell line, after the command
  word is normalised (`sudo`, `env`, absolute paths, `git -C`, `bash -c '...'`). Across the
  commands of a line, the highest tier wins.
- **The guard protects its own configuration.** A guard whose window file or rules an agent can
  write is a guard the agent can switch off.
- **The gate fails closed.** A missing `jq`, a malformed input or any internal error blocks the
  call (exit 2). Rules that fail to load are tier 3.
- **The gate has to be cheap.** It runs twice per tool call. A gate nobody can afford is a gate
  that gets removed.

## Install

Requirements: `bash` (3.2 is fine), `jq`, `ps`, `shasum`, and `gh` for the PR guard.

As a Claude Code plugin:

```
/plugin marketplace add cyphalle/agent-guardrails
/plugin install agent-guardrails@cyphalle
```

The bundled rules apply at once. Read [`rules/`](rules/) before you install: they gate pushes
to `main`, force pushes, branch deletion, PR merges, releases, outbound email and database
tunnels.

Your configuration lives in `~/.claude/guardrails/`, outside the plugin, so an update never
overwrites it. Writing there from a Claude Code session is itself gated (scope `guard-config`),
so set it up from your own terminal:

```bash
mkdir -p ~/.claude/guardrails
cp examples/pr-guard.json ~/.claude/guardrails/pr-guard.json          # enables the PR guard
cp examples/scheduled-jobs.json ~/.claude/guardrails/scheduled-jobs.json
cp examples/placeholders.json ~/.claude/guardrails/placeholders.json  # then set your values
mkdir -p ~/.claude/guardrails/rules
cp -R rules/. ~/.claude/guardrails/rules/                             # to change the rules
```

- A `rules/` folder there replaces the bundled rules as a whole. Files are read in name order,
  and the first match wins. Patterns are POSIX ERE: write `[[:space:]]`, never `\s`. An empty
  folder is reported as `guard-misconfigured`, not read as "no rules".
- `placeholders.json` fills the `<NAME>` placeholders of the rules. The database rules use
  `<DEV_PORT>`, `<PROD_PORT>` (your local tunnel ports) and `<PROD_HOST>` (your production
  database host). An unset placeholder matches nothing, so the database rules stay inert until
  you set them:

  ```json
  { "DEV_PORT": "5433", "PROD_PORT": "5434", "PROD_HOST": "db.example.com" }
  ```

- An `external-scopes.json` there replaces the bundled list of scopes that ask even with a
  human in front.

Without the plugin system, clone the repo and merge
[`examples/settings.json`](examples/settings.json) into `~/.claude/settings.json`. The clone's
own files are then protected as `guard-config` too.

Open a window ahead of time, from your own terminal (not from inside a Claude Code session,
where `unlock` refuses to run):

```bash
bin/unlock --scope gh-release --duration 1h
bin/audit-tail
```

## Configuration

| Variable | Default |
|---|---|
| `CLAUDE_GUARD_CONFIG_DIR` | `~/.claude/guardrails` |
| `CLAUDE_GUARD_RULES_DIR` | `<config>/rules/`, else the bundled `rules/` |
| `CLAUDE_GUARD_SENTINEL` | `~/.claude/guardrails-unlock` (the window file) |
| `CLAUDE_GUARD_AUDIT_DIR` | `~/.claude/guardrails-audit` |
| `CLAUDE_GUARD_SCHEDULED_JOBS` | `<config>/scheduled-jobs.json` |
| `CLAUDE_GUARD_EXTERNAL_SCOPES` | `<config>/external-scopes.json`, else the bundled one |
| `CLAUDE_GUARD_PR_CONFIG` | `<config>/pr-guard.json` (no file: the PR guard stays off) |
| `CLAUDE_GUARD_SCHEDULED_JOB` | set by your scheduler, never by hand |

In a nested session (a claude with another claude among its ancestors, typically one an agent
started from its Bash tool), every `CLAUDE_GUARD_*` variable is ignored, `HOME` is read from the
user database, and the session counts as unsupervised.

A window lasts at most 24 hours. The window file is read with that bound, so a hand-written
window with a far expiry, or without `created_at`, is ignored.

## Tests

```bash
bash tests/run.sh
```

The supervised cases run only when the test runs in a terminal. CI runs the rest on Linux and
macOS. `shellcheck -x hooks/*.sh hooks/lib/*.sh bin/* tests/run.sh` is clean.

## Limits

- The TTY check tells a terminal session from a headless one. It does not prove that the person
  at the terminal reads the thread.
- Nested sessions are found by walking the parent chain. A process that detaches from its parent
  before it starts claude (a double fork, `setsid`, a job the agent schedules itself) has no
  claude ancestor left to find, and a pseudo-terminal from `script` would then pass for a
  terminal. A renamed copy of the claude binary is not recognised either. The same limit
  applies to the scheduled-job variable: it is trusted only when no claude is found above.
- Regex rules on shell lines catch the usual forms. A determined agent can write a command they
  do not match (a script file, an alias, a path built from variables, an interpreter one-liner
  that does not name the file). The same goes for the `guard-config` protection. Keep
  server-side protection on what matters: branch protection on `main`, read-only database
  roles, file permissions.
- PR merges are all tier 3 on `gh-merge-main`, whatever their base branch: the gate does not
  ask GitHub for the base, because it makes no network call.
- The audit log is a plain file owned by you. It records what ran; it is not tamper-proof.
- The native dialog under bypass mode is macOS only. Elsewhere, an external tier-3 call in
  bypass mode is denied.

## License

MIT
