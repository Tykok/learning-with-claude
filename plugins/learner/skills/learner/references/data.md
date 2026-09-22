# Data files

Shared by all three quiz modes (`references/hook-quiz.md`, the `quiz` skill,
the `improve` skill) and by coach mode (`../../coach/references/coach.md`). Read
this once per mode invocation; do not restate these rules elsewhere.

## Paths

```bash
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$CFG/learner"
```

- `$CFG/learner/memory.md` — working memory.
- `$CFG/learner/recap.md` — dashboard.
- `$CFG/learner/libs.md` — the libraries the coach has already covered.
- `$CFG/learner/events.jsonl` — the event log the Learner IDE extensions read. Never read it
  to pick a question, and never write it by hand: only `learner-event.sh` does.

## `events.jsonl` — what the IDE sees

One line per question, so an IDE can show a badge for the open question, highlight a
`fill` hole and list the history. Every write goes through the shipped script:

```bash
HOOKS="${CLAUDE_PLUGIN_ROOT:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/hooks"
[ -f "$HOOKS/learner-event.sh" ] || HOOKS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks"
```

**When the question goes out** — in the same turn, right after putting it to the dev:

```bash
QID=$(sh "$HOOKS"/learner-event.sh asked --style fill --mode granular --level S \
        --domain Code --files "src/foo.ts" --anchor src/foo.ts:42 --prompt "<the question as asked>")
```

- `--style`: `code`, `architecture` or `fill` — what this question actually is, never `auto`.
- `--domain`: the domain you will file the answer under (`Code`, `Architecture`, `Tests`,
  `CI/Build`, `Data & DB`, `Integrations`).
- `--anchor FILE:LINE`: for `fill`, the first `LEARNER-TODO` line
  (`grep -n 'LEARNER-TODO' FILE | head -1`); for another style, the line the question is
  about when there is exactly one; omit it otherwise.
- `--prompt`: the question text only — never the code or a diff.

Remember `QID` until the answer. If the script prints nothing (no `jq`), carry on without it.

Create any of the three if it does not exist yet.

Two values recur below:
- Repo tag: `basename "$(git rev-parse --show-toplevel)"`.
- Today's date: `date +%F`.

## `memory.md` — working memory

The **only** file read to pick a question. One open weak spot per line:

```
- [Domain][repo] concept — seen: YYYY-MM-DD
```

Read it **before** choosing a question and prefer a still-open entry when relevant
(spaced repetition). Add a line when the dev misses or hesitates on something; remove
the line once they demonstrate mastery of it.

## `recap.md` — dashboard

Written to keep the dev informed, but **never read** to pick a question — that would
mix the zoomed-out view back into question selection.

### `To improve` / `Mastered`

Grouped by domain: `Code`, `Architecture`, `Tests`, `CI/Build`, `Data & DB`,
`Integrations`. Entries are phrased as **broad competency themes** ("Data access and
query performance", "Error and exception handling", "Layering and module
responsibilities"), never the precise concept of a single question. Roll related weak
spots under one theme; aim for a handful of themes per domain, not a growing list.

No repo tag here — this is a deliberate cross-repo view of what the dev should level
up on overall, not a per-repo log. (The repo tag belongs in `memory.md` lines and in
the `Session history` table below.)

### `Session history`

Table:

```
| Date | Repo | Domain | Style | Verdict | Note | Theme |
```

Verdicts: `✅ ok`, `⚠️ revisit`, `⏭️ skip`. This is the only place per-question detail
lives in `recap.md`.

`Theme` is the exact theme text the point was filed under in `To improve` or `Mastered` —
the same choice step 2 of § After every answer already makes, written down so it can be
counted later. Always fill it. A row that ends at `Note`, with no `Theme` cell, was
written before the column existed: read it as untagged and leave it alone.

`Style` names which mode produced the row: `code`/`architecture`/`fill` from a quiz question,
`improve` from an improve session, `coach` from a coach challenge or structure question,
`coach-lib` from a coach library question, `coach-ack` from a coach confirmation.

## `libs.md` — the libraries already covered

Written by coach mode only. Read **before** choosing a library question, so an angle is not
served twice; written after the dev's answer.

```markdown
# Libraries covered

| Library | Seen | Angle covered | Verdict |
|---------|------|---------------|---------|
| argon2 | 2026-09-18 | cost parameters (t, m) | ⚠️ revisit |
| zod | 2026-09-18 | refine vs superRefine | ✅ ok |
```

One row per (library, angle) pair, not per library: coming back to `argon2` three weeks later
from the salt-storage angle **adds** a row. That is what makes spaced repetition on libraries
possible at all — a single row per library would only ever say "already done".

## What a coach review writes

- **An answered question** — a `Session history` row as usual, with `Style` `coach` for the
  challenge and the structure question, `coach-lib` for the library one, and the verdict `✅ ok`
  / `⚠️ revisit` / `⏭️ skip`. A missed or hesitant answer also opens a `memory.md` line, as
  everywhere else.
- **A library question** — additionally, one `libs.md` row.
- **A finding** — rolled into an existing broad theme of `recap.md` § `To improve`, under its
  domain. "A missing exception at a critical point" belongs under `Code › Error and exception
  handling`; it does not become a line of its own. Create a theme only when none fits.

  A finding **never writes to `memory.md`.** That file is the only one read to pick a question,
  and a defect the dev was never questioned on has no place deciding what they are asked next —
  it would produce a question about something they have never been given a chance on.
- **A confirmation** — a `Session history` row with `Style` `coach-ack`, verdict `✅ ok`, and a
  `Note` naming the reflex ("business logic kept out of the controller"). The same reflex
  confirmed **twice, on two different diffs** — two `coach-ack` rows carrying the same theme —
  promotes that theme into `recap.md` § `Mastered`.

## After every answer

Update **all three**:

1. `memory.md` — add or remove the precise weak spot.
2. `recap.md` — append a `Session history` row, naming the theme in its `Theme` cell, and
   attach the point to that broad theme under `To improve` or `Mastered` (create the
   theme only if it does not already exist).
3. `events.jsonl` — close the question with the same verdict and theme as the recap row:

   ```bash
   sh "$HOOKS"/learner-event.sh answered --id "$QID" --verdict ok --domain Code \
     --theme "Error and exception handling" --note "<the recap row's Note>"
   sh "$HOOKS"/learner-event.sh skipped --id "$QID"      # on `skip`
   ```

   `--verdict` is `ok` for `✅ ok` and `revisit` for `⚠️ revisit`. A question left open when
   the session ends is closed by the `SessionEnd` hook; nothing to do for it.

Keep all three updates concise.
