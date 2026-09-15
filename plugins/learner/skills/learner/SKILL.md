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
| `update` | Check the remote version; re-run `bootstrap.sh` pinned to it if newer | the `update` skill |
| `config [key=value …]` | View/edit settings; `config project …` scopes to this repo | this file, § Config |
| `off` / `on` | Disable/enable the automatic quiz in this repo | this file, § Config |
| `pilot …` | Invoke the `pilot` skill and hand it the rest of the line | — |
| `help` (or `-h`, `--help`) | Print this dispatch table + the parameter table, then stop | — |
| *(empty)* | Same as `config` with no pairs: show current settings | this file, § Config |

A bare config instruction with no subcommand (`level=S`, `disable`) is `config` shorthand.

**Invoked by the Stop hook.** The hook blocks with a trigger line of the form `🎓 Learner (level: S, mode: granular, styles: auto, blanks: 2) — files: a.kt b.kt`. When you see it, read `references/hook-quiz.md` and follow it with those values. Do not treat the trigger as the protocol — it is only parameters.

**Invoked by the coach watcher.** A `Monitor` armed at session start blocks with
`🧑‍🏫 Coach (level: S, cycle: 3, files: 2, lines: 62) — Service.kt Mapper.kt`. When you see it,
read the `coach` skill and follow it with those values. As with the quiz trigger, the line is
parameters, not the protocol.

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

## Config

Two layers, later wins key by key:

1. `$CLAUDE_CONFIG_DIR/learner.json` (default `~/.claude/learner.json`) — the dev's
   defaults for every repo.
2. `<repo>/.claude/learner.local.json` — optional, gitignored, partial override.

| Key | Values | Default | Effect |
|-----|--------|---------|--------|
| `level` | `D`/`J`/`C`/`S`/`E` | — required | Question difficulty |
| `enabled` | bool | `true` | Master switch for the automatic quiz |
| `questionStyles` | `"auto"` or subset of `code`/`architecture`/`fill` | `"auto"` | Allowed formats |
| `synthesisFrequency` | `off`/`rare`/`normal`/`often` | `normal` | Synthesis question every 0/8/4/2 questions |
| `blanksPerExercise` | int ≥ 1 | `2` | `// LEARNER-TODO` holes in a `fill` exercise |
| `untrackGlobs` | array of globs | `[]` | Extra paths excluded from quiz material |
| `disabledPaths` | array of path prefixes | `[]` | Repos where learner stays silent |
| `coach` | bool | `false` | Coach regime: the dev writes, Claude challenges |
| `coachCadence` | `pomodoro`/`threshold` | `pomodoro` | Which clock drives reviews |
| `coachWorkMinutes` | int ≥ 1 | `25` | First work block, in minutes |
| `coachWorkGrowthMinutes` | int ≥ 0 | `5` | Added to the work block per completed cycle |
| `coachWorkMaxMinutes` | int ≥ 1 | `45` | Work-block ceiling |
| `coachChallengeMinutes` | int ≥ 0 | `8` | Challenge window, fixed |
| `coachIdleCycles` | int ≥ 1 | `2` | Empty work blocks before the watcher stops |
| `coachPollSeconds` | int ≥ 5 | `45` | Poll interval — `threshold` cadence only |
| `coachLines` | int ≥ 1 | `40` | Lines since last review that trigger one — `threshold` only |
| `coachFiles` | int ≥ 1 | `3` | Changed files that trigger one — `threshold` only |
| `coachEveryMinutes` | int ≥ 0 | `0` | Elapsed-time trigger, `0` = off — `threshold` only |
| `coachCooldownMinutes` | int ≥ 0 | `5` | Floor between two reviews — `threshold` only |
| `pilotEnabled` | bool | `false` | Master switch for the `pilot` skill; global only, never per-repo |
| `pilotCadenceDays` | int ≥ 1 | `7` | Days between weekly briefs |
| `pilotJudgeIntervalHours` | int ≥ 1 | `24` | Hours between scoring-queue drains |
| `pilotNudge` | bool | `true` | Whether `pilot-nudge.sh` reminds on a live `direction` manoeuvre |
| `agentSalvo` | bool | `true` | Salvo of questions while a subagent is in flight |
| `agentSalvoQuestions` | int ≥ 0 | `2` | Questions in a salvo, before the exercise |
| `agentSalvoFill` | bool | `true` | Cut a `fill` exercise at the end of a salvo |

Styles: `code` = what a changed function does; `architecture` (alias `archi`) = which
module/layer it lives in and why; `fill` = interactive fill-in exercise in the real
source file (see `references/hook-quiz.md`).

To edit: read the target file, merge the new values over the existing ones, validate
(`level` in the five letters; `enabled` boolean; `questionStyles` `"auto"` or a subset;
`synthesisFrequency` one of the four words; ints ≥ 1; the two glob keys arrays of
non-empty strings; `coach` boolean; `coachCadence` one of the two words; every `coach*`
integer at or above the floor in the table above; `agentSalvo` and `agentSalvoFill`
booleans; `agentSalvoQuestions` an integer ≥ 0 — the floor is **0**, not 1 like every
other integer key, because an exercise-only salvo is a legitimate setting), write it, then confirm with
`jq -e . <file> >/dev/null && echo OK`. Reject invalid values and re-ask instead of
writing them. `coachWorkMaxMinutes` below `coachWorkMinutes` clamps to `coachWorkMinutes`
rather than being rejected — the intent of that pair is unambiguous. `config` alone edits
the global file; `config project …`, `off` and `on` edit `<repo>/.claude/learner.local.json`
and add that path to the repo's `.gitignore` if it is missing. Those are the only writes
into a repo.

