# Hook quiz (Stop hook trigger)

Followed when the Stop hook blocks with a trigger line of the form
`🎓 Learner (level: S, mode: granular, styles: auto, blanks: 2) — files: a.kt b.kt`.
Read `level`, `mode`, `styles`, `blanks` and `files` straight off that line — the
trigger carries only parameters, this file is the protocol.

## `mode: granular`

Ask ONE short question about the listed `files`, at the difficulty matching `level`
in the level table in `SKILL.md`. Never quiz on code you have not read: read the
files first.

## `mode: synthesis`

Ask ONE question about how the session's work fits together — not a detail. Pick
whichever angle is most useful at `level`:

- how the edited pieces connect (data flow, calls across layers);
- which responsibility lives where, and why;
- a 2–3 sentence summary as if explaining the session's work to a colleague.

## Styles

- `code` — what a specific changed function does.
- `architecture` (alias `archi`) — which module/directory/layer the code lives in,
  and why that choice.
- `fill` — see below.
- `auto` — vary the format from one question to the next, picking whichever is most
  relevant to what changed.

When `styles` names a subset (not `auto`), use only those.

## The `fill` protocol

1. Pick ONE short function among the listed `files`.
2. Before cutting anything, memorise the correct version — it is in git.
3. Edit the real file: replace `blanks` key part(s) of the function's body with
   `// LEARNER-TODO: <hint>` comments, keeping the signature and surrounding code
   intact. Cut only that function.
4. Tell the dev the file and function, and ask them to write the missing code
   **directly in the file**.
5. Wait — never write it for them.
6. When they finish, or say `skip`, compare their code with the correct
   implementation and give brief feedback.
7. Restore a correct version of the function and verify it is valid (a focused
   compile/lint/test for the language).

Never end a turn with the file broken or with a leftover `// LEARNER-TODO`: the Stop
hook's guardrail re-blocks the end of any session while a marker survives, precisely
so a crashed exercise can't leave the tree broken. This is not optional.

Prefer another style when the dev cannot edit locally.

## Running the question

Ask ONE question, then wait for the answer. `skip` moves on without insisting. Give
brief feedback (correct / to fix, plus the missing bit) before continuing.

Then apply `references/data.md`.
