# Claude Learner — exporting the recap to a Notion database

Date: 2026-08-04
Status: approved design, not yet implemented

## Goal

`recap.md` already knows what the dev should level up on, but it lives in
`~/.claude/learner/` where nobody looks. Give it a home the dev already opens every day: a
Notion database, one row per competency theme, refreshed on demand by `learner export`.

The value is not the copy — it is the shape. A Markdown list of themes cannot be sorted by
weakness, filtered to one domain, or annotated with a priority the dev sets themself. A
database can, and the dev's own columns survive every refresh.

## Locked decisions

| # | Decision |
|---|----------|
| 1 | Notion only. No JSON export, no Markdown export, no CSV fallback. |
| 2 | Delivery through the Notion MCP connector only. No connector, no export — a clear refusal, never a partial write. |
| 3 | One row per broad theme from `recap.md`, never per precise concept from `memory.md`. |
| 4 | Upsert into one remembered database. The parent page URL is given once, on the first export. |
| 5 | `Learning level` is a five-value scale derived from `Session history`, not a stored field. |
| 6 | `Session history` gains a `Theme` column, appended last. Existing rows are not migrated. |
| 7 | The export writes only the seven properties it owns. Columns the dev adds by hand survive a refresh. |
| 8 | The export never writes `memory.md` or `recap.md`. Its only local write is `export.json`. The `Theme` column of §4 is written by the quiz modes, not by the export. |
| 9 | The database schema — property names and select values — is in English. Row content stays in the dev's language. |

Decision 3 rests on lifetime. A `memory.md` line is deleted the moment the dev demonstrates
mastery, so it has no stable identity to upsert against; a `recap.md` theme persists and only
moves between `To improve` and `Mastered`. Rows keyed on ephemera would accumulate orphans.

Decision 9 follows `recap.md` itself, which is already English scaffolding around
dev-language content: the headings are `To improve`, `Mastered`, `Session history`, and the
domains are `Code`, `Architecture`, `Tests`, `CI/Build`, `Data & DB`, `Integrations`. A
property name is scaffolding. It also has to be stable — upsert matches on it — and a public
skill cannot key its schema on one dev's language.

## 1. Command surface

| Command | Effect |
|---|---|
| `learner export <notion-page-url>` | First run: create the database inside that page, remember its id |
| `learner export` | Later runs: upsert into the remembered database |
| `learner export <other-url>` | A database is already known: ask before repointing, then create a new one there |

One new row in the Dispatch table of `skills/learner/SKILL.md`, routed to
`references/export.md`. No quiz, no config write, no question.

`learner export` with no argument and no remembered database is an error, not a prompt: it
says which URL it needs and stops.

Every run ends with a short summary in the dev's language: the database link, how many rows
were created and how many updated, and anything the export could not place — a `memory.md`
line that matched no theme, a domain with no theme at all. A silent success would hide exactly
the cases worth knowing about.

## 2. The Notion database

Title: `Learner — Subjects`.

| Property | Type | Source |
|---|---|---|
| `Subject` | Title | the theme text under `To improve` or `Mastered` |
| `Domain` | Select — `Code`, `Architecture`, `Tests`, `CI/Build`, `Data & DB`, `Integrations` | the sub-heading the theme sits under |
| `Learning level` | Select — `Discovered`, `Shaky`, `Progressing`, `Solid`, `Mastered` | derived, §3 |
| `Passes` | Number | `Session history` rows tagged with this theme |
| `To revisit` | Number | of those, the ⚠️ and ⏭️ ones |
| `Last reviewed` | Date | the latest date among those rows |
| `Repos` | Multi-select | the repo tags on those rows, plus the tags on matching `memory.md` lines |

Page body: the still-open precise concepts from `memory.md` that belong to this theme, as
bullets. That is where the detail the dev actually needs to revise lives; the properties are
for sorting and filtering.

**How a `memory.md` line is attached to a theme.** A line carries `[Domain][repo]` and a
concept, never a theme, so the domain narrows the candidates and the model judges which theme
within that domain the concept rolls up under — the same judgment `data.md`'s "After every
answer" step already makes when it files a point under a theme. A line whose domain has no
theme, or that fits none of them, is listed in the page body of no row and reported in the
run's summary rather than dropped in silence.

**The upsert contract.** A refresh writes those seven properties and the page body, and
nothing else. Any property the dev adds later — a priority, a link to a course, a next-review
date — is untouched, because the export never enumerates the schema to prune it.

Rows are matched on the exact `Subject` title. A theme that disappeared from `recap.md` is
left in place: the dev may have renamed a theme, and silently archiving rows would destroy
their annotations. A renamed theme therefore produces a new row and leaves a stale one, which
the dev resolves in Notion. That is the deliberate trade: no destructive write.

## 3. Deriving the learning level

For a theme, over the `Session history` rows tagged with it:

- `n` — how many rows
- `ok` — how many `✅ ok`
- `bad` — how many `⚠️ revisit` or `⏭️ skip`

A skip counts as a miss. Passing on a question is not evidence of knowing the answer, and
treating it as neutral would let a dev grade themself upward by skipping.

First matching rule wins:

| # | Condition | Level |
|---|---|---|
| 1 | the theme sits under `Mastered` | `Mastered` |
| 2 | `n = 0` | `Discovered` |
| 3 | `ok = 0` | `Shaky` |
| 4 | `ok < bad` | `Shaky` |
| 5 | `bad = 0` and `ok ≥ 2` | `Solid` |
| 6 | otherwise | `Progressing` |

Total and deterministic. Rule 1 makes `recap.md` authoritative over the arithmetic: the dev's
own judgment that a theme is done outranks a stale tally.

Rule 2 is also the answer for every theme whose history predates §4 — untagged rows are not
counted, so such a theme reads `Discovered` until its next quiz. That is honest: the export
does not know how those passes went.

## 4. The data-model change

`Session history` in `skills/learner/references/data.md` becomes:

```
| Date | Repo | Domain | Style | Verdict | Note | Theme |
```

`Theme` holds the exact theme text the point was attached to under `To improve` or
`Mastered`. The existing "After every answer" step already picks that theme in order to file
the point; this only asks it to write the choice down.

**Why the column goes last.** Inserting it after `Domain` would read better and would make
every existing six-cell row positionally ambiguous — cell 4 would be `Style` on old rows and
`Theme` on new ones, and the reader is a model, not a parser with a schema. Appended last, a
short row is unambiguously a row without a theme. No migration, no padding pass, no
half-parsed history.

`data.md` states the rule both ways: writers always fill `Theme`; readers treat a missing
`Theme` as untagged.

## 5. Export state

`$CFG/learner/export.json`, beside `memory.md` and `recap.md`:

```json
{
  "notion": {
    "databaseId": "…",
    "url": "…",
    "lastExport": "2026-08-04"
  }
}
```

Created on the first export, validated with `jq -e .` like every other write in this skill.
Never written into a repo — it is per-dev state, not per-project, and the only files this
skill puts inside a repo remain `.claude/learner.local.json` and its `.gitignore` line.

This is state, not configuration, which is why it is a separate file rather than new keys in
`learner.json`: nothing here is meant to be hand-edited, and `learner config` validates a
fixed key set that a machine-written id has no business joining.

## 6. When the connector is missing

The export needs the Notion MCP tools. `references/export.md` checks for them first and, if
they are absent, says so in one line — enable the Notion connector, then re-run
`learner export` — and stops. Nothing is written, locally or remotely. Decision 2 rules out a
CSV or Markdown consolation prize: a half-export that the dev then has to import by hand is
worse than a clear no, and it would drag in the file-export surface this design deliberately
defers.

**Open implementation risk.** `SKILL.md` declares `allowed-tools`, so the Notion tools must be
listed there or they are unreachable from the skill — and the MCP server prefix depends on how
the dev connected Notion (`mcp__claude_ai_Notion__…` for the claude.ai connector,
`mcp__notionApi__…` and others for a self-configured server). Implementation must verify how
`allowed-tools` behaves against MCP names before settling on a value; the fallback is to list
the known prefixes rather than to widen the skill's tool grant. This is the one part of the
design that is not fully determined on paper, and it is called out here so it is resolved
deliberately rather than discovered late.

## 7. Files touched

| File | Change |
|---|---|
| `skills/learner/SKILL.md` | one Dispatch row for `export [url]`; the Notion tools in `allowed-tools` |
| `skills/learner/references/export.md` | new — the whole protocol: read, derive, create-or-upsert, report |
| `skills/learner/references/data.md` | the `Theme` column and its read/write rule; the `export.json` path |
| `docs/usage.html` | a `<dt>`/`<dd>` for `learner export` under `On demand` |
| `test.sh` | the assertions in §8 |

`SKILL.md` is 88 lines and `test.sh` caps it at 120 because it is always loaded, so the
dispatch row is all that goes there. The protocol lives in `references/export.md`, read only
when the subcommand runs.

`install.sh` needs no change: it copies `skills/learner/references/*.md` as a glob.

The README needs no change either. It stopped enumerating subcommands when the site took over
that job, and its one mention of them is prose about `learner off`.

## 8. Tests

`test.sh` asserts on file content and shell behaviour and never reaches the network, so these
pin the contract, not a live Notion call.

1. **`references/export.md` exists.** Added to the hardcoded reference list at `test.sh:668`,
   which is what makes a missing file fail rather than silently skip.
2. **`usage.html` documents `learner export`.** Already automatic: `test.sh:1214` derives the
   subcommand list from `SKILL.md`'s own Dispatch table and requires each one on the page.
   Adding the row turns this red until the page catches up, which is the point.
3. **`SKILL.md` is still ≤ 120 lines.** The existing check, and the reason §7 keeps the
   dispatch row thin.
4. **`data.md`'s `Session history` header carries `Theme`, last.** Pins §4's ordering, not
   just the column's existence — the ordering is the decision.
5. **`export.md` documents the five level values and all six derivation rules.** The scale is
   the feature; a rule quietly dropped in an edit would silently regrade every row.
6. **`export.md` names `export.json` under the `CLAUDE_CONFIG_DIR`-derived path** and does not
   write into a repo. Mirrors the existing `data.md` path assertion.
7. **`export.md` documents the missing-connector refusal** and mentions no CSV or Markdown
   fallback, so decision 2 cannot erode.

Patterns use bracket expressions or `-F`, never a backslash before an ordinary character: an
undefined ERE escape has already produced a bug in this repository that passed under ugrep and
failed under GNU grep.

## Out of scope

- **JSON export.** Wanted, and deferred to its own iteration. Once the theme rollup in §2 and
  §3 exists, a JSON dump is a serialisation of it rather than new thinking.
- **Markdown export, and committing it to a GitHub repo.** Same reasoning. The layout question
  — one file per subject, one per domain, or a `mastered`/`to-improve` pair — was left open on
  purpose and deserves its own design.
- **CSV, or any non-MCP path to Notion.** Decision 2.
- **A Notion API token in `learner.json`.** A secret in a config file the skill validates and
  rewrites, for a path the MCP connector already covers.
- **Automatic export.** No export after N questions, no export from the Stop hook. The hook's
  budget is one question per turn and spending it on a network write would break that.
- **Importing from Notion.** One direction only. Two-way sync needs conflict rules that the
  themes' free-text identity cannot support.
- **Archiving rows for themes that vanished from `recap.md`.** §2: no destructive write.
- **New `learner.json` keys.** §5 keeps the parent page and database id in state, not config.

## Traceability

| Request | Section |
|---|---|
| Export the learning recap to Notion | 1, 2 |
| A structured database, not a page | 2 |
| A `Subject` field | 2 |
| A learning-level field | 2, 3 |
| Ideas for further fields | 2 — `Domain`, `Passes`, `To revisit`, `Last reviewed`, `Repos`, plus the dev's own columns preserved by the upsert contract |
| Plain export (JSON, or Markdown into a folder) | Out of scope, deferred by request |
