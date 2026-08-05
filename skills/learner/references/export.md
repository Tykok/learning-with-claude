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
| A database is recorded and `$ARGUMENTS` names a page other than `notion.parentPageUrl` | Ask before repointing. On yes, create a new database there and overwrite `export.json`; the old database is left untouched. |

Nothing in this table creates anything in Notion before §4's `recap.md` guard has passed: an
empty recap must not leave an empty database behind in the dev's page.

`export.json`:

```json
{
  "notion": {
    "databaseId": "…",
    "parentPageUrl": "…",
    "lastExport": "YYYY-MM-DD"
  }
}
```

`parentPageUrl` holds the page URL given at the first export — the page the database was
created *in*, never the database's own URL. That is what the repoint row above compares
`$ARGUMENTS` against, so recording the database's URL there would make a re-run of the very
same `learner export <page-url>` read as a different page and offer to build a second
database inside the one page. `lastExport` comes from `date +%F`. After writing, confirm with
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

Read `references/data.md` for the paths, then read `recap.md`. This mode only ever reads
`memory.md` and `recap.md`: `data.md`'s "create either file if it does not exist yet" does
not apply here, so never create either of them from this mode. If `recap.md` is missing, or
exists but lists no theme under `To improve` or `Mastered`, say there is nothing to export
yet and stop — before anything is created or touched in Notion, and without creating
`recap.md`.

- One row per entry under `To improve` and under `Mastered`. `Subject` is the entry text
  verbatim; `Domain` is the sub-heading it sits under. Never build a row from a `memory.md`
  line — those are deleted the moment the dev masters them, so they have no stable
  identity to match on and would leave orphans behind.
- `Passes`, `To revisit`, `Last reviewed` and `Repos` come from the `Session history` rows
  whose `Theme` cell names this theme. A row with no `Theme` cell predates the column:
  leave it out of every count. Over the rows that remain, `n` is how many there are, `ok`
  how many read `✅ ok`, and `bad` how many read `⚠️ revisit` or `⏭️ skip` — §5 grades the
  theme from the same three numbers.
- `Passes` = `n` — every tagged row, not only the passing ones. `To revisit` = `bad`, carved
  out of that same count, so `ok = Passes − To revisit` holds wherever the verdicts are
  canonical; reading `Passes` as a count of `✅ ok` breaks it. `Last reviewed` = the latest
  `Date` among those rows.
- `bad` counts `⏭️ skip` with `⚠️ revisit`. A skip is a miss — passing on a question is not
  evidence of knowing the answer, and counting it as neutral would let a dev grade themself
  upward by skipping.
- `Repos` is the set of `Repo` values on those rows, plus the repo tag of any `memory.md`
  line you attach in the page body.
- Page body: the still-open `memory.md` concepts belonging to this theme, as the bullets of
  the `## Open concepts` list §6 owns. A line carries `[Domain][repo]` and never a theme, so
  let the domain narrow the candidates and judge which theme the concept rolls up under —
  the same judgement `data.md` § After every answer already makes when it files a point. A
  line belongs under at most one theme.
- Keep that judgement stable between runs: if the `## Open concepts` list you are about to
  rewrite already carries a line, leave it under that same theme. Judge only a line you have
  not placed before, and break a tie towards the theme with the most `Session history` rows
  naming it. Re-deciding every run would drift a concept from one theme's page to another's
  and make the bullet lists worthless as revision material.
- Collect any line you cannot place and report it in §6 rather than dropping it in silence.

## 5. Derive `Learning level`

Per theme, over its tagged `Session history` rows, with `n`, `ok` and `bad` counted as in
§4. First matching rule wins.

| # | Condition | Level |
|---|-----------|-------|
| 1 | the theme sits under `Mastered` | `Mastered` |
| 2 | `n = 0` | `Discovered` |
| 3 | `ok = 0`, including tagged rows carrying no recognised verdict at all | `Shaky` |
| 4 | `ok < bad` | `Shaky` |
| 5 | `bad = 0` and `ok ≥ 2` | `Solid` |
| 6 | otherwise | `Progressing` |

Rule 1 makes `recap.md` authoritative over the arithmetic: the dev's own judgement that a
theme is done outranks a stale tally. Rule 2 is also the honest answer for a theme whose
whole history predates the `Theme` column — nothing is known about how those passes went.

Keep rule 3: rule 4 does not subsume it. Where every `Verdict` cell holds one of the three
canonical strings, `ok = 0` with `n > 0` does imply `ok < bad` — but a theme whose tagged
rows carry no recognised verdict has `ok = 0` and `bad = 0`, which fails rule 4 and would
fall through to rule 6 and read `Progressing`.

## 6. Upsert, then report

Query the recorded database (`notion.databaseId`) directly — never a workspace-wide search,
which can match a same-titled page sitting in some other database entirely. List every page
in that database once at the start of the run, then match locally on the (`Domain`,
`Subject`) pair: found → update that page, absent → create it. One local pass also survives
Notion's search index lagging a page you created moments ago, which a per-theme re-query
would turn into a duplicate.

`Subject` alone is not a key: the same broad theme name recurs under two domains, which is
why `recap.md` groups by domain in the first place. If two pages in the database already
share one (`Domain`, `Subject`) pair, update neither and name the collision in the summary —
picking one would write over whichever of the two the dev meant to keep.

Write **only** the seven properties of §3 and the page body. Any other column the dev added
by hand — a priority, a link to a course, a next-review date — must survive untouched, so
never enumerate the schema in order to prune it. A theme that has vanished from `recap.md`
keeps its page: a rename is indistinguishable from a deletion here, and losing the dev's
own annotations to that guess is not worth it.

The page body is one export-owned block: a `## Open concepts` heading, created on the first
write, whose bullet list you replace in full on every later write. Touch nothing else on the
page — appending would duplicate the list on every run, and rewriting the body wholesale
would delete a note the dev typed there, which is the same loss the paragraph above refuses
for properties.

Last, rewrite `export.json` with today's date (`date +%F`) in `lastExport` and confirm it
with `jq -e . "$CFG/learner/export.json" >/dev/null && echo OK` — on the create-database
path and the upsert-only path alike. A `lastExport` frozen at the first export is worse than
none: it reads as if every export since had never run.

Close with a short summary in the dev's language: the database link, how many pages were
created and how many updated, any (`Domain`, `Subject`) collision you left alone, and
anything you could not place. A silent success hides exactly the cases worth knowing about.
