# agent-guardrails

Hooks for [Claude Code](https://docs.claude.com/en/docs/claude-code) that let agents run with
wide autonomy while a few actions stay locked. The lock depends on **whether a human is in
front of the session**. The nature of the action alone does not decide.

I run a product and engineering team where most code, issues and pull requests start in a
Claude Code session, interactive or scheduled. These hooks are the safety layer of that setup,
extracted and made generic.

## The model

Every tool call gets a tier from a list of rules:

| Tier | Meaning | Behaviour |
|---|---|---|
| 1 | Free | Passes. Not logged. |
| 2 | Auditable | Passes. Logged with hashed arguments. |
| 3 | Locked | Depends on who is there, see below. |

A tier-3 call then follows four cases, in this order:

1. **Scheduled job** (`CLAUDE_GUARD_SCHEDULED_JOB` set by the plist or cron line): allowed only
   if `scheduled-jobs.json` lists the scope for this job. Least privilege, fail-closed.
2. **A window is open** on this scope: passes.
3. **A human is in front** (a real TTY in the parent chain):
   - an *external* scope (it leaves the company and no revert catches it: an email, a release,
     a production write) asks. The first yes opens a window on that scope, so a series of
     commands does not ask at each step.
   - an *internal* scope (push to main, force push, the dev database) passes. The human
     watches the thread and the audit keeps the trace.
4. **Nobody in front**: deny.

Two more hooks complete the set:

- `post-tool-audit.sh` writes tier-2 and tier-3 calls to a daily JSONL log.
- `pr-guard-post.sh` reads a pull request after its creation and tells the agent to add the
  missing assignee or reviewer. It deduces the reviewer from the paths of the diff.

## Why it is built this way

Each choice comes from an incident. [`docs/design.md`](docs/design.md) gives the full list.
The short version:

- **Repair after, instead of blocking before.** A blocking pre-hook on PR and issue creation
  stopped agents 35 times in 5 working days. Each block only sent the agent to replay the same
  command with one more flag. The post-hook reads the real state and repairs it, and it covers
  paths the pre-hook never saw (the MCP server, `--web`).
- **Gate on the human, not on the action.** 89 of 103 historical blocks came from one internal
  scope, merge to main. Blocking a watched session teaches people to click through. Locking only
  what is external, or what runs with nobody in front, keeps the prompts rare enough to be read.
- **A rule matches one command.** Rules run on each segment of a shell line. Unsplit, the `.*`
  of the force-push rule found a `-f` that belonged to a `pgrep` three commands later.
- **The gate decides by itself in bypass mode.** In one interactive session under
  `--dangerously-skip-permissions`, on an earlier Claude Code version, an `ask` went through
  with no prompt. A headless retest on 2.1.292 blocked it instead. The gate does not depend on
  either behaviour: in bypass mode it shows its own dialog (macOS) and returns `allow` or
  `deny`. With no dialog available, it denies.
- **The gate has to be cheap.** It runs twice per tool call. One `jq` pass for all rules took a
  lookup from 13 s to milliseconds. A gate nobody can afford is a gate that gets removed.

## Install

Requirements: `bash` (3.2 is fine), `jq`, `shasum`, and `gh` for the PR guard.

As a Claude Code plugin:

```
/plugin marketplace add cyphalle/agent-guardrails
/plugin install agent-guardrails@cyphalle
```

The bundled rules apply at once. Read [`rules/`](rules/) before you install: they gate pushes
to `main`, force pushes, branch deletion, releases, outbound email and two database tunnel
ports.

Your configuration lives in `~/.claude/guardrails/`, outside the plugin, so an update never
overwrites it:

```bash
mkdir -p ~/.claude/guardrails
cp examples/pr-guard.json ~/.claude/guardrails/pr-guard.json          # enables the PR guard
cp examples/scheduled-jobs.json ~/.claude/guardrails/scheduled-jobs.json
cp -R rules ~/.claude/guardrails/rules                                # to change the rules
```

- A `rules/` folder there replaces the bundled rules as a whole. Files are read in name order,
  and the first match wins. Patterns are POSIX ERE: write `[[:space:]]`, never `\s`.
- An `external-scopes.json` there replaces the bundled list of scopes that ask even with a
  human in front.
- `rules/10-database.json` assumes a dev tunnel on `15432` and a prod tunnel on `25432`.
  Change the ports to yours.

Without the plugin system, clone the repo and merge
[`examples/settings.json`](examples/settings.json) into `~/.claude/settings.json`.

Open a window ahead of time, from your own terminal:

```bash
bin/unlock --scope gh-release --duration 1h
bin/audit-tail
```

## Configuration

| Variable | Default |
|---|---|
| `CLAUDE_GUARD_CONFIG_DIR` | `~/.claude/guardrails` |
| `CLAUDE_GUARD_RULES_DIR` | `<config>/rules/`, else the bundled `rules/` |
| `CLAUDE_GUARD_SENTINEL` | `~/.claude/guardrails-unlock` |
| `CLAUDE_GUARD_AUDIT_DIR` | `~/.claude/guardrails-audit` |
| `CLAUDE_GUARD_SCHEDULED_JOBS` | `<config>/scheduled-jobs.json` |
| `CLAUDE_GUARD_EXTERNAL_SCOPES` | `<config>/external-scopes.json`, else the bundled one |
| `CLAUDE_GUARD_PR_CONFIG` | `<config>/pr-guard.json` (no file: the PR guard stays off) |
| `CLAUDE_GUARD_SCHEDULED_JOB` | set by your scheduler, never by hand |

## Tests

```bash
bash tests/run.sh
```

The supervised cases run only when the test runs in a terminal. CI runs the rest on Linux and
macOS.

## Limits

- The TTY check tells a terminal session from a headless one. It does not prove that the person
  at the terminal reads the thread.
- Regex rules on shell lines catch the usual forms. A determined agent can write a command they
  do not match (a script file, an alias). Keep server-side protection on what matters: branch
  protection on `main`, read-only database roles.
- The native dialog under bypass mode is macOS only. Elsewhere, an external tier-3 call in
  bypass mode is denied.

## License

MIT
