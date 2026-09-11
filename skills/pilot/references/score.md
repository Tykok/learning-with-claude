# Score — draining the queue into a number

This is the protocol for turning `$CFG/learner/pilot-queue` into rows in `pilot.md` and
quotes in `pilot-evidence.md`. It is read by the subagent `hooks/pilot-brief.sh` dispatches
when the queue is non-empty and stale — never read to decide whether to dispatch that
subagent in the first place; that decision is the hook's, not yours.

## 0. You must be a subagent, with nothing else in context

**Stop and say so if this file was reached with the very conversation being scored still in
context.** The `contradiction` axis asks whether the dev ever objected to *you*; judging
that from inside the conversation it happened in makes you judge and party to the same
exchange. If you are the main session — not a fresh subagent dispatched with no other
context — do not proceed. Tell the dev this pass needs to run as a subagent and stop here.
A subagent reading this file, freshly dispatched with no other context loaded, is correctly
positioned and should continue.

## 1. Read the queue

Read every line of `$CFG/learner/pilot-queue`. Each line is one finished session,
`key=value` pairs, ending `dev_lines=<int|-> est=<0|1|-> coach=<0|1> jsonl=<path>`. An empty
or missing queue means nothing to do — report that and stop.

For each line, read the transcript at its `jsonl=` path in full. That transcript, plus the
counters already on the queue line (`prompts`, `pw_med`, `pw_min`, `burst`, `tools`,
`cl_writes`, `cl_lines`, `dev_lines`, `est`, `coach`), is everything this pass judges from.
**Never recompute a counter** — `cl_lines`, `dev_lines` and the rest are deterministic
output of `hooks/pilot-record.sh` and are trusted as given, even if a hand count from the
transcript would differ slightly; recomputing them here is exactly the kind of judgement
call that must stay reproducible in one place, not two.

If a line's `jsonl` path does not exist or cannot be read, score `direction`, `verification`
and `contradiction` on that session `-` and note "transcript unavailable" in the Sessions
row rather than skipping the line silently — the row must still exist and still count
toward "how many sessions were scored." `writing` is not part of this fallback: §3 scores
it from the queue line's own counters, which are present and trustworthy whether or not the
transcript can be read, so score it normally even on a row otherwise marked "transcript
unavailable."

## 2. Score the three judged axes against `rubric.md`

For `direction`, `verification` and `contradiction`, read `references/rubric.md` and match
the transcript against its anchors, per session. Each is a fresh judgement — a session's
`direction` score does not roll forward from a previous session's target.

**Every numeric score (0–4) must carry one supporting quote pulled verbatim from the
transcript, at most 200 characters.** Trim quotes to the load-bearing fragment rather than
picking whichever line is longest. If, having read the whole transcript, you cannot produce
a quote that supports a particular axis's score, that axis is `-` for that session — not
your best guess at a number, and not `0`. This is not optional and it is not a formatting
nicety: a score with no quote behind it cannot be checked by the dev it is about, and an
unchecked number is not a measurement. When in doubt between two anchors, prefer the lower
one only if it is the one you can actually quote — do not round up to a score the transcript
does not evidence.

A session with a single prompt and no output to react to yet will legitimately score `-` on
`verification` and `contradiction`, and `-` on `direction` too if that one prompt states no
target. That is the rubric working as designed, not a gap in your reading.

## 3. Score `writing` from the counters, not the text

Apply `rubric.md`'s `writing` rows to `dev_lines` and `cl_lines` from the queue line — no
quote is required for this axis, since it is arithmetic on numbers already computed
deterministically, not a judgement call. `dev_lines=-` (queue `est=-`) makes this axis `-`
regardless of `cl_lines`.

## 4. Append one row per session to `pilot.md`'s `Sessions` block

`pilot.md` holds three blocks, in this order: `## Sessions`, `## Index`, `## Manoeuvres`. If
`pilot.md` does not exist yet, create it with all three headers — leave `## Index` stating
every axis needs more data, and `## Manoeuvres` empty (that block is only ever written by
`references/brief.md`; never invent a manoeuvre from here).

The `Sessions` table is `| Date | Repo | Dir | Ver | Con | Wri | Note |`, one row per queued
session, oldest first, appended after the existing rows (never re-sorted, never rewritten):

- `Date`, `Repo` — copied from the queue line (`repo=-` renders as `-`).
- `Dir`, `Ver`, `Con`, `Wri` — the score for that axis: `0`–`4`, or `-` when not assessable.
  Append `~` to `Wri` (e.g. `3~`) when the queue line has `est=1`; no marker when `est=0`;
  plain `-` when `dev_lines=-`. Never mark `Dir`, `Ver` or `Con` with `~` — those are never
  estimates, they are `-` or a quoted number.
- `Note` — one short remark if there is something worth flagging (`transcript unavailable`,
  `single prompt`, `no repo`), or `-` when there is nothing to add. Keep it under about 40
  characters; the quotes belong in the evidence file, not here.

## 5. Append the quotes to `pilot-evidence.md`, grouped by date

Under a `## <date>` heading — the session's date, from the queue line, the same date
already copied into that session's `Sessions` row in §4 (reuse the heading if an earlier
session scored in this same run already produced one for that date) — list each numeric
score's quote as one line:
`<repo> — <axis>: "<quote>"`. Sessions or axes scored `-` contribute no line here — there is
no quote to keep. This file is what answers `pilot why <date>` and what `pilot forget`
purges; write nothing here you would not want surfaced back to the dev verbatim, since that
is exactly what happens.

## 6. Recompute the `Index` block

For each of `direction`, `verification`, `contradiction`, `writing`: walk the (now-updated)
`Sessions` table from the most recent row backward and collect that axis's last 10
**assessable** scores — a row scored `-` on that axis is skipped entirely and does not
consume one of the 10 slots, per `rubric.md`'s arithmetic (a window of 10 assessable scores,
not 10 rows). Fewer than 4 assessable scores found this way renders the axis as `—` with
"not enough data yet". Otherwise: mean × 25, rounded to the nearest integer.

Then the profile, only once `direction`, `verification` and `contradiction` each clear the
4-assessable floor: apply `rubric.md`'s profile table top to bottom and write the first
match. Below that floor, write "profile: not enough data yet" instead of a name — never a
placeholder profile, never the nearest-looking one.

Rewrite the whole `## Index` block (it is a computed summary, not an append-only log, unlike
`Sessions` and the evidence file).

## 7. Stamp, then truncate — in that order, not the reverse

Once `pilot.md` and `pilot-evidence.md` are written and saved: write `score=<epoch seconds>`
into `$CFG/learner/pilot-stamps` (append or replace **only** the existing `score=` line —
that file also holds `brief=` and `declined=` lines that a full rewrite of it would silently
reset; resetting `declined` mid-decline-streak reopens the brief for a dev who already said
no twice, which is exactly the nagging the house rules in `references/brief.md` forbid),
**then** truncate `pilot-queue` to empty, and truncate `$CFG/learner/pilot-devlines` to empty
alongside it — every line in it belongs to a session that has just been drained into
`pilot.md`, and nothing prunes that file otherwise. If anything above fails partway,
`pilot-queue` must still hold every line that did not make it into `pilot.md` — the next
session start is what retries a failed drain, and it can only do that if the queue was never
truncated ahead of a completed write. Never truncate first "to be safe"; that is the one
order that loses data silently.

## 8. Report back in one line

Tell the dev how many sessions were scored and which axis's index moved the most since the
last drain (name it "not enough data yet" rather than a number if that axis is still below
its floor). Nothing more — the full detail lives in `pilot.md` and is one `learner pilot`
away.
