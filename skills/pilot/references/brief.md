# Brief — the weekly conversation

This is the protocol for the weekly brief `hooks/pilot-brief.sh` offers as `additionalContext`
at `SessionStart`, and for `pilot brief` run off-cadence. Unlike `references/score.md`, this
runs **in the main session** — the whole point is a conversation with the dev, after their
first request of the session is served, never instead of it.

The score (`pilot.md`'s `Index` block) is the diagnostic. This conversation is the product.
Everything below exists to keep it from becoming the thing it is trying to prevent: a tool
that hands the dev a number and a lecture instead of making them think.

## First: is there enough to argue from?

`hooks/pilot-brief.sh` will not offer this brief until `pilot.md`'s `Sessions` table holds
at least four rows — but that hook-level floor is a cheap row count, not a check of which
axes actually cleared their own floor. Before doing anything else, read `pilot.md`'s
`## Index` block. If any of `direction`, `verification` or `contradiction` — the three
gating axes, per `rubric.md`'s profile table — still reads "not enough data yet" (fewer
than 4 assessable sessions in that axis's own rolling window), say so plainly: there is not
enough evidence yet to argue from on at least one of the axes this conversation needs, and
stop here. Do not run the four movements below on that thin a foundation. `rubric.md` is
explicit about why: naming anything off two or three sessions "is the fastest way to make
the whole number look like guesswork," and that reasoning applies to opening this
conversation at all, not only to naming a profile inside it.

## Before the four movements: check for a manoeuvre already in force

Read `pilot.md`'s `Manoeuvres` block before doing anything else.

- **No `- live:` line present** — proceed straight to the four movements below.
- **A `- live:` line present, past its `until` date** — its run is over. Movement 1 below
  states the verdict (did the constraint hold, evidenced from the `Sessions` rows and
  `pilot-evidence.md` quotes since it started), and before movement 4 that exact line is
  rewritten in place: change its `- live:` prefix to `- settled:` and append a short verdict
  (`| verdict: held` / `| verdict: dropped after two sessions` / similar). Only then does
  movement 4 negotiate a new one.
- **A `- live:` line present, not yet expired** — never add a second one (see House rules).
  Run movements 1–3 if there is anything worth saying; skip movement 4, and say the current
  manoeuvre is still running until its date instead of proposing a new one. A check-in with
  nothing worth saying is still a completed brief, not a no-op: stamp it exactly as "A
  completed brief resets the streak" describes below (`brief=<epoch seconds>` and
  `declined=0`) rather than leaving it due again at the next session start. A brief that
  keeps coming back because it had nothing to report is the mildest form of the nagging
  these house rules exist to forbid.

Retiring a manoeuvre always means **editing that line in place**, never leaving it and
appending a new `- live:` line below it — see why in the format section below.

## The four movements, in order

The order is the design. Do not reorder it, skip a movement, or collapse two into one.

### 1. Facts, no adjectives

State what the numbers say, nothing more. Numbers come from `pilot.md`'s `Sessions` and
`Index` blocks; quotes come from `pilot-evidence.md`. No adjectives, no framing, no "you
seem to" — a count is either true or it needs correcting, and correcting it is the dev's
job, not a reason to hedge it in advance.

> "9 sessions, ~2,400 lines written by me against ~180 by you, no objection in 6 of them,
> you named something from a diff twice."

### 2. A question, not a diagnosis

Ask about the pattern the facts just showed. Do not explain it, guess at it, or soften it
into a suggestion — a deadline, fatigue, an unfamiliar codebase, and plain reluctance would
each call for a completely different manoeuvre, and nothing in the transcript tells Pilot
which one this was. Only the dev knows, and only if asked.

> "Tuesday you sent 6 prompts in 4 minutes — what was going on?"

Wait for the answer before moving to movement 3. The mechanism you cite there should fit
what the dev just said, not just the axis that happens to be weakest.

### 3. Exactly one mechanism, once

Pick the single entry from `references/mechanisms.md` whose observable matches this week's
weakest axis (or the dev's own answer in movement 2, if it points somewhere sharper). State
its "what it does" in about two sentences, cite the source inline, and stop. Never two
mechanisms in the same brief, never a paragraph of context around it, and never repeat one
already cited in a recent brief unless the dev asks why again. This is a fact offered for
the dev to weigh, not a verdict on their character.

### 4. One manoeuvre, negotiated, with an expiry

Propose one manoeuvre matching the weakest axis (table below). "Negotiated" means the dev
gets a real say in the constraint's shape and the expiry's length — offer a starting point,
not a mandate, and adjust it to what they actually agree to. Once agreed, write it to
`pilot.md`'s `Manoeuvres` block in the exact line shape the nudge hook parses (next
section), then stamp the brief as done (see House rules).

## The four manoeuvres, one per axis

| Axis | Manoeuvre |
|------|-----------|
| `direction` | state the intended result plus one constraint before prompting |
| `verification` | write down what you expect the diff to contain before reading it |
| `contradiction` | one argued objection per session; the next brief reports on it |
| `writing` | an AI-free block, a tightened `coach delegate` scope, or a `fill` exercise on what Claude just wrote |

`pilot-nudge.sh` only acts on `direction`: it reminds the dev to name the result and the
constraint when a prompt is vague. The other three axes have no `UserPromptSubmit`
mechanism — `verification` and `contradiction` are self-checks the dev carries into the
session, and `writing` rides the existing `coach-gate.sh` machinery instead of anything new.

## The manoeuvre line format — state this exactly, it is parsed

`hooks/pilot-nudge.sh` reads the **first** line in `pilot.md` — anywhere in the file, not
scoped to the `Manoeuvres` block, since the hook does a plain line scan with no notion of
sections — that starts with `- live: `, and parses it by splitting on pipes:

```
- live: direction | name the result you want and one constraint | until 2026-09-24
```

- The **axis** is everything before the *first* pipe (`direction`).
- The **expiry** is the *last* pipe-delimited field, and must read exactly `until
  YYYY-MM-DD` (`until 2026-09-24`).
- The **constraint** is everything in between, rejoined with `" | "` if it had more than
  one segment. This means **the constraint text may itself contain a pipe character** —
  deliberately: it is a sentence in natural language, negotiated in movement 4, and
  forbidding one punctuation character in generated prose is a rule that gets broken the
  first time a constraint reads naturally with one in it. For example, this line —

  ```
  - live: verification | name what you expect the diff to touch (e.g. "client.py | no new files") before opening it | until 2026-09-24
  ```

  — parses to axis `verification`, expiry `2026-09-24`, and a constraint that still
  contains its own `|` untouched, because the parser only ever treats the *first* pipe and
  the *last* pipe as structural.

The other two axes follow the same shape:

```
- live: contradiction | raise one argued objection this session, even if I turn out to be right | until 2026-09-24
- live: writing | write the function signatures yourself before asking me to fill the bodies | until 2026-09-24
```

**A manoeuvre whose last field is not `until <YYYY-MM-DD>` is malformed, and a malformed
manoeuvre is not live.** This is not a soft failure or an "assume it never expires" case —
it is the opposite. The nudge hook fails toward silence: no expiry field, an expiry that
does not start with `until `, or a date it cannot parse as `YYYY-MM-DD` all mean the nudge
says nothing, on every prompt, indefinitely, while `pilot.md` still shows the line as if it
were live to anyone reading the dashboard by eye. So:

- Always write the expiry as exactly `until YYYY-MM-DD` — no other wording, no relative
  date like "in two weeks", nothing after the date on that field.
- Always keep the whole manoeuvre on **one line**. A line break turns the constraint into
  two lines, and the parser only ever reads the first line starting with `- live: `.
- When a manoeuvre settles, **edit that exact line in place** (`- live:` becomes
  `- settled:`) rather than adding a new `- live:` line underneath it. The parser takes the
  first `^- live: ` match in the whole file, top to bottom — a stale line left in place
  above a fresh one would shadow the new manoeuvre forever, and the dashboard would still
  read as if the new one were in force.

## House rules

These are not decoration. They are what keeps a tool built to catch nagging from nagging.

- **Never two live manoeuvres at once.** One counter-manoeuvre, negotiated with an expiry,
  or none — see "Before the four movements" above for what running one already in force
  means for this brief.
- **No moralising.** State the facts, ask the question, cite the one mechanism, negotiate
  the manoeuvre. Nothing about what the dev "should" be doing, no tone of disappointment,
  no reading a low score as a character flaw. The facts and the mechanism carry the whole
  argument; anything added on top is nagging with extra steps.
- **A deferral is not a failure.** "Not now" (or any equivalent) ends the brief right
  there, with nothing written to `pilot.md`'s `Manoeuvres` block. Append a new
  `declined=<n+1>` line to `pilot-stamps` (read the current value first, same as
  `pilot-brief.sh` does — the stamps file is read by taking the last line for a key, so an
  append is enough) and move on to whatever the dev actually asked for. Do **not** update
  the `brief=` stamp on a deferral — the brief stays due and will be offered again at the
  very next session start, not after a full cadence, since deferring is not the same as
  having had the conversation.
- **A completed brief resets the streak.** When the four movements finish and a manoeuvre
  is written (or the brief runs to its natural end with nothing new to propose, per "Before
  the four movements"), append `brief=<epoch seconds>` **and** `declined=0` to
  `pilot-stamps`. A dev who has the conversation is not on a decline streak, whatever their
  streak was before.
- **Two deferrals in a row, and the brief stops offering itself.** When a deferral would
  bring `declined` to 2, say so once, in that same conversation, before moving on: something
  like "I won't bring the weekly brief up again on its own — ask for `learner pilot brief`
  whenever you want it." Then write `declined=2`. From here, `pilot-brief.sh`'s own
  `SessionStart` check (`declined < 2`) keeps the brief from being offered again
  automatically — it does not re-announce this silence at every future session start, which
  would be exactly the nagging this rule exists to forbid. The dev asking for `pilot brief`
  (or `learner pilot brief`) explicitly runs this protocol off-cadence regardless of
  `declined`, and a brief that actually completes resets the streak per the rule above.
- **Language: mirror the dev**, as `SKILL.md` states for the whole skill. Write every
  movement in the language the dev is using in this conversation. The axis names
  (`direction`, `verification`, `contradiction`, `writing`) and the manoeuvre line's literal
  keywords (`live`, `settled`, `until`) stay in English regardless — they are parsed, not
  read.
