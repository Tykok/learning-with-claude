# Export mode

`learner export [notion-page-url]` — push the recap into a Notion database, one row per
competency theme. Read-only over the learning record: this mode never quizzes, never edits
config, and never rewrites `memory.md` or `recap.md`.

Mirror the dev's language in everything you print, as everywhere else in this skill. The
schema below is fixed English on purpose — it is the key the upsert matches on, and it
cannot depend on the language one dev happens to work in.

## 1. Check the connector

This mode needs the Notion MCP tools. If none are reachable, say so in one line — enable
the Notion connector in the claude.ai connector settings, then re-run `learner export` —
and stop. Write nothing, locally or remotely. There is no offline substitute: a
half-finished export the dev then has to finish by hand is worse than a clear no.

## 2. Resolve the target database

```bash
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
cat "$CFG/learner/export.json" 2>/dev/null
```

| State | What to do |
|-------|------------|
| A `notion.databaseId` is recorded | Upsert into it (§6). |
| No `export.json`, a page URL in `$ARGUMENTS` | Create the database in that page (§3), then write `export.json`. |
| No `export.json`, no URL | Stop, and ask for one page URL: `learner export <notion-page-url>`. Never guess a parent page, never search for one. |
| A database is recorded and `$ARGUMENTS` names a different page | Ask before repointing. On yes, create a new database there and overwrite `export.json`; the old database is left untouched. |

`export.json`:

```json
{
  "notion": {
    "databaseId": "…",
    "url": "…",
    "lastExport": "YYYY-MM-DD"
  }
}
```

`lastExport` comes from `date +%F`. After writing, confirm with
`jq -e . "$CFG/learner/export.json" >/dev/null && echo OK`. This file is per-dev state and
is never written inside a repo.

## 3. The database

Title: `Learner — Subjects`. Properties, created once:

| Property | Type | Values |
|----------|------|--------|
| `Subject` | Title | — |
| `Domain` | Select | `Code`, `Architecture`, `Tests`, `CI/Build`, `Data & DB`, `Integrations` |
| `Learning level` | Select | `Discovered`, `Shaky`, `Progressing`, `Solid`, `Mastered` |
| `Passes` | Number | — |
| `To revisit` | Number | — |
| `Last reviewed` | Date | — |
| `Repos` | Multi-select | — |

## 4. Build one row per theme

Read `references/data.md` for the paths, then read `recap.md`.

- One row per entry under `To improve` and under `Mastered`. `Subject` is the entry text
  verbatim; `Domain` is the sub-heading it sits under. Never build a row from a `memory.md`
  line — those are deleted the moment the dev masters them, so they have no stable
  identity to match on and would leave orphans behind.
- `Passes`, `To revisit`, `Last reviewed` and `Repos` come from the `Session history` rows
  whose `Theme` cell names this theme. A row with no `Theme` cell predates the column:
  leave it out of every count.
- `To revisit` counts the `⚠️ revisit` and `⏭️ skip` verdicts together. A skip is a miss —
  passing on a question is not evidence of knowing the answer, and counting it as neutral
  would let a dev grade themself upward by skipping.
- `Repos` is the set of `Repo` values on those rows, plus the repo tag of any `memory.md`
  line you attach in the page body.
- Page body: the still-open `memory.md` concepts belonging to this theme, as bullets. A
  line carries `[Domain][repo]` and never a theme, so let the domain narrow the candidates
  and judge which theme the concept rolls up under — the same judgement `data.md`
  § After every answer already makes when it files a point. Collect any line you cannot
  place and report it in §6 rather than dropping it in silence.

## 5. Derive `Learning level`

Per theme, over its tagged `Session history` rows: `n` rows in total, `ok` = how many
`✅ ok`, `bad` = how many `⚠️ revisit` plus `⏭️ skip`. First matching rule wins.

| # | Condition | Level |
|---|-----------|-------|
| 1 | the theme sits under `Mastered` | `Mastered` |
| 2 | `n = 0` | `Discovered` |
| 3 | `ok = 0` | `Shaky` |
| 4 | `ok < bad` | `Shaky` |
| 5 | `bad = 0` and `ok ≥ 2` | `Solid` |
| 6 | otherwise | `Progressing` |

Rule 1 makes `recap.md` authoritative over the arithmetic: the dev's own judgement that a
theme is done outranks a stale tally. Rule 2 is also the honest answer for a theme whose
whole history predates the `Theme` column — nothing is known about how those passes went.

## 6. Upsert, then report

Match an existing page on its exact `Subject` title: found → update it, absent → create it.

Write **only** the seven properties of §3 and the page body. Any other column the dev added
by hand — a priority, a link to a course, a next-review date — must survive untouched, so
never enumerate the schema in order to prune it. A theme that has vanished from `recap.md`
keeps its page: a rename is indistinguishable from a deletion here, and losing the dev's
own annotations to that guess is not worth it.

Close with a short summary in the dev's language: the database link, how many pages were
created and how many updated, and anything you could not place. A silent success hides
exactly the cases worth knowing about.
