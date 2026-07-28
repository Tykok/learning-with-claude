# Quiz mode

`learner quiz [base-ref] [count]` — an interactive Q&A session about the **current
branch's** changes (the whole branch diff, not just this session's edits). The
on-demand counterpart to the Stop-hook quiz.

## Load config

Load config the same way as `SKILL.md` § Config. An explicit `learner quiz` runs even
when `enabled` is `false` — the dev asked for it directly.

`level` sets difficulty (level table in `SKILL.md`); `questionStyles` limits the
formats, `auto` = vary; `blanksPerExercise` supplies `blanks` for a `fill` exercise
(protocol in `references/hook-quiz.md`).

## Compute the branch diff

Pick the base ref from `$ARGUMENTS` if one is given, else fall back through the
repo's usual integration branches:

```bash
BASE=$(git merge-base origin/develop HEAD 2>/dev/null \
  || git merge-base develop HEAD 2>/dev/null \
  || git merge-base origin/main HEAD 2>/dev/null \
  || git merge-base main HEAD 2>/dev/null \
  || git merge-base master HEAD)
git diff --stat "$BASE"..HEAD
git diff "$BASE"..HEAD
```

Honour a base ref and/or a count from `$ARGUMENTS` (`quiz`, `quiz 5`,
`quiz origin/develop`, `quiz develop 4`). Read the diff so every question is grounded
in real code — never quiz on code you have not read. Ignore pure-docs and
test-scaffolding churn unless it is the point of the branch.

## Run the session

First read `references/data.md`: `memory.md` is the only file that drives question
selection, so read it before choosing the first question — prefer a still-open weak
spot when relevant (spaced repetition).

- One question at a time. Wait for each answer before asking the next; never answer
  for the dev.
- Brief feedback (correct / to fix, plus the missing bit) after each answer.
- Spread coverage across the branch's distinct areas (data model, persistence, core
  logic, error handling, external integrations, config/build) rather than re-asking
  about one file.
- Default to ~5 questions, then a closing synthesis question. Honour a count from
  `$ARGUMENTS`.
- Stop early on repeated `skip` or on `stop`.
- For a `fill`-style question, follow the protocol in `references/hook-quiz.md`.

After each answer, update `references/data.md`: record the outcome in `memory.md`
and `recap.md`.

## Wrap up

Close with a one-line recap of what looked solid and what is worth revisiting.
