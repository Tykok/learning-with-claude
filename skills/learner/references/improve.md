# Improve mode

`learner improve [topic]` — coach the dev to actually **master one weak spot**,
using the record of past quiz sessions plus the real code, then mark it resolved
once they demonstrate it. The level-up counterpart to `quiz`.

## Gather context

1. Load config the same way as `SKILL.md` § Config.
2. Read `memory.md` (open weak spots) and the recap's `To improve` section plus its
   `Session history` — see `references/data.md` for paths.

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
   `questionStyles`/`blanksPerExercise` (protocol in `references/hook-quiz.md`).
4. Wait for the dev, then give brief feedback.

## On mastery

Update both data files per `references/data.md`:

- Remove the weak spot from `memory.md`.
- Move its theme to `Mastered` in the recap.
- Append a `Session history` row with style `improve`, naming the theme in its `Theme` cell.

If the dev is not yet there, leave the weak spot open in `memory.md` and note in the
recap what still needs work.
