---
name: pilot
description: Delegation-habit tracking, read from the transcript itself. Invoke as "pilot" with a subcommand — bare "pilot" (dashboard: index per axis, profile, active manoeuvre), "pilot on"/"pilot off" (opt in/out), "pilot brief" (run the weekly brief now), "pilot score" (drain the scoring queue now), "pilot why <date>" (show the quotes behind a row), "pilot forget [--all|--before <date>]" (purge stored quotes). Also reachable through "learner pilot …". Trigger on "pilot", "learner pilot", "pilot on", "pilot off", "pilot brief", "pilot score", "pilot why", "pilot forget", "my delegation score", "am I still driving", "cognitive debt", "mon score de délégation", "est-ce que je délègue trop", "dette cognitive".
allowed-tools: Read, Write, Edit, Grep, Bash, Task
---

# Pilot

Pilot measures how much of the thinking on a task you handed to Claude versus did
yourself, read from the sessions you already had rather than a questionnaire. It scores
four behavioural axes — did you set the direction, did you check the output, did you ever
push back, did you write any of the code — and rolls them into a profile you can watch
move over weeks. It is not a measure of intelligence or of cognitive health, and it never
asks you a question to produce a score: everything it reports comes from what you and
Claude already did, never from a prompt written to test you.

## Privacy — read before turning it on

Pilot reads every prompt you have typed, in every repo, to do this. That is why it is
**opt-in and off by default** (`pilotEnabled: false`): reading everything you write is not
something a tool should do without being asked. Turning it on with `pilot on` prints this
paragraph once, in full, before the switch flips — never silently. `disabledPaths` is
honoured exactly as it is for the quiz: a repo listed there is never read for Pilot either.
Everything stays on this machine — the transcript is referenced by path, never copied, and
the judgement that turns a session into scores runs in a local subagent, nothing leaves
that Claude Code itself was not already sending. The quotes kept as evidence are capped at
200 characters each and fully purgeable at any time with `pilot forget`.

## Dispatch

`pilot <subcommand> [args]` — the subcommand is the first token of `$ARGUMENTS`. Reachable
directly, or via `learner pilot …` from the `learner` skill.

| Subcommand | Does | Read |
|------------|------|------|
| `pilot` *(bare)* | Render the dashboard: index per axis, profile, active manoeuvre | `references/dashboard.md` |
| `pilot on` | Print the privacy paragraph above once, then set `pilotEnabled: true` | this file, § Privacy |
| `pilot off` | Set `pilotEnabled: false`; stop reading anything | this file, § Privacy |
| `pilot brief` | Run the weekly brief now, off-cadence | `references/brief.md` |
| `pilot score` | Drain the scoring queue now, off-cadence | `references/score.md` |
| `pilot why <date>` | Show the quotes behind that row's scores | `references/dashboard.md` |
| `pilot forget [--all\|--before <date>]` | Purge stored quotes from `pilot-evidence.md` | `references/dashboard.md` |

`pilot` with no further token always renders the dashboard — it is read-only, never a
config prompt.

## The four axes

Full anchors, 0–4 per session, live in `references/rubric.md` — read it before scoring or
explaining a score. One line each here:

- **direction** — did you set the target and the constraints, or ask for "something that works"?
- **verification** — did you read what came back, naming something concrete from it?
- **contradiction** — did you ever object, correct, or ask why?
- **writing** — did you write any of the code yourself?

## House rules

- Never render a profile while `direction`, `verification` or `contradiction` has fewer
  than four assessable sessions — show the axes you do have and say the profile needs
  more data instead.
- Never run two live manoeuvres at once. One counter-manoeuvre, negotiated with an expiry,
  or none.
- A `-` (not assessable) is never a zero. It is excluded from every average, not floored.
- **Language: mirror the dev.** Write the dashboard, the brief and every line of feedback
  in the language the dev is using in this conversation, exactly as `learner` does. The
  axis identifiers themselves (`direction`, `verification`, `contradiction`, `writing`)
  stay in English regardless.
