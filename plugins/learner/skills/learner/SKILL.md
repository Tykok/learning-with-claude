---
description: Learning mode — the hub of the `learner` skills: dispatch table, the five levels, and every config key. Also the entry point for the Stop hook's 🎓 Learner trigger line and for the agent salvo's trigger line while a subagent is in flight, and for `learner config`, `learner off`/`on` and `learner help`. Use for "learner", "mode apprentissage", "learner config", "learner off", "learner on", "learner help", "level=S", or any bare Learner setting change.
allowed-tools: Read, Write, Edit, Grep, Bash
---

# Learner

Ask the dev questions about the code they just wrote, at their level, and keep a
record of what they should level up on.

**Language: mirror the dev.** Write every question, feedback line and summary in the
language the dev is using in this conversation. There is no language setting.

## Dispatch

`learner <subcommand> [args]` — the subcommand is the first token of `$ARGUMENTS`.

In a plugin install each subcommand is also its own skill, invocable directly: `/learner:quiz`,
`/learner:status`, `/learner:improve`, `/learner:coach`, `/learner:export`,
`/learner:update`, `/learner:sync`, `/learner:pilot`. The table below is the routing from the `learner <subcommand>` phrasing
to the skill that holds the protocol.

| Subcommand | Mode | Read |
|------------|------|------|
| `quiz [base-ref] [count]` | Q&A over the current branch diff | the `quiz` skill |
| `status` | Read-only summary: level + what to improve | the `status` skill |
| `improve [topic]` | Coach one weak spot to mastery | the `improve` skill |
| `coach on` / `coach off` | Turn the coach regime on/off in this repo | the `coach` skill |
| `coach delegate <glob> …` | Let Claude write inside those globs this session; `none` clears | the `coach` skill |
| `coach review [base-ref]` | Run one review now, off-cadence | the `coach` skill |
| `export [notion-page-url]` | Push the recap into a Notion database | the `export` skill |
| `sync push` / `sync pull [gist]` / `sync status` / `sync use <gist>` | Carry the learning record between machines through a private gist | the `sync` skill |
| `events import` | Backfill the IDE event log from `recap.md`'s Session history, once | this file, § Events |
| `update` | Check the remote version; re-install that release if newer | the `update` skill |
| `config [key=value …]` | View/edit settings; `config project …` scopes to this repo | `references/config.md` |
| `off` / `on` | Disable/enable the automatic quiz in this repo | `references/config.md` |
| `pilot …` | Invoke the `pilot` skill and hand it the rest of the line | — |
| `help` (or `-h`, `--help`) | Print this dispatch table + the parameter table, then stop | `references/config.md` |
| *(empty)* | Same as `config` with no pairs: show current settings | `references/config.md` |

A bare config instruction with no subcommand (`level=S`, `disable`) is `config` shorthand.

**Invoked by the Stop hook.** The hook blocks with a trigger line of the form `🎓 Learner (level: S, mode: granular, styles: auto, blanks: 2) — files: a.kt b.kt`. When you see it, read `references/hook-quiz.md` and follow it with those values. Do not treat the trigger as the protocol — it is only parameters.

**Invoked by the coach watcher.** A `Monitor` armed at session start blocks with
`🧑‍🏫 Coach (level: S, cycle: 3, files: 2, lines: 62) — Service.kt Mapper.kt`. The review fires
when the dev pauses typing, not on a clock or a quota; `files` and `lines` then size it. When you
see it, read the `coach` skill and follow it with those values. As with the quiz trigger, the
line is parameters, not the protocol.

**Invoked by the agent salvo.** While a subagent is in flight, the Stop hook blocks with
`🤖 Learner salvo (level: S, questions: 2, blanks: 2, styles: auto, agent 2/3, coach: off) — task: … — files: …`.
Read `references/agent-salvo.md` and follow it with those values. As with the other two
triggers, the line is parameters, not the protocol.

## Levels

The canonical value is the letter. Accept the full word and any case as an alias.

| Letter | Name | What a question targets | Register (coach) |
|--------|------|-------------------------|------------------|
| `D` | Discovering | syntax, what a block is for, basic vocabulary | name and explain each term before using it |
| `J` | Junior | what the function does, where the code lives | everyday vocabulary, a concrete example over an abstraction |
| `C` | Competent | why this split, edge cases, error handling | standard jargon assumed, basics not re-explained |
| `S` | Senior | trade-offs, rejected alternatives, perf and coupling impact | dense, allusive, no unrequested explanation |
| `E` | Expert | invariants, failure modes, what breaks at scale | context assumed, a discussion between equals |

## Events

`learner events import` — run the script below and report its counts in one sentence; safe to run twice, since rows already in the log are counted as `already`, not re-added; rows dated from the first live question on are counted as `live` and left out, since the log already holds them.

```bash
HOOKS="${CLAUDE_PLUGIN_ROOT:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/hooks"
[ -f "$HOOKS/learner-event.sh" ] || HOOKS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks"
sh "$HOOKS/learner-event.sh" import
```
