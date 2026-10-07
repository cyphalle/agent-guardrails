# Design notes

Each rule of this repo exists because something went wrong without it. This file keeps the
incidents, so a future change can tell a rule that still protects from one that only costs.

## 1. The lock follows the human

The first version gated on the action: a tier-3 call always needed a manual `unlock` typed in
another terminal. Over its life, 89 of 103 blocks came from the merge-to-main scope. Every one
of them happened with the author in front of the session. The block protected nothing, and it
trained the habit of opening a long blanket window.

The current version asks a different question: can anyone see this call? With a human in front,
internal actions pass and the audit keeps them. External actions ask once, then a window covers
the series. With nobody in front, everything tier 3 is denied, except what a scheduled job lists.

## 2. In bypass mode, the gate does not rely on `ask`

In one interactive session under `--dangerously-skip-permissions`, on an earlier Claude Code
version, a tier-3 call went through with no prompt and no window. A retest on 2.1.292, headless
(`claude -p`), went the other way: the `ask` blocked the call. The behaviour of `ask` in bypass
mode is therefore not something to build on. In that mode the gate shows its own dialog, writes
the answer to the audit log, and returns `allow` or `deny` itself. A timeout or a missing screen
is a deny.

## 3. Post-hooks repair, pre-hooks block

PR and issue creation had a blocking pre-hook: no reviewer, no assignee, no priority meant a
refusal. In 5 working days it fired 35 times, the largest single source of friction in the
setup. Each refusal led to the same command replayed with one more flag. It also could not see
the MCP path or flags that GitHub silently dropped.

The post-hook reads the real state of the PR and gives the agent the exact `gh pr edit` that
repairs it. The rule did not change. Only the moment of the check moved.

## 4. One command per match

A rule describes one command, but it used to run on the whole shell line. Two real cases:

- `git push origin HEAD 2>&1 | tail -2; pgrep -f run-job.sh` was blocked as a force push. The
  `-f` belonged to `pgrep`.
- A patch to this very file was blocked because its own comments quoted the patterns.

The lookup now folds backslash continuations, splits on `; & | &&` and newlines, and tests each
segment. The split can only produce more segments, so it never merges two commands. Anchored
rules (`^git push`) became stricter too: they used to see only the first command of a line.

## 5. The database gate keys on the port

Both databases sat in a private network. A client aimed at the cloud hostname hangs, and the
only working path is a local tunnel on a known port. The first rule gated the hostname: it
locked the path that cannot work and left the tunnel ungated. A production `UPDATE` through the
tunnel needed no approval at all.

The rule now looks for a database client in command position with the tunnel port in its
arguments, or an env assignment that carries the port. It does not parse SQL: a `-c 'select 1;
UPDATE ...'` splits into two segments, and a verb regex would only see the harmless half. The
read path is a wrapper that forces a read-only transaction in Postgres, and it stays free.

## 6. Speed is a safety property

The lookup first spawned two `jq` per rule, plus five more per match. With 131 rules, one lookup
took 13 s, and it runs twice per tool call. One `jq` pass now emits every rule, nine lines per
rule. A tab- or `\001`-joined format broke on bash 3.2, which macOS ships: it does not split on
`IFS=$'\001'`, every field landed in `TIER`, and the `eval` took every tool call down.

## 7. Fail-closed defaults

- Missing or malformed `external-scopes.json`: every tier-3 scope asks.
- Scheduled job without an entry: deny.
- `unlock` without a TTY on stdin: refused, so an agent cannot open its own window.
- The test escape `CLAUDE_GUARD_ASSUME_UNSUPERVISED` can only force a deny.
- An automatic window never extends a valid one. Extension would turn one yes into a blank
  cheque, and overwrite would shrink a manual `all` window.
