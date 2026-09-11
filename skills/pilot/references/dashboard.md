# Dashboard — rendering `pilot`, `pilot why`, `pilot forget`, and the status line

This file says how the numbers `references/rubric.md` and `references/score.md` already
computed get shown to the dev — never how they are computed. Read `rubric.md` first: the
axis anchors, the `-`/estimate semantics, the rolling-mean arithmetic and the profile table
all live there, and this file renders them rather than re-deriving them. Read `brief.md`
for the `Manoeuvres` block's line format (`- live: … | … | until YYYY-MM-DD` /
`- settled: … | verdict: …`), which this file reads but never writes.

Two files hold everything rendered here:

- **`pilot.md`** — `## Sessions` (`| Date | Repo | Dir | Ver | Con | Wri | Note |`, appended
  oldest-first, so the last rows in the file are the most recent sessions), `## Index`
  (one `- <axis>: <value>` line per axis plus `- profile: <name|not enough data yet>`),
  `## Manoeuvres` (the live/settled lines `brief.md` owns).
- **`pilot-evidence.md`** — the quotes behind each numeric score, grouped under `## <date>`
  headings, one line per scored axis: `<repo> — <axis>: "<quote>"`.

Every subcommand below is read-only against these two files except `pilot on`/`pilot off`
(which write `pilotEnabled`) and `pilot forget` (which writes `pilot-evidence.md` alone).
None of them ever re-scores a session — that only ever happens in `score.md`, once, in a
subagent.

## `pilot` (bare) — the dashboard

Render, in this order, and stop — no other section, no elaboration:

1. **`Index`.** One line per axis (`direction`, `verification`, `contradiction`, `writing`),
   read straight from `pilot.md`'s `## Index` block. Each axis's own floor decides whether it
   renders as a number: an axis with fewer than four assessable sessions in its own rolling
   window renders as `—`, with "not enough data yet" beside it, **regardless of whether the
   other three axes have cleared their own floor** — the floors are independent per
   `rubric.md`, and a thin `writing` axis must never hold back a well-populated `direction`
   axis, or vice versa. Never draw a trend, an arrow, or a "you're improving" line from an
   axis under its own floor: four rows is a floor for naming a number at all, not a target
   past which a direction becomes visible.
2. **`Profile`.** Only once `direction`, `verification` and `contradiction` have each
   individually cleared their four-session floor (`writing` never gates this — it is not in
   `rubric.md`'s profile table and is reported only as its own index line above). Apply
   `rubric.md`'s profile table exactly, top to bottom, first match; this file does not
   restate that table's thresholds, so a change to the table needs no matching edit here.
   Below the floor, render `- profile: not enough data yet` exactly as `pilot.md` already
   holds it, and stop there — **never render the nearest-looking profile as a placeholder**,
   and never a name at all until every one of the three gating axes clears its floor
   independently.

   **Whatever profile is rendered, follow the name with one short plain-language gloss of
   what it means** — a sentence, not a value judgment, e.g. `Cargo` — direction and pushback
   are both low this window; `Pilot` — direction, verification and pushback all clear the
   bar. `rubric.md`'s profile names are terse labels by design, and `Cargo` in particular is
   the one inanimate word in an otherwise role-shaped table, landing bare on a dev with
   nothing beside it to say it names a pattern and not a verdict on them — README.md's own
   line that "Pilot measures a habit, not you" only holds if every rendered profile carries
   that context, not just the one below with a remedy attached. Every profile gets this
   gloss; only `Backseat` additionally gets the remedy line that follows.

   **When the rendered profile is `Backseat`, add one more line naming its remedy.**
   `rubric.md` calls this the most actionable row in the table — a dev who argues with the
   output (`contradiction` ≥ 50) without having read it closely first (`verification` < 50)
   has a narrow, specific fix, not a vague exhortation to pay more attention: point at the
   `verification` manoeuvre (write down what you expect the diff to contain before opening
   it) by name. No other profile gets an appended remedy line here — `Backseat` is singled
   out because its fix is this legible; a generic "here's what to do" under every profile
   would bury the one case where it is actually this concrete. (Every profile still gets the
   plain-language gloss above; it is only the extra remedy line that stays exclusive to
   `Backseat`.)
3. **The live manoeuvre.** Read `pilot.md` for the first line anywhere in the file that
   starts `- live: axis | constraint | until YYYY-MM-DD` — same whole-file scan
   `pilot-nudge.sh` uses, not scoped to the `## Manoeuvres` block, even though that is the
   only place such a line is ever written. Render axis, constraint and the expiry date on
   one line. No `- live:` line, or one past
   its `until` date: render "no active manoeuvre" — an expired line is `brief.md`'s to
   retire (rewritten to `- settled:` with a verdict), never this file's to silently treat as
   current or to edit.
4. **The last five `Sessions` rows.** The five most recently appended rows of the table (the
   bottom of the file, since the table is append-only oldest-first), rendered as they stand:
   `Date`, `Repo`, `Dir`, `Ver`, `Con`, `Wri`, `Note`. Fewer than five existing rows renders
   however many exist; this is a display window, not a floor, and is unrelated to the
   four-session floors above.

### The `~` marker, explained once

A `Wri` cell suffixed `~` (e.g. `3~`) means that session's `dev_lines` was estimated —
`est=1` on the queue line, because coach mode was off and git diff arithmetic stood in for
an exact tally. Say this once, near the `Sessions` rows, rather than annotating every `~`
cell individually. `Dir`, `Ver` and `Con` never carry this marker: they are either a quoted
judgement or `-`, never an estimate.

### `-` is not a low score

A `-` cell means that axis was not assessable for that session — no evidence either way,
most often a single-prompt session with nothing yet to react to or object to. It is excluded
from every mean in the `Index` block, never counted as a 0, and a row of mostly `-` from a
short session is the rubric working correctly, not a bad result. **Never render a `-` in a
way that reads as a low score**: never place it at the bottom of a scale, never pair it with
language like "weak" or "poor", never let it visually stand in for `0` in a table someone
skims at a glance. If a legend is worth one line, it is this one: `-` means "nothing to
measure here", not "measured and found wanting".

## `pilot why <date>`

The accountability feature: it prints the quote behind every score on that date beside the
score itself, so a dev who disagrees with a number can go check the sentence it came from
and argue with it.

For every scored session on `<date>` in `pilot.md`'s `Sessions` table (there may be more
than one, if the dev had several sessions that day — render each separately, labelled by
repo), print each of the four axes as `<axis>: <score> — "<quote>"`, pulling the quote from
that date's `## <date>` section in `pilot-evidence.md` (matched by repo and axis, since a
day with two sessions has two sets of quotes).

- **A score with no quote reads as `-`, and says so plainly rather than being hidden.** If an
  axis is `-` in `pilot.md`, print the axis and `-` with a short reason if `score.md` left
  one in the row's `Note` (`single prompt`, `transcript unavailable`, …), never silently
  omit the row because there is nothing to quote. The absence of evidence is itself
  information the dev is owed — a row that vanishes because it has no quote is a different,
  worse promise than a row that says outright it could not be assessed.
- **`writing` is the one axis with no quote by design, not by omission.** `rubric.md` scores
  it from `dev_lines` against `cl_lines`, arithmetic on numbers already computed
  deterministically, never a judgement call — so it never carries a quote even when it is a
  clean number. Render it as `writing: <score> — computed from dev_lines vs cl_lines, not a
  judged quote`, with `~` appended to `<score>` if estimated (`est=1` on the queue line) and
  nothing appended if exact (`est=0`) — same marker and meaning as the `Sessions` table's
  `Wri` column, never a literal `?` — rather than reporting it the same way as a missing
  quote on `direction`, `verification` or `contradiction`: one is arithmetic that was never
  going to have a quote, the other is a judgement that could not find one, and conflating
  them would make `pilot why` lie about why a row has no quote.
- **A date with no scored session at all**: say plainly that nothing was recorded for that
  date, rather than guessing at the nearest one.

## `pilot forget [--all|--before <date>]`

Deletes from pilot-evidence.md only. `pilot.md`'s `Sessions` rows and `Index` values
survive untouched: the dev asked to drop the quotes, not to rewrite their history, and a
score that quietly loses its backing evidence while still standing in the index is not the
same request as one that vanishes.

- **No flag at all is not a silent `--all`.** A purge needs an explicit scope; ask which one
  (`--all`, or `--before <date>`) rather than assuming the broadest one because none was
  given.
- **Confirm before deleting.** Before touching the file, state what the flag actually
  selects — how many quotes, across how many dates (and, for `--before`, the date range) —
  and wait for the dev to say go ahead. A destructive purge that runs on the first ask,
  before the dev has seen what it will take, is the wrong shape for this command even though
  nothing it deletes is otherwise unrecoverable data.
- **Delete, then say what changed.** Remove the matched date sections (or the matched quote
  lines within a section, if `--before` splits one) from `pilot-evidence.md`, and report how
  many quotes were removed. Then say explicitly: the scores in `pilot.md` for those dates are
  unchanged, and **those scores can no longer be justified with `pilot why`** — the number
  still stands, but the sentence that backed it is gone.

## The `learner status` line

`learner status` gains exactly one Pilot line when `pilotEnabled` is true: profile (or "not
enough data yet" per the same floor as the dashboard), the weakest assessable axis and its
value, and the live manoeuvre if one is running (axis and expiry only — the full constraint
text belongs to `pilot`, not to a one-line summary). If no axis has cleared its own floor
yet, the line has nothing to name as weakest and says only that Pilot needs more sessions.

**When `pilotEnabled` is false, this line does not appear, and nothing else about Pilot
appears in its place.** Not "Pilot is off", not a mention that it exists, not an invitation
to turn it on. `learner status` is a surface the dev asked for by asking for their status; a
feature that reads every prompt they type does not get to use that surface to advertise
itself to a dev who has not opted in. Silent means silent — say nothing at all.

## `pilot on` / `pilot off`

**`pilot on`** prints the privacy paragraph from `skills/pilot/SKILL.md`'s `## Privacy —
read before turning it on` section, in full, once — before flipping anything. Only after
that is `pilotEnabled` set to `true` **in the global config file**,
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner.json` — never in the per-repo
`<repo>/.claude/learner.local.json`. Pilot's design is a machine-wide switch, not a
per-repository one; writing it to the repo-local override would silently narrow it to
whichever repo happened to be open when the dev flipped it, while they believe it is on
everywhere. Never flip the key first and explain afterward: the paragraph is what makes
turning it on informed consent rather than a default the dev stumbled into.

**`pilot off`** sets `pilotEnabled` back to `false` in that same global config file,
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner.json` — never the per-repo
`<repo>/.claude/learner.local.json` — and says two things, plainly: the data already
collected is kept, not deleted, and it can be purged with `pilot forget --all` if the dev
wants it gone. Turning Pilot off stops it reading new sessions; it does not, on its own,
touch anything already written to `pilot.md` or `pilot-evidence.md`.
