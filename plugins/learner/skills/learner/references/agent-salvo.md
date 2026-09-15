# Agent salvo — questions while the subagents work

Read on a `🤖 Learner salvo (…)` trigger. Read `references/data.md` once for the data-file
rules and `references/hook-quiz.md` for the questioning rules; this file does not restate
either — three channels drifting apart is exactly what restating them causes.

**Language: mirror the dev**, as everywhere else in this skill. The trigger line is an English
machine parameter list; it is not what the dev reads.

## Why this exists

Claude has just delegated work to one or more subagents. Until they return, the main
conversation has nothing to do and the dev is a spectator — with the decision that produced the
delegation still fresh and the code the agents will touch still unmodified. That window is the
best teaching material a session produces, and it expires when the agents come back.

The salvo is **bounded**: `questions` questions, then one exercise, then silence. It does not
refill while the agents keep working. A dev who wanted an endless quiz would have asked for one.

## The trigger

`🤖 Learner salvo (level: S, questions: 2, blanks: 2, styles: auto, agent 2/3, coach: off) — task: … — files: …`

| Field | Meaning |
|-------|---------|
| `level` | Difficulty and register — the level table in `SKILL.md` |
| `questions` | How many questions to ask before the exercise. May be `0` |
| `blanks` | Holes to cut in the exercise |
| `styles` | Allowed question formats, as in `hook-quiz.md` |
| `agent N/M` | This salvo's rank in the current batch of dispatches |
| `coach` | `on` means no exercise — see § The exercise |
| `task` | The description of the most recently dispatched agent still in flight |
| `files` | Files edited since the last question, possibly empty |

## Order of operations

1. **Launch the preparation agent first** (§ The exercise), unless `coach: on` or the exercise
   is off. It works while the dev answers, which is the entire reason the exercise comes last.
2. **Read `memory.md`** (path in `references/data.md`). Open weak spots pull the choice of
   question, the same spaced repetition the quiz and the coach use.
3. **Ask `questions` questions, one at a time.** Wait for each answer and give brief feedback
   before the next. Never two at once, never a question with sub-questions.
4. **Run the exercise** when the preparation agent reports.
5. **Record** every answer in `memory.md` and `recap.md` per `references/data.md` § *After every
   answer*, with `salvo` in the `Style` column.

`references/hook-quiz.md` § *Never hand the answer over* applies in full. A question that
quotes both sides of a hunk has already answered itself, and the failure is invisible from
here — the answer comes back correct.

## Material

All four sources are in scope. The order is what to reach for first when several apply.

1. **The delegated task** — from `task:`. Why this slice was split off, what its output has to
   satisfy, which failure mode it invites. No other channel can reach this material, and it is
   fresh for exactly as long as the agent runs.
2. **The branch diff** — as `references/quiz.md` resolves the base ref.
3. **The code the agents are about to touch** — read it *now*, before it changes: what it
   currently guarantees, what the change could break, what the callers assume.
4. **Open weak spots** — a `To improve` entry from `memory.md`, even unrelated to the task.

At `agent 2/3` and `3/3`, prefer a source the earlier salvos of this batch did not use. Three
near-identical questions in a row is the failure mode of a per-agent cadence.

## The exercise

The last step of the salvo is one `fill` exercise — real holes in the dev's real code, cut by a
**dedicated preparation agent** so it is ready by the time the questions are answered.

**Skip it entirely when `coach: on`.** In the coach regime `hooks/coach-gate.sh` denies writes
outside the delegated globs, and the preparation agent's edit is one of them. The barrier is not
weakened for the learner's own convenience; the salvo is questions-only there.

### Dispatching the preparation agent

**Its description MUST start with `learner-prep:`.** This is a contract, not a convention:
`hooks/learner-agent-track.sh` skips those dispatches, and a preparation agent that is *not*
skipped arms a salvo of its own, whose preparation agent arms another, with no bottom.

Its prompt carries the level letter, `blanks`, the candidate files, and the descriptions of the
agents currently in flight. Its mission:

- Pick **one** short function among the candidates and cut `blanks` holes in it as
  `// LEARNER-TODO: <hint>` comments calibrated to the level — `hook-quiz.md` § *The `fill`
  protocol*, steps 1–3.
- **Stay outside the in-flight agents' scope.** It is handed their descriptions and must avoid a
  file they plausibly touch. Two writers on one function is a merge conflict dressed up as a
  lesson.
- **Prefer committed code.** A function already in `HEAD` can be restored from git if anything
  goes wrong; an uncommitted one cannot.
- **Report the file and the function, and nothing else.** No hint that names the construct, no
  sketch of the answer: the report is pasted to the dev as it stands.

### When it reports

Tell the dev the file and the function, ask them to write the missing code **in the file**, and
wait. Feedback, restoration and verification follow `hook-quiz.md` § *The `fill` protocol*,
steps 5–7 — including the rule that a turn never ends with a `// LEARNER-TODO` surviving. The
Stop hook's guardrail enforces it either way.

### When it fails

It finds no suitable function, it errors, or the dev has moved on: say one line and end the
salvo on the questions. A missing exercise is not worth a retry loop.

## When another channel is already in progress

A coach challenge in progress wins: finish it, record the answer, then open the salvo. Never
both at once. `references/coach.md` states the same rule from the other side.
