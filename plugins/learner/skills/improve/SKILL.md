---
description: Coach one recorded weak spot to mastery, grounded in this repo's real code, then mark it resolved. Use for "learner improve", "level me up", "help me get better at X", "m'améliorer sur", "je veux progresser sur".
allowed-tools: Read, Grep, Write(~/.claude/learner/**), Edit(~/.claude/learner/**), Bash(sh *learner-event.sh *), Bash(git diff *), Bash(git merge-base *), Bash(git rev-parse *), Bash(git show *), Bash(git status *), Bash(mkdir -p *learner), Bash(date *), Bash(grep -n *)
---

# Improve mode

`learner improve [topic]` — coach the dev to actually **master one weak spot**,
using the record of past quiz sessions plus the real code, then mark it resolved
once they demonstrate it. The level-up counterpart to `quiz`.

## Gather context

1. Load config as `../learner/references/config.md` describes.
2. Read `memory.md` (open weak spots) and the recap's `To improve` section plus its
   `Session history` — see `../learner/references/data.md` for paths.

## Pick the target

- The topic in `$ARGUMENTS`, fuzzy-matched against a bullet, if given.
- Otherwise the most relevant open weak spot (recurring, or oldest).
- Otherwise ask the dev which one.

Confirm out loud which weak spot you are about to work on.

## Ground it in the real code

Look at the `Session history` rows for that topic to see *how* the dev struggled
(verdicts, notes), then read the real source files the concept lives in. Ground
everything in this repo's actual code — never explain abstractly.

## Coach in a loop

Repeat until the dev demonstrates understanding or says `stop`:

1. A concise explanation of the concept and the *why*.
2. A worked example pulled from the real codebase.
3. An active-recall step — a targeted question, or a `fill` exercise honouring
   `questionStyles`/`blanksPerExercise` (protocol in `../learner/references/hook-quiz.md`).
   Emit it and close it in `events.jsonl` like any other question
   (`../learner/references/data.md`), with `--style` `code`, `architecture` or `fill` —
   never `improve`, which is only the recap row's style.
4. Wait for the dev, then give brief feedback.

## On mastery

Update both data files per `../learner/references/data.md`:

- Remove the weak spot from `memory.md`.
- Move its theme to `Mastered` in the recap.
- Append a `Session history` row with style `improve`, naming the theme in its `Theme` cell.

If the dev is not yet there, leave the weak spot open in `memory.md` and note in the
recap what still needs work.
