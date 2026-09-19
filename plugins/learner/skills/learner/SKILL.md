---
description: Learning mode — the hub of the `learner` skills: dispatch table, the five levels, and every config key. Also the entry point for the Stop hook's 🎓 Learner trigger line, and for `learner config`, `learner off`/`on` and `learner help`. Use for "learner", "mode apprentissage", "learner config", "learner off", "learner on", "learner help", "level=S", or any bare Learner setting change.
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
`🧑‍🏫 Coach (level: S, cycle: 3, files: 2, lines: 62) — Service.kt Mapper.kt`. The review fires
when the dev pauses typing, not on a clock or a quota; `files` and `lines` then size it. When you
see it, read the `coach` skill and follow it with those values. As with the quiz trigger, the
line is parameters, not the protocol.

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
| `coachPollSeconds` | int ≥ 5 | `30` | How often the watcher measures the dev's changes |
| `coachQuietPolls` | int ≥ 1 | `1` | Consecutive unchanged polls — a pause — before a review fires |
| `coachMinLines` | int ≥ 1 | `10` | Fewer changed lines than this never triggers a review |
| `coachCooldownMinutes` | int ≥ 0 | `3` | Floor between two reviews |
| `coachMaxWaitMinutes` | int ≥ 0 | `15` | Emit even without a pause once material has waited this long; `0` disables |
| `coachIdleMinutes` | int ≥ 1 | `45` | Zero changes for this long → the watcher stops |
| `pilotEnabled` | bool | `false` | Master switch for the `pilot` skill; global only, never per-repo |
| `pilotCadenceDays` | int ≥ 1 | `7` | Days between weekly briefs |
| `pilotJudgeIntervalHours` | int ≥ 1 | `24` | Hours between scoring-queue drains |
| `pilotNudge` | bool | `true` | Whether `pilot-nudge.sh` reminds on a live `direction` manoeuvre |

Styles: `code` = what a changed function does; `architecture` (alias `archi`) = which
module/layer it lives in and why; `fill` = interactive fill-in exercise in the real
source file (see `references/hook-quiz.md`).

To edit: read the target file, merge the new values over the existing ones, validate
(`level` in the five letters; `enabled` boolean; `questionStyles` `"auto"` or a subset;
`synthesisFrequency` one of the four words; ints ≥ 1; the two glob keys arrays of
non-empty strings; `coach` boolean; every `coach*` integer key is a positive integer
(`coachCooldownMinutes` and `coachMaxWaitMinutes` may be `0`)), write it, then confirm with
`jq -e . <file> >/dev/null && echo OK`. Reject invalid values and re-ask instead of
writing them. A config still carrying a v1 key (`coachCadence`, `coachWorkMinutes`,
`coachWorkGrowthMinutes`, `coachWorkMaxMinutes`, `coachChallengeMinutes`, `coachIdleCycles`,
`coachLines`, `coachFiles`, `coachEveryMinutes`) is not an error — name them once as ignored
and do not rewrite the dev's file, since silently dropping a key the dev may still be reading
elsewhere is worse than leaving it inert. `config` alone edits the global file; `config
project …`, `off` and `on` edit `<repo>/.claude/learner.local.json` and add that path to the
repo's `.gitignore` if it is missing. Those are the only writes into a repo.

