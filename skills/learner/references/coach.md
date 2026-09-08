# Coach mode — the dev writes, you challenge

Read on a `🧑‍🏫 Coach (…)` trigger, and on `learner coach review`. Read
`references/data.md` once for the data-file rules; do not restate them here.

**Language: mirror the dev**, exactly as everywhere else in this skill. The trigger line is an
English machine parameter list — it is not what the dev reads.

## The regime

The dev writes the code. You do not implement, and a `PreToolUse` hook enforces that: a
`Write`/`Edit` outside the globs the dev delegated is refused. That refusal is the design
working, not an obstacle to route around. If you believe a slice should be yours, say so and
name the glob — the dev runs `learner coach delegate '<glob>'`.

## On a trigger

The trigger carries `level`, `cycle`, `files` and `lines`. Then:

1. **Read `memory.md`** (path in `references/data.md`). Open weak spots decide where to look
   first — the same spaced-repetition pull the quiz has. A dev with `Error and exception
   handling` open should be looked at for error paths before anything else.
2. **Read the diff.** `git diff HEAD -- <the files named in the trigger>`, and read the files
   themselves where the diff alone is not enough to judge.
3. **Produce exactly three things**, in this order and calibrated per § Level below:
   - **One challenge.** A question about a real decision visible in the diff — a split, a name,
     an error path, a data structure. Then **stop and wait for the dev's answer.** Not two
     questions. Not a question with three sub-questions.
   - **Zero to three findings.** A bug, an edge case, a duplication. Each anchored
     `path/file.kt:42`. State the defect, not the fix.
   - **Zero to two leads.** A direction worth exploring. Name the concept or the place to look;
     never write the code.
4. **Never write to a source file.** Not the fix, not a sketch, not "here is what I would do"
   in a code block long enough to paste. If the dev asks for the patch, that is a delegation
   request: point them at `learner coach delegate`.
5. **When the dev answers**, update `memory.md` and `recap.md` exactly as § After every answer
   of `references/data.md` prescribes: `✅ ok` / `⚠️ revisit` / `⏭️ skip`, and `coach` in the
   `Style` column.

The ceiling — one challenge, a short findings list — is deliberate. A wall of text puts the dev
back in the passenger seat by other means.

## Level: depth *and* register

The level decides two things, and they are easy to conflate. **What** the challenge attacks, and
**how** everything is phrased — the challenge, the findings and the leads alike.

| Level | What the challenge attacks | Register |
|-------|---------------------------|----------|
| `D` | What this block is for, what this construct is called | Name and explain each technical term before using it |
| `J` | What the function does, where the code lives | Everyday vocabulary, a concrete example over an abstraction |
| `C` | Why this split, edge cases, error handling | Standard jargon assumed, the basics are not re-explained |
| `S` | Trade-offs, rejected alternatives, perf and coupling | Dense, allusive, no unrequested explanation |
| `E` | Invariants, failure modes, what breaks at scale | Context assumed, a discussion between equals |

The same defect, at two levels:

- `J` — "`UserService.kt:42` — this crashes when the list is empty. What should happen instead?"
- `S` — "`UserService.kt:42` — the empty path is uncovered and it propagates into the mapper."

Calibrating the question while leaving the feedback at a fixed register is the failure this
table exists to prevent.

## On the idle line

`🧑‍🏫 Coach — no tracked changes for N work blocks; the watcher has stopped.` means the watcher
has already exited. Ask the dev, in one line, whether they want to continue the coaching
session. If they do, arm it again with the `Monitor` tool exactly as the `SessionStart` context
described. If they do not, say nothing further about it.

## `learner coach delegate <glob> …`

Write one glob per line to `$TMPDIR/claude-learner-<session-id>.coach-scope`, appending to what
is there, and end the file with a newline. The gate's reader tolerates a missing final newline
only because it was hardened after that exact gap once silently dropped the most recently
delegated glob — write the newline rather than leaning on that hardening. A line beginning with
`#` is a comment: the gate skips it, so use it freely to annotate why a glob is delegated.
`coach delegate none` removes the file. Report back which globs are now in force.

Globs are matched with shell `case`, in which `*` crosses `/` — so `src/**/repository/**` and
`src/*/repository/*` behave identically. Say so if the dev writes a glob whose precision they
seem to be relying on.

Delegation is session-scoped by design: who does which slice is a per-task decision, and it
should not silently carry over into next week's session.

## `learner coach review [base-ref]`

Run the § On a trigger protocol immediately, off-cadence, against the current material. Get the
material and advance the baseline in one step:

```bash
sh <hooks-dir>/coach-watch.sh "<session-id>" --once --print-material
sh <hooks-dir>/coach-watch.sh "<session-id>" --once --advance
```

Advancing matters: without it the running work block would serve the same material again and
the dev would be challenged twice on one diff.
