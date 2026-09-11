# Rubric — the four axes, 0–4, and the arithmetic

Read this before scoring any session (`references/score.md`) and before answering
`pilot why <date>`. The anchors exist so two runs over the same transcript land on the
same number: where a fact can be checked (a count, a named thing, a changed line), the
anchor names the fact, never a feeling like "several" or "some" for the scorer to guess at.

Every numeric score below is written with **one supporting quote, at most 200 characters,
pulled from the transcript**. If you cannot produce that quote, the score is `-`, not `0`.
This is not a fallback for a lazy pass — it is the one rule that keeps this index from being
astrology: a number with no quote behind it is not a measurement, and is recorded as missing
rather than invented. `-` is never a zero: it is excluded from every mean below, never
floored to it. A session with one prompt scores `-` on most axes, and that is the correct
answer, not a failure to find evidence.

## direction — does the dev set the target and the constraints?

0 — no target given; "make it work", "do the thing", or a pasted error with no ask
1 — a target, no constraint: what to build, nothing about how or what to avoid
2 — a target and at least one constraint (an approach ruled out, a library refused, a shape required, a file named)
3 — target, constraints, and the acceptance condition ("done when the retry stops on a 4xx")
4 — all of 3, plus the dev narrowed the task before delegating it (split it into steps, or handed over one named slice of a larger job)
- — not assessable (no prompt in the session states a target at all — e.g. a single-prompt session, or a session that opens mid-task with no target visible in it)

## verification — does the dev read what came out?

0 — no reference to any content of any output anywhere in the session
1 — a general reaction only, with nothing named from the output ("looks good", "hmm", "ok next")
2 — exactly one concrete thing named from the output: a function, a file, a line, a variable, a branch of the logic
3 — at least two concrete things named from the output, and at least one reference names two or more files or functions in the same causal chain (a caller and what it calls, a definition and where it is used)
4 — the dev names something the output got wrong or left out, and the transcript shows they found it by reading the output, not by Claude volunteering it first
- — not assessable (no output for the dev to react to, or no reaction of any kind survives the strip described in `hooks/pilot-record.sh` §3.1 — e.g. a single-prompt session)

## contradiction — does the dev object, correct, ask why?

0 — no objection anywhere; every output accepted as-is
1 — exactly one doubt voiced with no argument behind it ("hmm, weird", "are you sure?" with no follow-up reason)
2 — exactly one argued objection: a doubt plus a stated reason ("that's wrong because X")
3 — at least two argued objections, and at least one of them changed the solution (Claude's next message reflects the correction)
4 — at least two argued objections, and at least one is conceded: Claude's own later message accepts the correction rather than defending or ignoring it
- — not assessable (nothing in the session gives the dev an opening to object — e.g. a single-prompt session with no output to react to yet)

## writing — does the dev write code themselves?

Scored from `dev_lines` against `cl_lines` on the queue line (`hooks/pilot-record.sh`), never
from the transcript text — this is the one axis with no quote requirement, because it is
already a fact rather than a judgement. Apply the rows top to bottom; stop at the first
match, so no session satisfies two rows at once.

- — dev_lines is `-` (est=`-`: no repo existed to measure against for this session)
- — dev_lines is 0 and cl_lines is 0 (nothing was written by either side this session)
0 — dev_lines is 0 and cl_lines is above 50
4 — dev_lines exceeds cl_lines (dev_lines / cl_lines > 1.00), which also covers cl_lines being 0 while dev_lines is above 0 — all the writing was the dev's, nothing of Claude's to compare it to
3 — dev_lines is between 40% and 100% of cl_lines, inclusive of both ends
2 — dev_lines is at least 10% and under 40% of cl_lines
1 — dev_lines is under 10% of cl_lines (this also covers dev_lines = 0 with cl_lines at or below 50, which row 0 does not claim)

Mark the row `~` in `pilot.md`'s `Sessions` block whenever the queue line carries `est=1` —
the number is real but estimated, never presented as exact. `est=0` renders with no marker.

## The arithmetic — so two runs agree

**Index per axis** = mean of the last 10 **assessable** session scores for that axis,
× 25, rounded to the nearest integer (a tie at exactly .5 rounds up). `-` rows are skipped
when building that list of 10 — they are not part of it at all, and are never counted as 0.
Each axis is windowed independently: a session assessable on `direction` but `-` on
`contradiction` contributes to one rolling mean and not the other.

**Fewer than 4 assessable sessions on an axis** renders that axis as `—` in `pilot.md`,
with "not enough data yet" — never as a number. Four is a floor, not a target: it exists
because a mean of one or two sessions swings on a single session and would read as far more
settled than it is.

**Profile** — never rendered until `direction`, `verification` and `contradiction` **each**
have at least 4 assessable sessions (the same floor as their index, checked on all three
independently). Until then, `pilot.md` shows whatever axes it has and states that the
profile needs more sessions — naming a profile off two or three sessions is the fastest way
to make the whole number look like guesswork. Once all three floors are met, apply these
rows top to bottom against the three indices; the first that matches is the profile:

| # | Profile | Rule |
|---|---------|------|
| 1 | `Pilot` | direction ≥ 70 and verification ≥ 70 and contradiction ≥ 70 |
| 2 | `Co-pilot` | verification ≥ 50 and contradiction ≥ 50 |
| 3 | `Observer` | verification ≥ 50 |
| 4 | `Backseat` | contradiction ≥ 50 |
| 5 | `Cargo` | direction < 25 and contradiction < 25 |
| 6 | `Passenger` | everything else |

Row 6 carries **no condition**. That is the property that closes the table rather than an
accident of writing it down casually: rows 1–5 cover every vector where `verification ≥ 50`
or `contradiction ≥ 50` or (`direction < 25` and `contradiction < 25`), and row 6 catches
every vector that reaches it — which, by the time a vector has failed rows 1–4, is
guaranteed to have `verification < 50` and `contradiction < 50` already (that is what
falling through rows 2–4 means), so rows 3 and 4 above can be read as the single conditions
they are written as without silently losing the second half of their old two-condition
form. Do not add a condition to row 6 to make it look more deliberate — a condition there
reopens exactly the gap this shape closes. If a future edit narrows row 5 or splits row 6,
re-derive that every one of the 0–100³ vectors still lands somewhere, rather than trusting
that it still does.

`Backseat` is new and distinct from `Passenger`: it is a dev who argues with the output
(`contradiction ≥ 50`) without reading it closely (`verification < 50`, since row 3 already
claimed everything at or above that). That combination — objecting on instinct or on a
vague sense that something's off, without the concrete naming that `verification` scores —
is the most actionable vector in the whole table, because the fix is narrow and obvious: the
`verification` manoeuvre (write down what you expect before reading the diff), not a general
exhortation to "pay more attention". Folding it into `Passenger` would bury a dev who is
already halfway to driving under a label built for one who is not engaging at all.

`writing` never gates the profile and never appears in the table above: a dev who delegates
every line typed but sets the target, reads the diff and argues with it is still driving.
`writing` is reported on the dashboard as its own index, on its own floor of 4 assessable
sessions, alongside the profile — never folded into it.
