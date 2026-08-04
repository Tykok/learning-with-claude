# Data files

Shared by all three quiz modes (`references/hook-quiz.md`, `references/quiz.md`,
`references/improve.md`). Read this once per mode invocation; do not restate these
rules elsewhere.

## Paths

```bash
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$CFG/learner"
```

- `$CFG/learner/memory.md` — working memory.
- `$CFG/learner/recap.md` — dashboard.

Create either file if it does not exist yet.

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

## After every answer

Update **both** files:

1. `memory.md` — add or remove the precise weak spot.
2. `recap.md` — append a `Session history` row, naming the theme in its `Theme` cell, and
   attach the point to that broad theme under `To improve` or `Mastered` (create the
   theme only if it does not already exist).

Keep both updates concise.
