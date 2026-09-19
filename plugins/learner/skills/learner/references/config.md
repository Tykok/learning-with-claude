# Config

Read whenever a subcommand needs the settings: `config`, `off`, `on`, and the config-load
step of the `quiz` and `improve` skills (their own files cover what they do
with the values once loaded; this file owns the layers, the keys and the validation rules,
and is not restated there).

## Two layers, later wins key by key

1. `$CLAUDE_CONFIG_DIR/learner.json` (default `~/.claude/learner.json`) — the dev's
   defaults for every repo.
2. `<repo>/.claude/learner.local.json` — optional, gitignored, partial override.

## Keys

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
| `agentSalvo` | bool | `true` | Salvo of questions while a subagent is in flight |
| `agentSalvoQuestions` | int ≥ 0 | `2` | Questions in a salvo, before the exercise |
| `agentSalvoFill` | bool | `true` | Cut a `fill` exercise at the end of a salvo |

Styles: `code` = what a changed function does; `architecture` (alias `archi`) = which
module/layer it lives in and why; `fill` = interactive fill-in exercise in the real
source file (see `references/hook-quiz.md`).

## Editing

To edit: read the target file, merge the new values over the existing ones, validate
(`level` in the five letters; `enabled` boolean; `questionStyles` `"auto"` or a subset;
`synthesisFrequency` one of the four words; ints ≥ 1; the two glob keys arrays of
non-empty strings; `coach` boolean; every `coach*` integer at or above the floor in the
table above; `agentSalvo` and `agentSalvoFill`
booleans; `agentSalvoQuestions` an integer ≥ 0 — the floor is **0**, not 1 like every
other integer key, because an exercise-only salvo is a legitimate setting), write it,
then confirm with `jq -e . <file> >/dev/null && echo OK`. Reject invalid values and
re-ask instead of writing them.

A config still carrying a v1 coach key (`coachCadence`, `coachWorkMinutes`,
`coachWorkGrowthMinutes`, `coachWorkMaxMinutes`, `coachChallengeMinutes`, `coachIdleCycles`,
`coachLines`, `coachFiles`, `coachEveryMinutes`) is not an error — name them once as ignored
and do not rewrite the dev's file, since silently dropping a key the dev may still be reading
elsewhere is worse than leaving it inert. Two v1 keys were **kept with new meanings** and are
the more dangerous case, because they are still read: `coachPollSeconds` (v1 default `45`) and
`coachCooldownMinutes` (v1 default `5`) applied only to the removed threshold cadence and now
drive the single pause cadence, at the defaults in the table above. Name them as *changed*, not
as obsolete — a config still carrying `coachPollSeconds: 300` silently turns the pause into a
five-minute one.

`config` alone edits the global file; `config project …`, `off` and `on`
edit `<repo>/.claude/learner.local.json` and add that path to the repo's `.gitignore`
if it is missing. Those are the only writes into a repo.
