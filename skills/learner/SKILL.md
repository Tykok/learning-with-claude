---
description: Learning mode. Invoke as "learner" with a subcommand — "quiz" (Q&A on the current branch), "status" (what to improve + level), "improve" (coach one weak spot to mastery), "coach" (coach mode: the dev writes the code, you challenge it — "coach on"/"off", "coach delegate <glob>", "coach review"), "export" (push the recap into a Notion database), "update" (check for a newer version and refresh), "config" (settings, incl. "off"/"on" for this repo), "help". Also invoked by the Stop hook, which passes a trigger line, and by the coach watcher's trigger line. Trigger on "learner", "learner quiz", "learner status", "learner improve", "learner export", "learner update", "learner config", "learner off", "quiz me", "quiz me on the branch", "what should I improve", "my level", "level me up", "mode apprentissage", "interroge-moi", "quiz sur la branche", "ce que je dois améliorer", "mon niveau", "m'améliorer sur", "exporter vers Notion", "learner coach", "coach on", "coach off", "coach delegate", "coach review", "mode coach", "passe en mode coach", "délègue-moi", "challenge-moi".
allowed-tools: Read, Write, Edit, Grep, Bash, mcp__claude_ai_Notion, mcp__notionApi, mcp__notion
---

# Learner

Ask the dev questions about the code they just wrote, at their level, and keep a
record of what they should level up on.

**Language: mirror the dev.** Write every question, feedback line and summary in the
language the dev is using in this conversation. There is no language setting.

## Dispatch

`learner <subcommand> [args]` — the subcommand is the first token of `$ARGUMENTS`.

| Subcommand | Mode | Read |
|------------|------|------|
| `quiz [base-ref] [count]` | Q&A over the current branch diff | `references/quiz.md` |
| `status` | Read-only summary: level + what to improve | this file, § Status |
| `improve [topic]` | Coach one weak spot to mastery | `references/improve.md` |
| `coach on` / `coach off` | Turn the coach regime on/off in this repo | `references/coach.md` |
| `coach delegate <glob> …` | Let Claude write inside those globs this session; `none` clears | `references/coach.md` |
| `coach review [base-ref]` | Run one review now, off-cadence | `references/coach.md` |
| `export [notion-page-url]` | Push the recap into a Notion database | `references/export.md` |
| `update` | Check the remote version; re-run `bootstrap.sh` pinned to it if newer | `references/update.md` |
| `config [key=value …]` | View/edit settings; `config project …` scopes to this repo | this file, § Config |
| `off` / `on` | Disable/enable the automatic quiz in this repo | this file, § Config |
| `pilot …` | Invoke the `pilot` skill and hand it the rest of the line | — |
| `help` (or `-h`, `--help`) | Print this dispatch table + the parameter table, then stop | — |
| *(empty)* | Same as `config` with no pairs: show current settings | this file, § Config |

A bare config instruction with no subcommand (`level=S`, `disable`) is `config` shorthand.

**Invoked by the Stop hook.** The hook blocks with a trigger line of the form `🎓 Learner (level: S, mode: granular, styles: auto, blanks: 2) — files: a.kt b.kt`. When you see it, read `references/hook-quiz.md` and follow it with those values. Do not treat the trigger as the protocol — it is only parameters.

**Invoked by the coach watcher.** A `Monitor` armed at session start blocks with `🧑‍🏫 Coach (level: S, cycle: 3, files: 2, lines: 62) — Service.kt Mapper.kt`. When you see it, read `references/coach.md` and follow it with those values. As with the quiz trigger, the line is parameters, not the protocol.

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

Styles: `code` = what a changed function does; `architecture` (alias `archi`) = which
module/layer it lives in and why; `fill` = interactive fill-in exercise in the real
source file (see `references/hook-quiz.md`).

To edit: read the target file, merge the new values over the existing ones, validate
(`level` in the five letters; `enabled` boolean; `questionStyles` `"auto"` or a subset;
`synthesisFrequency` one of the four words; ints ≥ 1; the two glob keys arrays of
non-empty strings; `coach` boolean; `coachCadence` one of the two words; every `coach*`
integer at or above the floor in the table above), write it, then confirm with
`jq -e . <file> >/dev/null && echo OK`. Reject invalid values and re-ask instead of
writing them. `coachWorkMaxMinutes` below `coachWorkMinutes` clamps to `coachWorkMinutes`
rather than being rejected — the intent of that pair is unambiguous. `config` alone edits
the global file; `config project …`, `off` and `on`
edit `<repo>/.claude/learner.local.json` and add that path to the repo's `.gitignore`
if it is missing. Those are the only writes into a repo.

## Status

Read-only: no quiz, no config write, no data-file update.

1. Level and version: `jq -r '.level // "not set"' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner.json"`
   (a project override wins if present), and
   `cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/learner/VERSION" 2>/dev/null` — unless this
   skill's own base directory (visible in your context when it loaded) contains `/plugins/`,
   in which case report the version as `plugin-managed` instead: a plugin install never
   creates that file, and Claude Code's own `/plugin` command is the source of truth for which
   version is installed.
2. Open weak spots: read the `To improve` sections of the recap (see
   `references/data.md` for paths). If nothing is recorded, say so and suggest `learner quiz`.
3. Print one line for the level and version, then one line for coach status — on/off, the
   current cycle if a coach session is running, and the delegated globs read from
   `$TMPDIR/claude-learner-<session-id>.coach-scope` when that file exists — then, if
   `pilotEnabled`, one line with Pilot's profile, weakest axis and live manoeuvre from
   `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner/pilot.md` (not a second dashboard) — then a
   handful of bullets: broad competency themes grouped by domain, skipping anything already
   under `Mastered`. Summarise; never dump the file. No tables, no history.
